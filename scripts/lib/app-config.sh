#!/bin/bash
# Sourced by the scripts in scripts/. Single source of truth: Bundler.toml.
#
#   APP_NAME        the `[apps.<name>]` key; names <name>.app and the executable inside it
#   BUNDLE_ID       `identifier`
#   PROJECT_ROOT    absolute path of the repo
#   APP_BUNDLE      .build/bundler/<name>.app (relative to PROJECT_ROOT)
#   INFO_PLIST      Info.plist inside APP_BUNDLE
#   APP_EXECUTABLE  executable inside APP_BUNDLE
#   APPLE_EVENTS_USAGE  `NSAppleEventsUsageDescription` from `[apps.<name>.plist]`
#
# Signing: dev_sign (self-signed LOCAL_SIGNING_IDENTITY from .signing-config, else ad-hoc).
#
# Swift mirrors APP_NAME and BUNDLE_ID in `AppIdentity` (Constants.swift);
# AppIdentityTests fails if they drift.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

_bundler_toml="$PROJECT_ROOT/Bundler.toml"
APP_NAME=$(sed -n 's/^\[apps\.\([^].]*\)\]$/\1/p' "$_bundler_toml" | head -1)
BUNDLE_ID=$(sed -n "s/^identifier = '\(.*\)'$/\1/p" "$_bundler_toml" | head -1)
APPLE_EVENTS_USAGE=$(sed -n "s/^NSAppleEventsUsageDescription = '\(.*\)'$/\1/p" "$_bundler_toml" | head -1)
unset _bundler_toml

if [ -z "$APP_NAME" ] || [ -z "$BUNDLE_ID" ] || [ -z "$APPLE_EVENTS_USAGE" ]; then
    echo "❌ Could not read the app name ([apps.<name>]), 'identifier' or 'NSAppleEventsUsageDescription' from Bundler.toml" >&2
    exit 1
fi

APP_BUNDLE=".build/bundler/${APP_NAME}.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Output, in the style of the Anchor scripts (colours only on a terminal).
if [ -t 1 ]; then
    C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[0;34m'; C_NC=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_NC=""
fi
print_step()    { printf '%s==>%s %s%s%s\n' "$C_BLUE" "$C_NC" "$C_GREEN" "$1" "$C_NC"; }
print_info()    { printf '%sℹ️  %s%s\n' "$C_BLUE" "$1" "$C_NC"; }
print_warning() { printf '%s⚠️  %s%s\n' "$C_YELLOW" "$1" "$C_NC"; }
print_error()   { printf '%s❌ %s%s\n' "$C_RED" "$1" "$C_NC" >&2; }
print_success() { printf '%s✅ %s%s\n' "$C_GREEN" "$1" "$C_NC"; }
print_rule()    { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

# Semantic version: X.Y.Z or X.Y.Z-suffix (e.g. 1.0.0, 1.1.0-beta.1).
is_valid_version() {
    echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'
}

# The version in the VERSION file (the single source; build.sh writes it).
current_version() {
    tr -d '[:space:]' < "$PROJECT_ROOT/VERSION"
}

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

# patch_info_plist [version]: swift-bundler doesn't always merge Bundler.toml's plist
# values, so set the identifier, version strings and usage descriptions explicitly.
# Without NSAppleEventsUsageDescription macOS denies Apple Events without a prompt.
patch_info_plist() {
    plist_set "$INFO_PLIST" CFBundleIdentifier "$BUNDLE_ID"
    if [ -n "$1" ]; then
        plist_set "$INFO_PLIST" CFBundleShortVersionString "$1"
        plist_set "$INFO_PLIST" CFBundleVersion "$1"
    fi
    plist_set "$INFO_PLIST" NSAppleEventsUsageDescription "$APPLE_EVENTS_USAGE"
}

# Ad-hoc signature, the fallback when no local identity is configured. The default
# ad-hoc designated requirement is the build's cdhash, which changes on every build,
# so macOS treats each rebuild as a new app and drops its privacy grants (Automation,
# Accessibility). Pinning the requirement to the bundle id keeps them across rebuilds,
# but on that Mac any binary with that identifier would match the grants.
adhoc_sign() {
    codesign --force --deep --sign - \
        -r="designated => identifier \"$BUNDLE_ID\"" \
        "$APP_BUNDLE" 2>&1 | grep -v "replacing existing signature" || true
}

# LOCAL_SIGNING_IDENTITY: the name of a self-signed code-signing certificate in the
# login keychain (docs/BUILD_AND_CODESIGN.md). The environment wins over the
# git-ignored .signing-config. Empty = ad-hoc.
load_signing_config() {
    if [ -z "${LOCAL_SIGNING_IDENTITY:-}" ] && [ -f "$PROJECT_ROOT/.signing-config" ]; then
        source "$PROJECT_ROOT/.signing-config"
    fi
    LOCAL_SIGNING_IDENTITY="${LOCAL_SIGNING_IDENTITY:-}"
}

# Signs with the local identity when one is configured, otherwise ad-hoc. A
# self-signed signature gets codesign's default requirement (bundle id + the
# certificate's hash), so grants survive rebuilds and releases and no other app can
# claim them. A configured identity that can't be found is an error, not a silent
# ad-hoc fallback, which would reset the grants. Sets SIGNED_WITH for messages.
dev_sign() {
    load_signing_config
    if [ -z "$LOCAL_SIGNING_IDENTITY" ]; then
        adhoc_sign
        SIGNED_WITH="ad-hoc (requirement pinned to the bundle id)"
        return
    fi
    # Not `find-identity -v`: an untrusted self-signed certificate signs fine but
    # isn't listed as valid.
    if ! security find-identity -p codesigning | grep -qF "\"$LOCAL_SIGNING_IDENTITY\""; then
        echo "❌ Signing identity \"$LOCAL_SIGNING_IDENTITY\" not found in the keychain" >&2
        echo "   Create it (docs/BUILD_AND_CODESIGN.md › Self-signed identity), or unset" >&2
        echo "   LOCAL_SIGNING_IDENTITY / remove .signing-config to sign ad-hoc." >&2
        exit 1
    fi
    codesign --force --deep --timestamp=none \
        --sign "$LOCAL_SIGNING_IDENTITY" \
        "$APP_BUNDLE" 2>&1 | grep -v "replacing existing signature" || true
    if ! codesign -dvv "$APP_BUNDLE" 2>&1 | grep -qF "Authority=$LOCAL_SIGNING_IDENTITY"; then
        echo "❌ Signing with \"$LOCAL_SIGNING_IDENTITY\" failed (see the codesign output above)" >&2
        exit 1
    fi
    SIGNED_WITH="self-signed identity \"$LOCAL_SIGNING_IDENTITY\""
}
