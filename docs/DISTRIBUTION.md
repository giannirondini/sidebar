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

1. Checks the built app is that version, passes `verify-build.sh`, and is signed with the self-signed identity in `.signing-config`. An ad-hoc release would let any app with the bundle id claim the users' grants, and another identity would reset them; `--allow-adhoc` only makes a local test DMG.
2. Builds the DMG: 600 × 400 window, `SidebArc.app` and an Applications link side by side, background `Resources/dmg-background.png`, volume icon from the app; then `hdiutil verify`.
3. Writes `checksums.txt` (SHA-256), `RELEASE_NOTES.md` (What's New from the commit subjects since the previous tag, "First release." without one; install steps with `xattr`; permissions; requirements; checksum) and `UPLOAD_INSTRUCTIONS.md` (commit `VERSION`, tag `v<version>`, push, `gh release create … --notes-file RELEASE_NOTES.md`, or the web form).

Nothing is committed, tagged, pushed or published by the scripts. Nothing is notarized either: that needs a paid Apple Developer ID, which this open-source project doesn't have ([BUILD_AND_CODESIGN.md › No Developer ID](BUILD_AND_CODESIGN.md#no-developer-id)).

| Build | Command | Signing | User experience |
|---|---|---|---|
| App | `./scripts/build.sh [version]` | Self-signed (`.signing-config`), else ad-hoc | Runs locally; a downloaded copy is blocked until `xattr` |
| Release DMG | `./scripts/create-dmg.sh [version]` | Self-signed (required) | Blocked until `xattr` |

## Installing (for users)

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
        └── UPLOAD_INSTRUCTIONS.md
```

`./scripts/clean.sh` removes `.build/` entirely.

## Troubleshooting

| Problem | Fix |
|---|---|
| "App bundle not found" / "The built app is version X" from `create-dmg.sh` | `./scripts/build.sh <version>` first |
| "isn't signed with your identity" | Set up `.signing-config` and rebuild (or `--allow-adhoc` for a test DMG) |
| `create-dmg` not found | `brew install create-dmg` |
| Finder layout or background not applied | Allow the terminal to control Finder (Privacy & Security › Automation) and rerun; cosmetic, the DMG still works |
| Info.plist shows an old version | `./scripts/clean.sh && ./scripts/build.sh` |
| "SidebArc can't be opened" / "Apple could not verify…" after a download | Clear the quarantine flag (Installing, step 4) |
