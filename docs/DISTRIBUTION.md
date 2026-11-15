# Distribution Guide

How to version, package and publish SidebArc.

**See also:**
- [BUILD_AND_CODESIGN.md](BUILD_AND_CODESIGN.md): toolchain, build scripts, code signing, verification
- [ASSETS.md](ASSETS.md): app icon and DMG background

## Updates

SidebArc has **no in-app updater**. "Check for Updates…" (app menu and Settings → App Version) opens the [GitHub Releases page](https://github.com/giannirondini/sidebarc/releases) (`AppIdentity.releasesURL`). Users update by downloading the new DMG and replacing the app.

## Version management

`VERSION` in the repo root is the source of truth ([Semantic Versioning](https://semver.org/)):

```bash
echo "1.1.0" > VERSION
```

`./scripts/build.sh <version>` writes it (`./scripts/build.sh` alone uses it as it is), syncs it into `Bundler.toml` and sets `CFBundleShortVersionString` and `CFBundleVersion` in Info.plist.

## Releasing

Quick start: [scripts/README.md](../scripts/README.md). Two steps you run yourself, then the publishing commands they print:

```bash
./scripts/build.sh 1.1.0        # build and sign .build/bundler/SidebArc.app
./scripts/create-dmg.sh 1.1.0   # .build/release/1.1.0/: DMG, notes, checksums, upload instructions
```

`create-dmg.sh` (Homebrew's `create-dmg`, `brew install create-dmg`):

1. Checks the built app is that version, is a release build (`SidebArcBuildConfiguration` = `release` in Info.plist; `run.sh` writes a debug build to the same path), passes `verify-build.sh`, and is signed with the release certificate: the leaf certificate's SHA-256 must equal `scripts/release-signing-cert.sha256`. The name isn't compared: a recreated certificate with the same name would still reset the users' grants, and an ad-hoc release would let any app with the bundle id claim them. `--allow-adhoc` accepts anything else but only writes `.build/release/<version>-adhoc/SidebArc-<version>-adhoc.dmg` (no notes, no upload instructions); a later run without it deletes that folder.
2. Builds the DMG in a temporary folder (`.build/release/.dmg-build.*`, removed on exit along with any disk image create-dmg left attached): 600 × 400 window, `SidebArc.app` and an Applications link side by side, background `Resources/dmg-background.png`, volume icon from the app; then `hdiutil verify`. If the Finder-styling AppleScript fails (create-dmg exits 64 without a DMG), it retries once with `--skip-jenkins` and warns.
3. Writes `checksums.txt` (SHA-256), `RELEASE_NOTES.md` (What's New from the commit subjects since the previous tag, "First release." without one; install steps with `xattr`; permissions; requirements; checksum) and `UPLOAD_INSTRUCTIONS.md` (commit `VERSION`, tag `v<version>`, push, `gh release create … --notes-file RELEASE_NOTES.md`, or the web form), then moves them into `.build/release/<version>/`. A rerun keeps an existing `RELEASE_NOTES.md` (the fresh notes become `RELEASE_NOTES.new.md`, with a warning if the kept notes lack the new checksum) and moves the previous DMG and `checksums.txt` to `previous-<timestamp>/`.

Nothing is committed, tagged, pushed or published by the scripts. Nothing is notarized either: that needs a paid Apple Developer ID, which this open-source project doesn't have ([BUILD_AND_CODESIGN.md › No Developer ID](BUILD_AND_CODESIGN.md#no-developer-id)).

| Build | Command | Signing | User experience |
|---|---|---|---|
| App | `./scripts/build.sh [version]` | Self-signed (`.signing-config`), else ad-hoc | Runs locally; a downloaded copy is blocked until `xattr` |
| Release DMG | `./scripts/create-dmg.sh [version]` | Release certificate (required, compared by SHA-256) | Blocked until `xattr` |

## Installing (for users)

Requires macOS 13 or later on Apple silicon: the DMG is arm64 only.

1. Download `SidebArc-<version>.dmg` from GitHub Releases.
2. Open it and drag **SidebArc** onto **Applications**.
3. Eject the disk image and launch SidebArc.
4. SidebArc isn't notarized, so macOS blocks the downloaded app until its quarantine flag is cleared, once per new version:
   ```bash
   xattr -dr com.apple.quarantine /Applications/SidebArc.app
   ```
   (Or System Settings → Privacy & Security → Open Anyway.) Accessibility and Automation grants carry over between releases signed with the same identity.

To update, quit SidebArc and repeat with the new DMG. Data lives in `~/Library/Application Support/io.github.giannirondini.sidebarc/` and is kept across updates.

## Build artifacts

```
.build/
├── bundler/
│   └── SidebArc.app
└── release/
    └── <version>/
        ├── SidebArc-<version>.dmg
        ├── RELEASE_NOTES.md
        ├── checksums.txt
        ├── UPLOAD_INSTRUCTIONS.md
        ├── RELEASE_NOTES.new.md      (rerun with edited notes only)
        └── previous-<timestamp>/     (rerun only: the replaced DMG and checksums)
```

A test DMG (`--allow-adhoc`) goes to `.build/release/<version>-adhoc/` instead.

`./scripts/clean.sh` removes `.build/` entirely.

## Troubleshooting

| Problem | Fix |
|---|---|
| "App bundle not found" / "The built app is version X" from `create-dmg.sh` | `./scripts/build.sh <version>` first |
| "isn't signed with the release certificate" | Set up `.signing-config` with the release certificate and rebuild (or `--allow-adhoc` for a test DMG) |
| "isn't a release build" | `./scripts/build.sh <version>` |
| `create-dmg` not found | `brew install create-dmg` |
| "The Finder styling failed" / layout or background not applied | Allow the terminal to control Finder (Privacy & Security › Automation) and rerun; `create-dmg.sh` already retried without the styling, so the DMG works with the default layout |
| Info.plist shows an old version | `./scripts/clean.sh && ./scripts/build.sh` |
| "SidebArc can't be opened" / "Apple could not verify…" after a download | Clear the quarantine flag (Installing, step 4) |
