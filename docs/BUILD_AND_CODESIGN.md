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
- Swift mirrors them in `AppIdentity` (`Sources/ArcmarkCore/Constants.swift`): bundle id, data directory name, logger subsystem, display name, releases URL. `AppIdentityTests` fails if Swift and `Bundler.toml` drift, or if the agent skill CLI points at another data directory.
- The minimum macOS version comes from `platforms` in `Package.swift` (swift-bundler v3 rejects `minimum_macos_version`).
- The Swift module and target names (`ArcmarkCore`, `ArcmarkApp`, `ArcmarkTests`) are unchanged on purpose; a rename is planned separately.

## Build scripts

> Run these yourself; they are not meant to be run by coding agents (see CLAUDE.md).

### `scripts/build.sh`

```bash
./scripts/build.sh                     # release build, ad-hoc signed
./scripts/build.sh --dmg               # + DMG
./scripts/build.sh --production        # Developer ID signing, hardened runtime
./scripts/build.sh --production --dmg  # + notarized DMG
```

Steps:

1. Fails early with install instructions if Mint is missing.
2. Syncs `VERSION` into `Bundler.toml`.
3. `mint run swift-bundler bundle -c release`.
4. **Unwraps the nested resource bundle** (`unwrap_nested_resource_bundles`). Swift 6.4's default `swiftbuild` build system already emits the SwiftPM resource bundle as a full macOS bundle, and swift-bundler v3 wraps it again (`…/Contents/Resources/Contents/Resources/NoteEditor`). Without this step the note editor is not found at runtime. `--build-system native` is not a way out: it is deprecated, and its warning on stdout breaks swift-bundler's `--show-bin-path` parsing.
5. Sets `CFBundleIdentifier`, `CFBundleShortVersionString` and `CFBundleVersion` in Info.plist (belt and braces; swift-bundler v3 already writes them).
6. Code signs (ad-hoc, or Developer ID with `--production`).
7. Prints the bundle id, version and signing identifier; `--dmg` then calls `scripts/create-dmg.sh`.

**Output**: `.build/bundler/SidebArc.app` (executable `Contents/MacOS/SidebArc`).

### `scripts/run.sh`

Debug build, the same unwrap and Info.plist steps, ad-hoc signing, then `open`.

### `scripts/verify-build.sh`

```bash
./scripts/verify-build.sh [path-to-app]   # default: .build/bundler/SidebArc.app
```

Fails unless all of these hold:

- Info.plist is valid; `CFBundleIdentifier` equals the `Bundler.toml` identifier; `CFBundleExecutable` equals the app name.
- The code signature identifier equals the bundle id, and the signature verifies.
- `Contents/MacOS/<app name>` exists.
- The note editor is at `Contents/Resources/*.bundle/Contents/Resources/NoteEditor/index.html`. The bundle is matched by content, not name, the same rule as `NoteServer.resolveBundledResourcesURL()`. A missing editor once crashed the app at launch, and a double-wrapped bundle silently disables notes.
- Regression guards: no `SUFeedURL` in Info.plist and no `Sparkle.framework` (the app has no in-app updater).

## Code signing

macOS needs a valid signature whose identifier matches `CFBundleIdentifier` for:

- **Accessibility** (window attachment) and, later, **Automation**: TCC tracks grants by bundle id plus signature.
- **Gatekeeper** when the app runs outside the App Store.

### Ad-hoc (development)

```bash
codesign --force --deep --sign - .build/bundler/SidebArc.app
```

An ad-hoc signature changes on every build, so TCC may treat each rebuild as a new app and drop the Accessibility grant. If that happens, remove and re-add SidebArc in System Settings, or reset it (below). A stable self-signed identity for development is planned.

### Developer ID (distribution)

`./scripts/build.sh --production` reads `SIGNING_IDENTITY` from `.notarization-config` and signs with `--options runtime --timestamp`. Setup: [PRODUCTION_SIGNING.md](PRODUCTION_SIGNING.md).

## Info.plist as built

```text
CFBundleExecutable        SidebArc
CFBundleIdentifier        io.github.giannirondini.sidebarc
CFBundleName              SidebArc
CFBundleShortVersionString / CFBundleVersion   from VERSION
CFBundleIconFile          AppIcon
LSApplicationCategoryType public.app-category.productivity
LSMinimumSystemVersion    13.0   (from Package.swift)
```

## Runtime data

| What | Where |
|---|---|
| Data (`data.json`, `Icons/`, `Notes/`, `Backups/`, `agent-endpoint.json`) | `~/Library/Application Support/io.github.giannirondini.sidebarc/` |
| Preferences (`UserDefaults`) | domain `io.github.giannirondini.sidebarc` |
| Logs | `os.Logger` subsystem `io.github.giannirondini.sidebarc` |

Nothing is shared with an Arcmark install on the same Mac.

```bash
log stream --predicate 'subsystem == "io.github.giannirondini.sidebarc"'
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
2. Reset the grant and relaunch:
   ```bash
   tccutil reset Accessibility io.github.giannirondini.sidebarc
   ```
3. macOS caches the check: quit and relaunch SidebArc, or use "Refresh Status" in Settings.

## References

- [Swift Bundler documentation](https://swiftbundler.dev/documentation/swift-bundler/)
- [Apple: Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)
- [Apple: Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
