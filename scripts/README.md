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

A release must be signed with the **release certificate**: your self-signed certificate (`.signing-config`, see [docs/BUILD_AND_CODESIGN.md › Self-signed identity](../docs/BUILD_AND_CODESIGN.md#self-signed-identity)) whose SHA-256 is in `scripts/release-signing-cert.sha256`. `create-dmg.sh` compares the hash, not the name: an ad-hoc app would let any app with the bundle id claim your users' permissions, and any other certificate, even a recreated one with the same name, would reset them.

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

It checks that the built app is version 1.1.0, is a release build (not `run.sh`'s debug build, which goes to the same path), passes `verify-build.sh` and is signed with the release certificate. It builds everything in a temporary folder and moves it into `.build/release/1.1.0/` only when every step succeeded:

| File | What it is |
|---|---|
| `SidebArc-1.1.0.dmg` | The installer (drag to Applications; background from `Resources/dmg-background.png`) |
| `RELEASE_NOTES.md` | What's New (commit subjects since the previous tag), install steps with the `xattr` command, permissions, requirements, checksum |
| `checksums.txt` | SHA-256 of the DMG |
| `UPLOAD_INSTRUCTIONS.md` | The commit, tag, push and `gh release create` commands for this version, ready to paste |

The first run may ask to let your terminal control Finder (the DMG window layout). If that's denied, create-dmg fails without a DMG; `create-dmg.sh` then retries without the styling and warns: the DMG works, with the default layout. Allow it and rerun for the styled window.

**Rerunning** (e.g. after tagging) never overwrites `RELEASE_NOTES.md`: the fresh notes go to `RELEASE_NOTES.new.md`, and you're warned if your notes don't contain the new DMG's checksum (a rebuilt DMG has a different one). The previous DMG and `checksums.txt` move to `previous-<timestamp>/`.

`--allow-adhoc` accepts an app that isn't signed with the release certificate and writes only `.build/release/1.1.0-adhoc/SidebArc-1.1.0-adhoc.dmg`: no notes, no upload instructions, never publish it. The next run without the flag deletes that folder, even if it's refused.

## 3. Publish

Open `.build/release/1.1.0/UPLOAD_INSTRUCTIONS.md`: edit the notes, test the DMG, then commit `VERSION`, tag `v1.1.0`, push and run `gh release create` (or upload on the GitHub releases page).

## Troubleshooting

| Problem | Fix |
|---|---|
| `create-dmg` not found | `brew install create-dmg` |
| "The built app is version X, not Y" | `./scripts/build.sh Y` |
| "isn't signed with the release certificate" | Set up `.signing-config` with the release certificate and rebuild, or `--allow-adhoc` for a test DMG. A new certificate: [docs/BUILD_AND_CODESIGN.md › Self-signed identity](../docs/BUILD_AND_CODESIGN.md#self-signed-identity), step 7 |
| "isn't a release build" | `./scripts/build.sh <version>` (`run.sh` makes a debug build at the same path) |
| "The Finder styling failed", DMG has no background or icon layout | Allow the terminal to control Finder (System Settings › Privacy & Security › Automation) and run `create-dmg.sh` again; the unstyled DMG works |
| Downloaded app "can't be opened" | `xattr -dr com.apple.quarantine /Applications/SidebArc.app` |

Details: [docs/DISTRIBUTION.md](../docs/DISTRIBUTION.md).
