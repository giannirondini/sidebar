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

# Self-signed identity from .signing-config if configured, else ad-hoc
dev_sign
echo "🔏 Signed: $SIGNED_WITH"

echo "🚀 Launching $APP_NAME..."
open "$APP_BUNDLE"
