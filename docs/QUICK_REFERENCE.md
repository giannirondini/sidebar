# Quick Reference

Details: [BUILD_AND_CODESIGN.md](BUILD_AND_CODESIGN.md) · [DISTRIBUTION.md](DISTRIBUTION.md)

## Build and run

```bash
brew install mint                 # once; swift-bundler is pinned in Mintfile
./scripts/build.sh                # → .build/bundler/SidebArc.app
./scripts/run.sh                  # debug build + launch
./scripts/verify-build.sh         # full bundle check
./scripts/build.sh --dmg          # + .build/dmg/SidebArc-<version>.dmg
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
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

If SidebArc is missing from the Accessibility list or the grant doesn't stick: run `./scripts/verify-build.sh`, reset as above, quit and relaunch. Ad-hoc signatures change on every build, so a rebuild can drop the grant.

## Data and logs

```bash
open ~/Library/Application\ Support/io.github.giannirondini.sidebarc
defaults read io.github.giannirondini.sidebarc
log stream --predicate 'subsystem == "io.github.giannirondini.sidebarc"'
```

## Key files

| File | Purpose |
|---|---|
| `Bundler.toml` | App name, bundle id, version, icon (single source) |
| `Mintfile` | Pinned swift-bundler revision |
| `scripts/lib/app-config.sh` | Names and helpers shared by every script |
| `Sources/ArcmarkCore/Constants.swift` | `AppIdentity`: Swift mirror of the identity |
