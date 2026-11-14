#!/bin/bash
# Sourced by the scripts in scripts/. Single source of truth: Bundler.toml.
#
#   APP_NAME        the `[apps.<name>]` key; names <name>.app and the executable inside it
#   BUNDLE_ID       `identifier`
#   PROJECT_ROOT    absolute path of the repo
#   APP_BUNDLE      .build/bundler/<name>.app (relative to PROJECT_ROOT)
#   INFO_PLIST      Info.plist inside APP_BUNDLE
#   APP_EXECUTABLE  executable inside APP_BUNDLE
#
# Swift mirrors APP_NAME and BUNDLE_ID in `AppIdentity` (Constants.swift);
# AppIdentityTests fails if they drift.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_bundler_toml="$PROJECT_ROOT/Bundler.toml"
APP_NAME=$(sed -n 's/^\[apps\.\([^].]*\)\]$/\1/p' "$_bundler_toml" | head -1)
BUNDLE_ID=$(sed -n "s/^identifier = '\(.*\)'$/\1/p" "$_bundler_toml" | head -1)
unset _bundler_toml

if [ -z "$APP_NAME" ] || [ -z "$BUNDLE_ID" ]; then
    echo "❌ Could not read the app name ([apps.<name>]) or 'identifier' from Bundler.toml" >&2
    exit 1
fi

APP_BUNDLE=".build/bundler/${APP_NAME}.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# swift-bundler runs through Mint, pinned by the Mintfile in the repo root.
require_swift_bundler() {
    if ! command -v mint >/dev/null 2>&1; then
        echo "❌ Mint is not installed. swift-bundler runs through Mint (revision pinned in Mintfile)." >&2
        echo "   Install it with:  brew install mint" >&2
        echo "   The first build then installs swift-bundler automatically (takes a few minutes)." >&2
        exit 1
    fi
}

# swift-bundler v3 expects SwiftPM's old flat resource bundles. The default
# `swiftbuild` build system (Swift 6.3+) already emits a full macOS bundle
# (X.bundle/Contents/Resources/...), which swift-bundler wraps a second time:
# X.bundle/Contents/Resources/Contents/Resources/NoteEditor. Bundle.resourceURL
# then misses the note editor. Replace each wrapper with the real bundle inside.
# (`--build-system native` is not an option: deprecated, and its warning on
# stdout breaks swift-bundler's `--show-bin-path` parsing.)
unwrap_nested_resource_bundles() {
    local bundle inner
    for bundle in "$APP_BUNDLE"/Contents/Resources/*.bundle; do
        inner="$bundle/Contents/Resources/Contents"
        [ -d "$inner" ] || continue
        if [ "$(ls -A "$bundle/Contents/Resources")" != "Contents" ]; then
            echo "❌ $(basename "$bundle") has unexpected files next to the nested bundle; not unwrapping" >&2
            exit 1
        fi
        mv "$inner" "$bundle/Contents.unwrapped"
        rm -rf "$bundle/Contents"
        mv "$bundle/Contents.unwrapped" "$bundle/Contents"
        echo "  ✓ Unwrapped nested resource bundle $(basename "$bundle")"
    done
}

# plist_set <file> <key> <string value>: adds the key or overwrites it.
plist_set() {
    if /usr/libexec/PlistBuddy -c "Print :$2" "$1" &>/dev/null; then
        /usr/libexec/PlistBuddy -c "Set :$2 $3" "$1"
    else
        /usr/libexec/PlistBuddy -c "Add :$2 string $3" "$1"
    fi
}
