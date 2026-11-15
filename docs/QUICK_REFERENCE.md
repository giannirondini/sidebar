# Quick Reference

Details: [BUILD_AND_CODESIGN.md](BUILD_AND_CODESIGN.md) · [DISTRIBUTION.md](DISTRIBUTION.md)

## Build and run

```bash
brew install mint                 # once; swift-bundler is pinned in Mintfile
./scripts/build.sh                # → .build/bundler/SidebArc.app
./scripts/run.sh                  # debug build + launch
./scripts/verify-build.sh         # full bundle check
./scripts/build.sh 1.1.0          # set VERSION, then build
./scripts/create-dmg.sh 1.1.0     # .build/release/1.1.0/: DMG, notes, checksums, upload steps
```

## Tests

```bash
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
```

## Verify by hand

```bash
APP=.build/bundler/SidebArc.app
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist"   # io.github.giannirondini.sidebarc
codesign -dvv "$APP" 2>&1 | grep "^Identifier="                                     # same id
codesign -d -r- "$APP"                                                              # designated requirement
codesign --verify --deep --strict "$APP"                                            # no output = valid
ls "$APP"/Contents/Resources/*.bundle/Contents/Resources/NoteEditor/index.html      # note editor present
```

## Install

```bash
rm -rf /Applications/SidebArc.app
cp -R .build/bundler/SidebArc.app /Applications/
```

## Permissions

```bash
tccutil reset Accessibility io.github.giannirondini.sidebarc
tccutil reset AppleEvents io.github.giannirondini.sidebarc
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

Grants survive rebuilds as long as the signing identity doesn't change. TCC keeps the requirement from grant time, and toggling the switch doesn't refresh it: after switching identity (e.g. ad-hoc → self-signed), or if SidebArc is missing from the list or the grant doesn't stick, run `./scripts/verify-build.sh`, reset as above, quit, relaunch and grant again. To see why a grant fails: `/usr/bin/log show --last 10m --predicate 'process == "tccd" AND eventMessage CONTAINS[c] "sidebarc"'`.

## Data and logs

```bash
open ~/Library/Application\ Support/io.github.giannirondini.sidebarc
defaults read io.github.giannirondini.sidebarc
/usr/bin/log stream --predicate 'subsystem == "io.github.giannirondini.sidebarc"'
```

## Key files

| File | Purpose |
|---|---|
| `Bundler.toml` | App name, bundle id, version, icon (single source) |
| `Mintfile` | Pinned swift-bundler revision |
| `scripts/lib/app-config.sh` | Names and helpers shared by every script |
| `Sources/SidebArcCore/Constants.swift` | `AppIdentity`: Swift mirror of the identity |
