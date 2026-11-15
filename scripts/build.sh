#!/bin/bash
# Build the app as a macOS app bundle. Names and ids come from Bundler.toml.
#
# Usage:
#   ./scripts/build.sh                     # Build, signed with the self-signed identity in
#                                          # .signing-config (ad-hoc if there is none)
#   ./scripts/build.sh --dmg               # Same, and create a DMG
#
# Builds aren't notarized (that needs a paid Apple Developer ID), so a downloaded
# copy needs `xattr -dr com.apple.quarantine` once; see docs/DISTRIBUTION.md.

set -e  # Exit on error

CREATE_DMG=false

for arg in "$@"; do
    case $arg in
        --dmg)
            CREATE_DMG=true
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--dmg]"
            exit 1
            ;;
    esac
done

# Ensure we're in the project root
cd "$(dirname "$0")/.."
source scripts/lib/app-config.sh

echo "🔨 Building $APP_NAME ($BUNDLE_ID)..."

require_swift_bundler

# Read version from VERSION file and sync it into Bundler.toml
if [ -f "VERSION" ]; then
    VERSION=$(tr -d '[:space:]' < VERSION)
    echo "📌 Version: $VERSION"

    if grep -q "^version = " Bundler.toml; then
        CURRENT_VERSION=$(grep "^version = " Bundler.toml | head -1 | sed "s/version = '\(.*\)'/\1/" | tr -d "'")
        if [ "$CURRENT_VERSION" != "$VERSION" ]; then
            echo "  → Updating Bundler.toml version to $VERSION"
            sed -i '' "s/^version = .*/version = '$VERSION'/" Bundler.toml
        fi
    fi
fi

# Build the app bundle using swift-bundler (revision pinned in Mintfile)
mint run swift-bundler bundle -c release
unwrap_nested_resource_bundles

# Post-build: swift-bundler doesn't always merge [apps.*.plist] values, so set the
# identifier, version strings and usage descriptions explicitly.
echo "🔧 Patching Info.plist..."
patch_info_plist "$VERSION"
echo "  ✓ CFBundleIdentifier = $BUNDLE_ID"
[ -n "$VERSION" ] && echo "  ✓ CFBundleShortVersionString / CFBundleVersion = $VERSION"
echo "  ✓ NSAppleEventsUsageDescription"

# Code sign the app
echo "🔏 Code signing app..."
dev_sign
echo "  ✓ Signed: $SIGNED_WITH"

echo ""
echo "✅ Build complete!"
echo "📦 App bundle: $APP_BUNDLE"
echo ""
echo "🔍 Verification:"
echo "  Bundle ID: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || echo 'ERROR: Not found')"
echo "  Version:   $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || echo 'Not set')"
echo "  Code Sign: $(codesign -dvv "$APP_BUNDLE" 2>&1 | grep "^Identifier=" | cut -d= -f2)"
echo "  Full check: ./scripts/verify-build.sh"

if [ "$CREATE_DMG" = true ]; then
    echo ""
    echo "────────────────────────────────────────"
    ./scripts/create-dmg.sh
fi
