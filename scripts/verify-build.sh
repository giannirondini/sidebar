#!/bin/bash
# Verify a built app bundle. Names and ids come from Bundler.toml.
# Usage: ./scripts/verify-build.sh [path-to-app]

source "$(dirname "$0")/lib/app-config.sh"

APP_PATH="${1:-$PROJECT_ROOT/$APP_BUNDLE}"
PLIST="$APP_PATH/Contents/Info.plist"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ App not found at: $APP_PATH"
    echo "   Build it first: ./scripts/build.sh"
    echo "   Usage: $0 [path-to-app]"
    exit 1
fi

plist_get() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null
}

FAILED=false
fail() {
    echo "❌ $1"
    FAILED=true
}

echo "🔍 Verifying $APP_NAME build at: $APP_PATH"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Info.plist Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if plutil -lint "$PLIST" > /dev/null 2>&1; then
    echo "✅ Info.plist is valid"
else
    echo "❌ Info.plist is missing or malformed"
    exit 1
fi

PLIST_BUNDLE_ID=$(plist_get CFBundleIdentifier)
if [ "$PLIST_BUNDLE_ID" = "$BUNDLE_ID" ]; then
    echo "✅ CFBundleIdentifier: $PLIST_BUNDLE_ID"
else
    fail "CFBundleIdentifier: ${PLIST_BUNDLE_ID:-NOT FOUND} (expected: $BUNDLE_ID)"
fi

PLIST_EXECUTABLE=$(plist_get CFBundleExecutable)
if [ "$PLIST_EXECUTABLE" = "$APP_NAME" ]; then
    echo "✅ CFBundleExecutable: $PLIST_EXECUTABLE"
else
    fail "CFBundleExecutable: ${PLIST_EXECUTABLE:-NOT FOUND} (expected: $APP_NAME)"
fi

echo "   CFBundleName: $(plist_get CFBundleName)"
echo "   CFBundleShortVersionString: $(plist_get CFBundleShortVersionString)"

# Without it macOS denies Apple Events (tab focus) silently, without a prompt.
if plist_get NSAppleEventsUsageDescription > /dev/null; then
    echo "✅ NSAppleEventsUsageDescription present"
else
    fail "NSAppleEventsUsageDescription missing (tab focus would be denied without a prompt)"
fi

# There is no in-app updater; a feed key here means a stale or foreign build.
if plist_get SUFeedURL > /dev/null; then
    fail "SUFeedURL present in Info.plist (the app has no updater)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔏 Code Signature Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CODESIGN_OUTPUT=$(codesign -dvv "$APP_PATH" 2>&1)
SIGNATURE_ID=$(echo "$CODESIGN_OUTPUT" | grep "^Identifier=" | cut -d= -f2)
SIGNATURE_FORMAT=$(echo "$CODESIGN_OUTPUT" | grep "^Format=" | cut -d= -f2-)
SIGNATURE_TYPE=$(echo "$CODESIGN_OUTPUT" | grep "^Signature=" | cut -d= -f2)
INFO_PLIST_ENTRIES=$(echo "$CODESIGN_OUTPUT" | grep "^Info.plist entries=" | cut -d= -f2)

if [ "$SIGNATURE_ID" = "$BUNDLE_ID" ]; then
    echo "✅ Signature Identifier: $SIGNATURE_ID"
else
    fail "Signature Identifier: ${SIGNATURE_ID:-NONE} (expected: $BUNDLE_ID)"
fi

echo "   Format: $SIGNATURE_FORMAT"
echo "   Signature Type: $SIGNATURE_TYPE"
echo "   Info.plist entries: $INFO_PLIST_ENTRIES"
SIGNING_AUTHORITY=$(echo "$CODESIGN_OUTPUT" | grep -m1 "^Authority=" | cut -d= -f2-)
# Ad-hoc builds pin the requirement to the bundle id so privacy grants survive rebuilds;
# a self-signed identity adds the certificate's hash, so no other app can claim them.
if [ "$SIGNATURE_TYPE" = "adhoc" ]; then
    echo "   Signed: ad-hoc (any app with this bundle id would match the grants; see docs/BUILD_AND_CODESIGN.md › Self-signed identity)"
else
    echo "   Signed by: ${SIGNING_AUTHORITY:-unknown}"
fi
echo "   Designated requirement: $(codesign -d -r- "$APP_PATH" 2>&1 | sed -n 's/^designated => //p')"

# Under the hardened runtime, Apple Events need the entitlement or they fail silently.
if echo "$CODESIGN_OUTPUT" | grep -q "flags=.*runtime"; then
    if codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null | grep -q "com.apple.security.automation.apple-events"; then
        echo "✅ Hardened runtime with the Apple Events entitlement"
    else
        fail "Hardened runtime without com.apple.security.automation.apple-events (tab focus would fail)"
    fi
fi

if codesign --verify --verbose=4 "$APP_PATH" > /dev/null 2>&1; then
    echo "✅ Signature is valid"
else
    fail "Signature is invalid or missing"
    codesign --verify --verbose=4 "$APP_PATH"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Bundle Structure"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

EXECUTABLE="$APP_PATH/Contents/MacOS/$APP_NAME"
if [ -f "$EXECUTABLE" ]; then
    echo "✅ Executable found: Contents/MacOS/$APP_NAME"
    echo "   Architecture: $(lipo -archs "$EXECUTABLE" 2>/dev/null)"
else
    fail "Executable not found: Contents/MacOS/$APP_NAME"
fi

if [ -d "$APP_PATH/Contents/Resources" ]; then
    echo "✅ Resources directory found"
else
    echo "⚠️  Resources directory not found"
fi

if [ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]; then
    fail "Sparkle.framework is embedded (the app has no updater)"
fi

# The bundled note editor must ship inside the SwiftPM resource bundle. If it is
# missing, the notes feature is dead in the field, and historically a missing
# resource bundle crashed the app on launch. Matched by content, not by bundle
# name, the same rule NoteServer.resolveBundledResourcesURL() uses.
EDITOR_INDEX=$(ls "$APP_PATH"/Contents/Resources/*.bundle/Contents/Resources/NoteEditor/index.html 2>/dev/null | head -1)
if [ -n "$EDITOR_INDEX" ]; then
    echo "✅ Note editor resources found: ${EDITOR_INDEX#"$APP_PATH/"}"
else
    fail "Note editor resources missing (expected Contents/Resources/*.bundle/Contents/Resources/NoteEditor/index.html)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$FAILED" = false ]; then
    echo "✅ Build verification PASSED"
    echo ""
    echo "Ready for installation:"
    echo "  cp -R \"$APP_PATH\" /Applications/"
    exit 0
else
    echo "❌ Build verification FAILED"
    echo ""
    echo "Please rebuild:"
    echo "  ./scripts/build.sh"
    exit 1
fi
