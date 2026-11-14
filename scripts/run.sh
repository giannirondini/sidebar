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
patch_info_plist "$(tr -d '[:space:]' < VERSION)"

# Ad-hoc code sign for development (requirement pinned to the bundle id)
adhoc_sign

echo "🚀 Launching $APP_NAME..."
open "$APP_BUNDLE"
