# Distribution Guide

How to version, package and publish SidebArc.

**See also:**
- [BUILD_AND_CODESIGN.md](BUILD_AND_CODESIGN.md): toolchain, build scripts, code signing, verification
- [PRODUCTION_SIGNING.md](PRODUCTION_SIGNING.md): Developer ID and notarization setup
- [ASSETS.md](ASSETS.md): app icon and DMG background

## Updates

SidebArc has **no in-app updater**. "Check for Updates…" (app menu and Settings → App Version) opens the [GitHub Releases page](https://github.com/giannirondini/sidebarc/releases) (`AppIdentity.releasesURL`). Users update by downloading the new DMG and replacing the app.

## Version management

`VERSION` in the repo root is the source of truth ([Semantic Versioning](https://semver.org/)):

```bash
echo "1.1.0" > VERSION
```

`build.sh` syncs it into `Bundler.toml` and sets `CFBundleShortVersionString` and `CFBundleVersion` in Info.plist. `release.sh` writes `VERSION` for you.

## Building

| Build | Command | Signing | Notarized | User experience |
|---|---|---|---|---|
| Development | `./scripts/build.sh` | Self-signed (`.signing-config`), else ad-hoc | No | Runs locally; a downloaded copy is blocked until `xattr` |
| DMG | `./scripts/build.sh --dmg` | Self-signed, else ad-hoc | No | Blocked until `xattr` |
| Production | `./scripts/build.sh --production` | Developer ID | No | Click-through warning |
| Production DMG | `./scripts/build.sh --production --dmg` | Developer ID | Yes | No warning |

`--production --dmg`:

1. Builds and signs the app with your Developer ID (hardened runtime).
2. Creates the DMG.
3. Submits it to Apple for notarization (about 2 to 5 minutes) and staples the ticket.

Production signing needs `.notarization-config`; see [PRODUCTION_SIGNING.md](PRODUCTION_SIGNING.md).

## DMG

`scripts/create-dmg.sh` (called by `build.sh --dmg`) creates `.build/dmg/SidebArc-<version>.dmg`:

```
SidebArc <version>/
├── SidebArc.app
└── Applications/   → /Applications
```

- Custom Finder layout; background from `Resources/dmg-background.png` when present.
- UDZO (zlib) compression.
- Names come from `Bundler.toml` through `scripts/lib/app-config.sh`.

## Releasing

```bash
./scripts/release.sh 1.1.0                          # Developer ID, notarized
./scripts/release.sh 1.1.0 --no-notarize            # self-signed, not notarized
./scripts/release.sh 1.1.0 --no-notarize --dry-run  # build and sign only, no git/GitHub
```

The script:

1. Checks the working tree is clean (except `VERSION` and `Bundler.toml`), that `gh` is installed, the branch, and that the tag doesn't exist.
2. Opens your editor with the commits since the previous tag, for the release notes.
3. Writes `VERSION` and runs `./scripts/build.sh --production --dmg`, or `./scripts/build.sh --dmg` with `--no-notarize`. `--no-notarize` requires the self-signed identity (`.signing-config`): an ad-hoc release would let any app with the bundle id claim the users' grants, and another identity would reset them.
4. Commits `VERSION` and `Bundler.toml`, tags `v<version>`, pushes.
5. Runs `gh release create` with the DMG and the notes; with `--no-notarize` the notes get an Install section with the `xattr` command.

`--dry-run` stops after the build and prints the remaining git/GitHub commands.

## Installing (for users)

1. Download `SidebArc-<version>.dmg` from GitHub Releases.
2. Open it and drag **SidebArc** onto **Applications**.
3. Eject the disk image and launch SidebArc.
4. Builds that aren't notarized (`--no-notarize`, `build.sh --dmg`): macOS blocks the app until the download's quarantine flag is cleared, once per new version:
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
└── dmg/
    ├── SidebArc-<version>.dmg
    └── dmg-staging/        # temporary, removed automatically
```

`./scripts/clean.sh` removes `.build/` entirely.

## Troubleshooting

| Problem | Fix |
|---|---|
| "App bundle not found" from `create-dmg.sh` | Run `./scripts/build.sh` first |
| Finder layout not applied | Cosmetic; the DMG still works |
| Info.plist shows an old version | `./scripts/clean.sh && ./scripts/build.sh` |
| Notarization fails | See [PRODUCTION_SIGNING.md](PRODUCTION_SIGNING.md) → Troubleshooting |
