#!/bin/bash
###############################################################################
# SidebArc - build the app bundle (release configuration)
#
# Usage:
#   ./scripts/build.sh [version]
#
#   version   optional; written to VERSION (and Bundler.toml) before building.
#             Without it the version in VERSION is used.
#
# Example:
#   ./scripts/build.sh 1.1.0
#   ./scripts/create-dmg.sh 1.1.0      # next step for a release (scripts/README.md)
#
# Signed with the self-signed identity in .signing-config, else ad-hoc (only for
# local use). Names and ids come from Bundler.toml (scripts/lib/app-config.sh).
###############################################################################

set -e

cd "$(dirname "$0")/.."
source scripts/lib/app-config.sh

if [ $# -gt 1 ]; then
    print_error "Usage: $0 [version]"
    exit 1
fi

###############################################################################
# Validation
###############################################################################

print_step "Validating build environment..."

if [[ "$OSTYPE" != "darwin"* ]]; then
    print_error "This script must be run on macOS"
    exit 1
fi
require_swift_bundler

if [ $# -eq 1 ]; then
    if ! is_valid_version "$1"; then
        print_error "Invalid version: $1 (expected MAJOR.MINOR.PATCH, e.g. 1.1.0 or 1.1.0-beta.1)"
        exit 1
    fi
    if [ "$1" != "$(current_version)" ]; then
        echo "$1" > VERSION
        print_info "VERSION set to $1"
    fi
fi
VERSION=$(current_version)

load_signing_config
if [ -n "$LOCAL_SIGNING_IDENTITY" ]; then
    print_info "Signing identity: $LOCAL_SIGNING_IDENTITY"
else
    print_warning "No .signing-config: the build will be signed ad-hoc (fine locally, not for a release)"
fi

# Keep Bundler.toml's version in step with VERSION.
CURRENT_TOML_VERSION=$(sed -n "s/^version = '\(.*\)'$/\1/p" Bundler.toml | head -1)
if [ "$CURRENT_TOML_VERSION" != "$VERSION" ]; then
    sed -i '' "s/^version = .*/version = '$VERSION'/" Bundler.toml
    print_info "Bundler.toml version set to $VERSION"
fi

print_success "Building $APP_NAME $VERSION ($BUNDLE_ID)"

###############################################################################
# Build
###############################################################################

print_step "Building with swift-bundler (release)..."
mint run swift-bundler bundle -c release
unwrap_nested_resource_bundles
print_success "App bundle built"

print_step "Patching Info.plist..."
# swift-bundler doesn't always merge [apps.*.plist] values: set the identifier,
# version strings and usage descriptions explicitly.
patch_info_plist "$VERSION" release
print_success "CFBundleIdentifier, version $VERSION, NSAppleEventsUsageDescription, $BUILD_CONFIGURATION_KEY=release"

print_step "Code signing..."
dev_sign
print_success "Signed: $SIGNED_WITH (codesign --verify --deep --strict passed)"

CERT_SHA256=$(leaf_cert_sha256 "$APP_BUNDLE")
EXPECTED_CERT_SHA256=$(expected_release_cert_sha256)
if [ -n "$CERT_SHA256" ]; then
    print_info "Certificate SHA-256: $CERT_SHA256"
    if [ -n "$EXPECTED_CERT_SHA256" ] && [ "$CERT_SHA256" != "$EXPECTED_CERT_SHA256" ]; then
        print_warning "Not the release certificate (scripts/release-signing-cert.sha256): create-dmg.sh will refuse this build"
    fi
fi

###############################################################################
# Summary
###############################################################################

echo ""
print_rule
print_success "Build completed: $APP_NAME $VERSION"
print_rule
echo ""
print_info "App bundle: $APP_BUNDLE"
print_info "Bundle size: $(du -sh "$APP_BUNDLE" | cut -f1)"
echo ""
print_warning "Next steps:"
echo "  1. Test the app:      open \"$APP_BUNDLE\""
echo "  2. Check the bundle:  ./scripts/verify-build.sh"
echo "  3. Create the DMG:    ./scripts/create-dmg.sh $VERSION"
echo ""
print_rule
