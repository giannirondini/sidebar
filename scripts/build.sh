#!/bin/bash
# Build the app as a macOS app bundle. Names and ids come from Bundler.toml.
#
# Usage:
#   ./scripts/build.sh                     # Build with ad-hoc signing (development)
#   ./scripts/build.sh --dmg               # Build with ad-hoc signing and create DMG
#   ./scripts/build.sh --production        # Build with Developer ID signing (production)
#   ./scripts/build.sh --production --dmg  # Build and create notarized DMG

set -e  # Exit on error

CREATE_DMG=false
PRODUCTION=false

for arg in "$@"; do
    case $arg in
        --dmg)
            CREATE_DMG=true
            ;;
        --production)
            PRODUCTION=true
            ;;
        *)
            echo "Unknown argument: $arg"
            echo "Usage: $0 [--production] [--dmg]"
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

if [ "$PRODUCTION" = true ]; then
    if [ ! -f ".notarization-config" ]; then
        echo "❌ Error: .notarization-config not found"
        echo "   See docs/PRODUCTION_SIGNING.md for setup instructions"
        exit 1
    fi

    source .notarization-config

    if [ -z "$SIGNING_IDENTITY" ]; then
        echo "❌ Error: SIGNING_IDENTITY not set in .notarization-config"
        exit 1
    fi

    echo "  → Using Developer ID: $SIGNING_IDENTITY"

    # Sign with hardened runtime for notarization
    codesign --force --deep \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --entitlements "$ENTITLEMENTS" \
        --timestamp \
        "$APP_BUNDLE" 2>&1 | grep -v "replacing existing signature" || true

    echo "  ✓ Signed with Developer ID (hardened runtime, Apple Events entitlement)"
else
    adhoc_sign
    echo "  ✓ Signed with ad-hoc signature (development only; requirement pinned to the bundle id)"
fi

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
    if [ "$PRODUCTION" = true ]; then
        ./scripts/create-dmg.sh --notarize
    else
        ./scripts/create-dmg.sh
    fi
fi
