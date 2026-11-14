#!/bin/bash
# Build (debug) and launch the app. Names and ids come from Bundler.toml.

set -e  # Exit on error

# Ensure we're in the project root
cd "$(dirname "$0")/.."
source scripts/lib/app-config.sh

echo "🚀 Building and running $APP_NAME..."

require_swift_bundler

# Build using swift-bundler (debug mode, revision pinned in Mintfile)
mint run swift-bundler bundle
unwrap_nested_resource_bundles

# Post-build: swift-bundler doesn't always merge plist values
VERSION=$(tr -d '[:space:]' < VERSION)
plist_set "$INFO_PLIST" CFBundleIdentifier "$BUNDLE_ID"
plist_set "$INFO_PLIST" CFBundleShortVersionString "$VERSION"
plist_set "$INFO_PLIST" CFBundleVersion "$VERSION"

# Ad-hoc code sign for development
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 | grep -v "replacing existing signature" || true

echo "🚀 Launching $APP_NAME..."
open "$APP_BUNDLE"
