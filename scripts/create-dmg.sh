#!/bin/bash
###############################################################################
# SidebArc - DMG and release files
#
# Creates the DMG installer with Homebrew's create-dmg, plus everything needed to
# publish it, in .build/release/<version>/:
#
#   SidebArc-<version>.dmg     the installer
#   RELEASE_NOTES.md           What's New (from the commits since the last tag),
#                              install steps (xattr), permissions, checksum
#   checksums.txt              SHA-256 of the DMG
#   UPLOAD_INSTRUCTIONS.md     the git and gh commands to publish, ready to paste
#
# Nothing is committed, tagged, pushed or published: you review the notes and run
# the commands yourself (scripts/README.md).
#
# Prerequisites:
#   brew install create-dmg
#   ./scripts/build.sh <version>    (signed with the identity in .signing-config)
#
# Usage:
#   ./scripts/create-dmg.sh [version] [--allow-adhoc]
#
#   version         defaults to the VERSION file; must match the built app
#   --allow-adhoc   accept an ad-hoc signed app (a local test DMG, never a release)
#
# Example:
#   ./scripts/create-dmg.sh 1.1.0
###############################################################################

set -e

cd "$(dirname "$0")/.."
source scripts/lib/app-config.sh

VERSION=""
ALLOW_ADHOC=false
for arg in "$@"; do
    case $arg in
        --allow-adhoc) ALLOW_ADHOC=true ;;
        -*) print_error "Unknown option: $arg"; echo "Usage: $0 [version] [--allow-adhoc]" >&2; exit 1 ;;
        *)
            if [ -n "$VERSION" ]; then
                print_error "Usage: $0 [version] [--allow-adhoc]"
                exit 1
            fi
            VERSION="$arg"
            ;;
    esac
done
VERSION="${VERSION:-$(current_version)}"

RELEASE_DIR=".build/release/$VERSION"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
STAGING_DIR="$RELEASE_DIR/dmg-staging"
TAG="v$VERSION"
REPO_URL="https://github.com/giannirondini/sidebarc"
DMG_BACKGROUND="Resources/dmg-background.png"
VOLUME_ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"

###############################################################################
# Validation
###############################################################################

print_step "Validating environment..."

if [[ "$OSTYPE" != "darwin"* ]]; then
    print_error "This script must be run on macOS"
    exit 1
fi
if ! is_valid_version "$VERSION"; then
    print_error "Invalid version: $VERSION (expected MAJOR.MINOR.PATCH, e.g. 1.1.0)"
    exit 1
fi
if ! command -v create-dmg &>/dev/null; then
    print_error "Required command 'create-dmg' not found."
    print_info "Install with: brew install create-dmg"
    exit 1
fi
if [ ! -d "$APP_BUNDLE" ]; then
    print_error "App bundle not found: $APP_BUNDLE"
    print_info "Run ./scripts/build.sh $VERSION first"
    exit 1
fi

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || echo "?")
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    print_error "The built app is version $BUILT_VERSION, not $VERSION"
    print_info "Run ./scripts/build.sh $VERSION first"
    exit 1
fi

# The bundle checks (identifier, usage strings, note editor, valid signature).
if ! VERIFY_OUTPUT=$(./scripts/verify-build.sh 2>&1); then
    echo "$VERIFY_OUTPUT"
    print_error "./scripts/verify-build.sh failed (above)"
    exit 1
fi

# A release must carry the self-signed identity: an ad-hoc release would let any
# app with the bundle id claim the users' permissions, and another identity would
# reset them on update.
load_signing_config
SIGNING_AUTHORITY=$(codesign -dvv "$APP_BUNDLE" 2>&1 | sed -n 's/^Authority=//p' | head -1)
if [ -n "$LOCAL_SIGNING_IDENTITY" ] && [ "$SIGNING_AUTHORITY" = "$LOCAL_SIGNING_IDENTITY" ]; then
    print_info "Signed by: $SIGNING_AUTHORITY"
