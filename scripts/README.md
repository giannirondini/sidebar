# Releasing SidebArc: quick start

## TL;DR

```bash
./scripts/build.sh 1.1.0        # writes VERSION, builds and signs .build/bundler/SidebArc.app
./scripts/create-dmg.sh 1.1.0   # DMG + release notes + checksums + upload instructions
# then follow .build/release/1.1.0/UPLOAD_INSTRUCTIONS.md
```

Nothing is committed, tagged, pushed or published for you: you review the notes and run the commands yourself.

## First time setup

```bash
brew install mint          # swift-bundler runs through Mint (pinned in Mintfile)
brew install create-dmg    # the DMG tool
brew install gh && gh auth login   # optional: publish from the terminal
```

A release must be signed with your **self-signed certificate** (`.signing-config`, see [docs/BUILD_AND_CODESIGN.md › Self-signed identity](../docs/BUILD_AND_CODESIGN.md#self-signed-identity)): `create-dmg.sh` refuses an ad-hoc signed app, which would let any app with the bundle id claim your users' permissions.

## 1. Build

```bash
./scripts/build.sh 1.1.0
open .build/bundler/SidebArc.app     # try it
./scripts/verify-build.sh            # optional; create-dmg.sh runs it too
```

Without a version, `build.sh` uses the one in `VERSION`.

## 2. Create the DMG and release files

```bash
./scripts/create-dmg.sh 1.1.0
```

It checks that the built app is version 1.1.0, passes `verify-build.sh` and is signed with your certificate, then writes `.build/release/1.1.0/`:

| File | What it is |
|---|---|
| `SidebArc-1.1.0.dmg` | The installer (drag to Applications; background from `Resources/dmg-background.png`) |
| `RELEASE_NOTES.md` | What's New (commit subjects since the previous tag), install steps with the `xattr` command, permissions, requirements, checksum |
| `checksums.txt` | SHA-256 of the DMG |
| `UPLOAD_INSTRUCTIONS.md` | The commit, tag, push and `gh release create` commands for this version, ready to paste |

The first run may ask to let your terminal control Finder (the DMG window layout): allow it, or the DMG gets the default layout.

`--allow-adhoc` makes a local test DMG from an ad-hoc build; don't publish it.

## 3. Publish

Open `.build/release/1.1.0/UPLOAD_INSTRUCTIONS.md`: edit the notes, test the DMG, then commit `VERSION`, tag `v1.1.0`, push and run `gh release create` (or upload on the GitHub releases page).

## Troubleshooting

| Problem | Fix |
|---|---|
| `create-dmg` not found | `brew install create-dmg` |
| "The built app is version X, not Y" | `./scripts/build.sh Y` |
| "isn't signed with your identity" | Set up `.signing-config` and rebuild, or `--allow-adhoc` for a test DMG |
| DMG has no background or icon layout | Allow the terminal to control Finder (System Settings › Privacy & Security › Automation) and run `create-dmg.sh` again; the DMG works either way |
| Downloaded app "can't be opened" | `xattr -dr com.apple.quarantine /Applications/SidebArc.app` |

Details: [docs/DISTRIBUTION.md](../docs/DISTRIBUTION.md).
