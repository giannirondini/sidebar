# Build Process and Code Signing

How SidebArc is built, bundled, code-signed, and verified. Release and DMG workflow: [DISTRIBUTION.md](DISTRIBUTION.md).

## Toolchain

| Tool | Role | Notes |
|---|---|---|
| Swift 6.2+ (Command Line Tools are enough) | Compiles the package | Xcode is **not** required |
| [Mint](https://github.com/yonaskolb/Mint) (`brew install mint`) | Runs swift-bundler at a pinned revision | The first build installs swift-bundler (a few minutes) |
| [swift-bundler](https://github.com/stackotter/swift-bundler) | Turns the SwiftPM product into `SidebArc.app` | Pinned in `Mintfile` to `d49cb27` (v3.0.0) |

**Why that swift-bundler revision**: from commit `0f7aa1f` (2025-08-12) swift-bundler depends on ErrorKit, whose `.xcstrings` resource needs `xcstringstool`, which ships only with Xcode. Later revisions fail to build with Command Line Tools. Bump the pin deliberately and rebuild.

## Single source of identity

`Bundler.toml` defines the app once:

```toml
format_version = 2

[apps.SidebArc]                                 # app name: SidebArc.app and its executable
identifier = 'io.github.giannirondini.sidebarc' # bundle id
product = 'sidebarc'                            # SwiftPM executable product (Package.swift)
version = '1.0.0'                               # synced from VERSION by build.sh
icon = 'Resources/AppIcon.png'
```

- Scripts read the app name and bundle id through `scripts/lib/app-config.sh` (`APP_NAME`, `BUNDLE_ID`, `APP_BUNDLE`, `INFO_PLIST`, `APP_EXECUTABLE`). No script hard-codes them.
- Swift mirrors them in `AppIdentity` (`Sources/SidebArcCore/Constants.swift`): bundle id, data directory name, logger subsystem, display name, releases URL. `AppIdentityTests` fails if Swift and `Bundler.toml` drift, or if the agent skill CLI points at another data directory.
- The minimum macOS version comes from `platforms` in `Package.swift` (swift-bundler v3 rejects `minimum_macos_version`).
- The Swift module and target names (`SidebArcCore`, `SidebArcApp`, `SidebArcTests`) are unchanged on purpose; a rename is planned separately.

## Build scripts

> Run these yourself; they are not meant to be run by coding agents (see CLAUDE.md).

### `scripts/build.sh`

```bash
./scripts/build.sh          # release build, self-signed (.signing-config) or ad-hoc
./scripts/build.sh --dmg    # + DMG
```

Steps:

1. Fails early with install instructions if Mint is missing.
2. Syncs `VERSION` into `Bundler.toml`.
3. `mint run swift-bundler bundle -c release`.
4. **Unwraps the nested resource bundle** (`unwrap_nested_resource_bundles`). Swift 6.4's default `swiftbuild` build system already emits the SwiftPM resource bundle as a full macOS bundle, and swift-bundler v3 wraps it again (`…/Contents/Resources/Contents/Resources/NoteEditor`). Without this step the note editor is not found at runtime. `--build-system native` is not a way out: it is deprecated, and its warning on stdout breaks swift-bundler's `--show-bin-path` parsing.
5. Sets `CFBundleIdentifier`, `CFBundleShortVersionString`, `CFBundleVersion` and `NSAppleEventsUsageDescription` in Info.plist (`patch_info_plist`; swift-bundler doesn't always merge `[apps.SidebArc.plist]`). Without the usage string macOS denies Apple Events without a prompt, so "switch to open tabs" never works.
6. Code signs (`dev_sign`, see below): with the self-signed identity named in `.signing-config`, else ad-hoc with the requirement pinned to the bundle id.
7. Prints the bundle id, version and signing identifier; `--dmg` then calls `scripts/create-dmg.sh`.

**Output**: `.build/bundler/SidebArc.app` (executable `Contents/MacOS/SidebArc`).

### `scripts/run.sh`

Debug build, the same unwrap and Info.plist steps (`patch_info_plist`), the same signing (`dev_sign`), then `open`.

### `scripts/verify-build.sh`

```bash
./scripts/verify-build.sh [path-to-app]   # default: .build/bundler/SidebArc.app
```

Fails unless all of these hold:

- Info.plist is valid; `CFBundleIdentifier` equals the `Bundler.toml` identifier; `CFBundleExecutable` equals the app name.
- `NSAppleEventsUsageDescription` is in Info.plist.
- The code signature identifier equals the bundle id, and the signature verifies. It also prints who signed it (ad-hoc or the certificate) and the designated requirement.
- `Contents/MacOS/<app name>` exists.
- The note editor is at `Contents/Resources/*.bundle/Contents/Resources/NoteEditor/index.html`. The bundle is matched by content, not name, the same rule as `NoteServer.resolveBundledResourcesURL()`. A missing editor once crashed the app at launch, and a double-wrapped bundle silently disables notes.
- Regression guards: no `SUFeedURL` in Info.plist and no `Sparkle.framework` (the app has no in-app updater).

## Code signing

macOS needs a valid signature whose identifier matches `CFBundleIdentifier` for:

- **Accessibility** (window attachment) and **Automation** (switching to open tabs): TCC stores each grant with the app's designated requirement.
- **Gatekeeper** when the app runs outside the App Store.

Without notarization, Gatekeeper blocks a **downloaded** app whatever its signature (ad-hoc or self-signed) until the quarantine flag is cleared (`xattr -dr com.apple.quarantine /Applications/SidebArc.app`). Only Developer ID + notarization avoids that. A local build is never quarantined.

| Signature | Grants survive rebuilds/releases | Another app can claim the grants | Setup |
|---|---|---|---|
| Self-signed identity (recommended) | Yes | No | Once, on the Mac that builds |
| Ad-hoc (fallback) | Yes | Yes, any binary with the bundle id on that Mac | None |

`dev_sign` (`scripts/lib/app-config.sh`, used by `build.sh` and `run.sh`) uses `LOCAL_SIGNING_IDENTITY` from the environment or `.signing-config`, and falls back to ad-hoc when it's unset. A configured identity that isn't in the keychain stops the build: a silent ad-hoc fallback would change the requirement.

### Self-signed identity

codesign's default requirement for a certificate is the bundle id **and** the certificate's hash: `identifier "io.github.giannirondini.sidebarc" and certificate leaf = H"…"`. The certificate travels inside the signature, so other Macs (e.g. one that installs the DMG) need nothing installed, and the certificate doesn't have to be trusted.

Setup, once, on the Mac that builds:

1. Keychain Access (on macOS 27 it's no longer in Applications: open it with Spotlight, or from `/System/Library/CoreServices/Applications/`) › Keychain Access › Certificate Assistant › **Create a Certificate…**: Name `SidebArc Local Signing`, Identity Type **Self-Signed Root**, Certificate Type **Code Signing** › Create. Leave its trust settings alone.
2. `cp .signing-config.template .signing-config` (git-ignored) and check the name. `security find-identity -p codesigning` lists it as `CSSMERR_TP_NOT_TRUSTED`, which is expected (`-v` hides it).
3. Build. The first signature asks to let `codesign` use the key: **Always Allow**.
4. `./scripts/verify-build.sh` shows `Signed by: SidebArc Local Signing` and the requirement with `certificate leaf`.
5. **Once per Mac, re-grant.** TCC keeps the requirement that applied when a permission was granted, so grants made for an ad-hoc build keep matching any binary with the bundle id. Reset them and grant again so TCC stores the certificate requirement:
   ```bash
   tccutil reset Accessibility io.github.giannirondini.sidebarc
   tccutil reset AppleEvents io.github.giannirondini.sidebarc
   ```
6. **Back it up.** Keychain Access › My Certificates › the certificate › Export… as `.p12` (certificate + private key). A new certificate has a new hash, so every Mac would have to re-grant once.

### Ad-hoc (fallback)

```bash
codesign --force --deep --sign - \
  -r='designated => identifier "io.github.giannirondini.sidebarc"' \
  .build/bundler/SidebArc.app
```

By default an ad-hoc signature's designated requirement is the build's `cdhash`, which changes on every build, so TCC treated each rebuild as a new app and dropped its Accessibility and Automation grants. `adhoc_sign` (`scripts/lib/app-config.sh`) pins the requirement to the bundle id so grants survive rebuilds; `codesign -d -r- .build/bundler/SidebArc.app` shows `designated => identifier "io.github.giannirondini.sidebarc"`. On that Mac any binary signed with that identifier matches the grants; use a self-signed identity to close that. If a grant still doesn't stick, reset it (below).

Ad-hoc and self-signed builds have no hardened runtime, so they need no entitlements.

### No Developer ID

SidebArc is open source and has no paid Apple Developer account, so builds are neither Developer ID-signed nor notarized; downloaded copies need the `xattr` step above ([DISTRIBUTION.md › Installing](DISTRIBUTION.md#installing-for-users)). Adding it later would mean signing with the hardened runtime, which needs the `com.apple.security.automation.apple-events` entitlement (without it Apple Events to browsers fail silently), and submitting the DMG with `notarytool`; the scripts for that were removed on 2026-11-15 and are in the git history.

## Info.plist as built

```text
CFBundleExecutable        SidebArc
CFBundleIdentifier        io.github.giannirondini.sidebarc
CFBundleName              SidebArc
CFBundleShortVersionString / CFBundleVersion   from VERSION
CFBundleIconFile          AppIcon
LSApplicationCategoryType public.app-category.productivity
LSMinimumSystemVersion    13.0   (from Package.swift)
NSAppleEventsUsageDescription  from [apps.SidebArc.plist] in Bundler.toml
```

## Runtime data

| What | Where |
|---|---|
| Data (`data.json`, `Icons/`, `Notes/`, `Backups/` with the rotating `data-*.json` and the `pre-import-*` exports, `agent-endpoint.json`) | `~/Library/Application Support/io.github.giannirondini.sidebarc/` |
| Preferences (`UserDefaults`) | domain `io.github.giannirondini.sidebarc` |
| Logs | `os.Logger` subsystem `io.github.giannirondini.sidebarc`; categories include `attach` (window attachment: activations, hides and why), `tabs` (tab focus), `transition`, `store`, `model` |

Nothing is shared with an Arcmark install on the same Mac.

```bash
/usr/bin/log stream --predicate 'subsystem == "io.github.giannirondini.sidebarc"'
```

## Verification commands

```bash
APP=.build/bundler/SidebArc.app

/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign -dvv "$APP" 2>&1 | grep -E "^(Identifier|Format|Signature|Info.plist)"
codesign --verify --deep --strict --verbose=2 "$APP"
ls "$APP"/Contents/Resources/*.bundle/Contents/Resources/NoteEditor/index.html
```

## Tests

```bash
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
```

All tests use swift-testing (XCTest is not available without Xcode). The plugin path works around an intermittent "TestingMacros plugin not found" failure with Command Line Tools.

## Troubleshooting

### `mint` not found

`brew install mint`, then rerun the build.

### swift-bundler fails to build under Mint

Most likely the `Mintfile` pin was moved past `d49cb27`, and the new revision needs Xcode (`xcstringstool`). Revert the pin, or install Xcode.

### "Encountered unexpected key … minimum_macos_version"

swift-bundler v3 rejects that key. Set the minimum in `Package.swift` `platforms`.

### Notes show "editor unavailable"

The resource bundle was not unwrapped. Rebuild with `./scripts/build.sh` (not a bare `mint run swift-bundler bundle`) and run `./scripts/verify-build.sh`.

### SidebArc doesn't appear in Accessibility, or the grant doesn't stick

1. Check the bundle id and the signature identifier match (`./scripts/verify-build.sh`).
2. TCC keeps the code requirement from **grant time**; turning the switch off and on doesn't refresh it. After a change of signing identity (e.g. ad-hoc → self-signed) the old grant no longer matches. Reset it, relaunch the current build and grant again:
   ```bash
   tccutil reset Accessibility io.github.giannirondini.sidebarc
   ```
3. macOS caches the check: quit and relaunch SidebArc, or use "Refresh Status" in Settings.
4. To see why a grant is rejected, read `tccd`'s log (in zsh, plain `log` is a builtin):
   ```bash
   /usr/bin/log show --last 10m --predicate 'process == "tccd" AND eventMessage CONTAINS[c] "sidebarc"'
   ```
   `Failed to match existing code requirement` means the stored grant belongs to another signature: reset as in step 2.

### Clicking a favorite opens a duplicate instead of switching to the open tab

1. Settings › Permissions › Automation shows each profile browser's status. "Not asked yet": click **Allow Browser Access…** with the browser running. "Not allowed": turn it on in System Settings › Privacy & Security › Automation › SidebArc.
2. `./scripts/verify-build.sh` must show `NSAppleEventsUsageDescription`.
3. Reset the grant to be asked again:
   ```bash
   tccutil reset AppleEvents io.github.giannirondini.sidebarc
   ```
4. Logs: `/usr/bin/log stream --predicate 'subsystem == "io.github.giannirondini.sidebarc" AND category == "tabs"'` shows each lookup and its timing.

## References

- [Swift Bundler documentation](https://swiftbundler.dev/documentation/swift-bundler/)
- [Apple: Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)