elif [ "$ALLOW_ADHOC" = true ]; then
    print_warning "Signed ad-hoc (--allow-adhoc): a local test DMG, don't publish it"
else
    print_error "The app isn't signed with your identity (signed by: ${SIGNING_AUTHORITY:-ad-hoc})"
    print_info "Set up .signing-config (docs/BUILD_AND_CODESIGN.md › Self-signed identity) and rebuild,"
    print_info "or pass --allow-adhoc for a local test DMG"
    exit 1
fi

print_success "Environment validation passed"

###############################################################################
# Prepare
###############################################################################

print_step "Preparing $RELEASE_DIR..."

rm -rf "$RELEASE_DIR"
mkdir -p "$STAGING_DIR"
# create-dmg copies the contents of the folder it's given: stage the app in one.
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
if [ -d "/Volumes/$APP_NAME $VERSION" ]; then
    hdiutil detach "/Volumes/$APP_NAME $VERSION" -quiet 2>/dev/null || true
fi

print_success "Release folder ready"

###############################################################################
# Create DMG
###############################################################################

print_step "Creating DMG installer..."

# Layout: 600 × 400 window, the app on the left and the Applications link on the
# right (docs/ASSETS.md › DMG background).
DMG_ARGS=(
    --volname "$APP_NAME $VERSION"
    --window-pos 200 120
    --window-size 600 400
    --icon-size 180
    --text-size 14
    --icon "$APP_NAME.app" 160 200
    --hide-extension "$APP_NAME.app"
    --app-drop-link 460 200
    --hdiutil-quiet
)
if [ -f "$DMG_BACKGROUND" ]; then
    DMG_ARGS+=(--background "$DMG_BACKGROUND")
else
    print_info "No $DMG_BACKGROUND: default Finder background"
fi
if [ -f "$VOLUME_ICON" ]; then
    DMG_ARGS+=(--volicon "$VOLUME_ICON")
fi
DMG_ARGS+=("$DMG_PATH" "$STAGING_DIR")

# create-dmg can exit non-zero when only the Finder styling failed; the DMG
# file is what counts.
create-dmg "${DMG_ARGS[@]}" || true
rm -rf "$STAGING_DIR"

if [ ! -f "$DMG_PATH" ]; then
    print_error "DMG creation failed (see the create-dmg output above)"
    exit 1
fi
if ! hdiutil verify -quiet "$DMG_PATH"; then
    print_error "hdiutil verify failed for $DMG_PATH"
    exit 1
fi

print_success "DMG created: $DMG_NAME ($(du -sh "$DMG_PATH" | cut -f1))"

###############################################################################
# Checksums
###############################################################################

print_step "Generating checksums..."

(cd "$RELEASE_DIR" && shasum -a 256 "$DMG_NAME") > "$RELEASE_DIR/checksums.txt"
CHECKSUM=$(cut -d' ' -f1 < "$RELEASE_DIR/checksums.txt")

print_success "SHA-256: $CHECKSUM"

###############################################################################
# Release notes
###############################################################################

print_step "Creating release notes..."

# What's New: commit subjects since the previous tag (none yet: first release).
PREVIOUS_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ -n "$PREVIOUS_TAG" ] && [ "$PREVIOUS_TAG" != "$TAG" ]; then
    WHATS_NEW=$(git log "$PREVIOUS_TAG..HEAD" --no-merges --format='- %s' | grep -v '^- chore(release)' || true)
    WHATS_NEW_SOURCE="commits since $PREVIOUS_TAG"
else
    WHATS_NEW="- First release."
    WHATS_NEW_SOURCE="no previous tag"
fi
[ -n "$WHATS_NEW" ] || WHATS_NEW="- "

ARCHS=$(lipo -archs "$APP_EXECUTABLE" 2>/dev/null || echo "unknown")
MIN_MACOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST" 2>/dev/null || echo "13.0")

cat > "$RELEASE_DIR/RELEASE_NOTES.md" <<NOTES
## What's New

$WHATS_NEW

## Installation

1. Download \`$DMG_NAME\` and open it.
2. Drag **$APP_NAME** onto **Applications**.
3. $APP_NAME is signed but not notarized by Apple (that needs a paid developer account), so macOS blocks it the first time. Clear the download's quarantine flag once:
   \`\`\`bash
   xattr -dr com.apple.quarantine /Applications/$APP_NAME.app
   \`\`\`
   (Or **System Settings** → **Privacy & Security** → **Open Anyway**.)
4. Launch $APP_NAME from Applications.

**Updating:** quit $APP_NAME, replace the app and repeat step 3. Your data (\`~/Library/Application Support/$BUNDLE_ID/\`) and the Accessibility and Automation permissions carry over.

## Permissions

- **Accessibility**, to attach the sidebar to your browser's window (not needed as a standalone window).
- **Automation**, to switch to a tab that's already open (Chrome, Brave, Safari): **Settings** → **Permissions** → **Allow Browser Access…**

## Requirements

- macOS $MIN_MACOS or later ($ARCHS)

## Checksum

\`\`\`
$CHECKSUM  $DMG_NAME
\`\`\`
NOTES

print_success "Release notes created ($WHATS_NEW_SOURCE)"

###############################################################################
# Upload instructions
###############################################################################

print_step "Creating upload instructions..."

BRANCH=$(git branch --show-current 2>/dev/null || echo "main")

cat > "$RELEASE_DIR/UPLOAD_INSTRUCTIONS.md" <<STEPS
# Publishing $APP_NAME $VERSION

Run these from the repository root. Nothing has been committed, tagged or pushed yet.

## 1. Review

- Edit \`$RELEASE_DIR/RELEASE_NOTES.md\` (What's New lists the $WHATS_NEW_SOURCE).
- Test the DMG: \`open "$DMG_PATH"\`, install, launch.

## 2. Commit the version

\`\`\`bash
git add VERSION Bundler.toml
git commit -m "chore(release): $TAG"
\`\`\`

(Skip if \`git status\` shows nothing to commit.)

## 3. Tag and push

\`\`\`bash
git tag -a $TAG -m "$APP_NAME $VERSION"
git push origin $BRANCH $TAG
\`\`\`

Releases normally come from \`main\`; you're on \`$BRANCH\`.

## 4. Publish

\`\`\`bash
gh release create $TAG \\
  "$DMG_PATH" \\
  "$RELEASE_DIR/checksums.txt" \\
  --verify-tag \\
  --title "$APP_NAME $VERSION" \\
  --notes-file "$RELEASE_DIR/RELEASE_NOTES.md"
\`\`\`

Or by hand: $REPO_URL/releases/new → tag \`$TAG\` → title "$APP_NAME $VERSION" → paste RELEASE_NOTES.md → attach the DMG and checksums.txt → Publish.

## 5. Check

- The release page shows the notes and both files: $REPO_URL/releases/tag/$TAG
- Download the DMG on another Mac, install it with the \`xattr\` step, launch it.
- "Check for Updates…" in the app opens the releases page.
STEPS

print_success "Upload instructions created"

###############################################################################
# Summary
###############################################################################

echo ""
print_rule
print_success "Release files ready: $APP_NAME $VERSION"
print_rule
echo ""
print_info "DMG:                 $DMG_PATH"
print_info "Release notes:       $RELEASE_DIR/RELEASE_NOTES.md"
print_info "Checksums:           $RELEASE_DIR/checksums.txt"
print_info "Upload instructions: $RELEASE_DIR/UPLOAD_INSTRUCTIONS.md"
echo ""
print_warning "Next steps:"
echo "  1. Test the DMG:   open \"$DMG_PATH\""
echo "  2. Edit the notes: $RELEASE_DIR/RELEASE_NOTES.md"
echo "  3. Publish:        follow $RELEASE_DIR/UPLOAD_INSTRUCTIONS.md"
echo ""
print_rule
