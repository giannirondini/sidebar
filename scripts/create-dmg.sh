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
# Everything is built in a temporary folder and moved into place only when it all
# succeeded. A rerun (e.g. after tagging) keeps an existing RELEASE_NOTES.md (the
# fresh one is written as RELEASE_NOTES.new.md) and moves the previous DMG and
# checksums to previous-<timestamp>/.
#
# Nothing is committed, tagged, pushed or published: you review the notes and run
# the commands yourself (scripts/README.md).
#
# Prerequisites:
#   brew install create-dmg
#   ./scripts/build.sh <version>    (release build, signed with the certificate
#                                    in scripts/release-signing-cert.sha256)
#
# Usage:
#   ./scripts/create-dmg.sh [version] [--allow-adhoc]
#
#   version         defaults to the VERSION file; must match the built app
#   --allow-adhoc   accept an app not signed with the release certificate: writes
#                   only .build/release/<version>-adhoc/SidebArc-<version>-adhoc.dmg,
#                   a local test DMG, never a release. A run without the flag
#                   deletes that folder.
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

RELEASE_ROOT=".build/release"
RELEASE_DIR="$RELEASE_ROOT/$VERSION"
ADHOC_DIR="$RELEASE_ROOT/$VERSION-adhoc"
TAG="v$VERSION"
REPO_URL="https://github.com/giannirondini/sidebarc"
DMG_BACKGROUND="Resources/dmg-background.png"
VOLUME_ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# A test DMG never outlives the next real run, refused or not.
if [ "$ALLOW_ADHOC" != true ] && [ -d "$ADHOC_DIR" ]; then
    rm -rf "$ADHOC_DIR"
    print_info "Removed the test DMG folder $ADHOC_DIR"
fi

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

# run.sh writes a debug build to the same path: package only what build.sh made.
BUILT_CONFIGURATION=$(/usr/libexec/PlistBuddy -c "Print :$BUILD_CONFIGURATION_KEY" "$INFO_PLIST" 2>/dev/null || echo "")
if [ "$BUILT_CONFIGURATION" != "release" ]; then
    print_error "The built app isn't a release build ($BUILD_CONFIGURATION_KEY: ${BUILT_CONFIGURATION:-not set})"
    print_info "Run ./scripts/build.sh $VERSION (./scripts/run.sh makes a debug build at the same path)"
    exit 1
fi

# The bundle checks (identifier, usage strings, note editor, valid signature).
if ! VERIFY_OUTPUT=$(./scripts/verify-build.sh 2>&1); then
    echo "$VERIFY_OUTPUT"
    print_error "./scripts/verify-build.sh failed (above)"
    exit 1
fi

# A release must carry the release certificate, compared by hash: an ad-hoc
# release would let any app with the bundle id claim the users' permissions, and
# any other certificate (even a recreated one with the same name) would reset them.
SIGNING_AUTHORITY=$(codesign -dvv "$APP_BUNDLE" 2>&1 | sed -n 's/^Authority=//p' | head -1)
CERT_SHA256=$(leaf_cert_sha256 "$APP_BUNDLE")
EXPECTED_CERT_SHA256=$(expected_release_cert_sha256)
if [ -n "$CERT_SHA256" ] && [ "$CERT_SHA256" = "$EXPECTED_CERT_SHA256" ]; then
    RELEASE_BUILD=true
    print_info "Signed by: $SIGNING_AUTHORITY (release certificate $CERT_SHA256)"
elif [ "$ALLOW_ADHOC" = true ]; then
    RELEASE_BUILD=false
    print_warning "Not signed with the release certificate (--allow-adhoc): a local test DMG, don't publish it"
else
    print_error "The app isn't signed with the release certificate"
    print_info "Signed by:   ${SIGNING_AUTHORITY:-ad-hoc}${CERT_SHA256:+ (SHA-256 $CERT_SHA256)}"
    print_info "Release:     ${EXPECTED_CERT_SHA256:-not recorded} (scripts/release-signing-cert.sha256)"
    print_info "Set up .signing-config with the release certificate (docs/BUILD_AND_CODESIGN.md › Self-signed identity)"
    print_info "and rebuild, or pass --allow-adhoc for a local test DMG"
    exit 1
fi

# Finder draws the background at its size in points (pixels × 72 / DPI): a 600 × 400
# image tagged 300 DPI shows as 144 × 96 in the top-left corner. It must be 600 × 400 pt.
if [ -f "$DMG_BACKGROUND" ]; then
    BG_INFO=$(sips -g pixelWidth -g pixelHeight -g dpiWidth -g dpiHeight "$DMG_BACKGROUND" 2>/dev/null)
    BG_POINTS=$(echo "$BG_INFO" | awk '
        /pixelWidth/ {pw = $2} /pixelHeight/ {ph = $2} /dpiWidth/ {dw = $2} /dpiHeight/ {dh = $2}
        END { if (!dw) dw = 72; if (!dh) dh = 72; printf "%d x %d", pw * 72 / dw + 0.5, ph * 72 / dh + 0.5 }')
    if [ "$BG_POINTS" != "600 x 400" ]; then
        print_error "$DMG_BACKGROUND is $BG_POINTS points; the DMG window is 600 x 400"
        print_info "600 x 400 px:  sips -s dpiWidth 72 -s dpiHeight 72 $DMG_BACKGROUND"
        print_info "1200 x 800 px: sips -s dpiWidth 144 -s dpiHeight 144 $DMG_BACKGROUND  (sharp on Retina)"
        exit 1
    fi
fi

print_success "Environment validation passed"

###############################################################################
# Prepare
###############################################################################

if [ "$RELEASE_BUILD" = true ]; then
    OUT_DIR="$RELEASE_DIR"
    DMG_NAME="$APP_NAME-$VERSION.dmg"
else
    OUT_DIR="$ADHOC_DIR"
    DMG_NAME="$APP_NAME-$VERSION-adhoc.dmg"
fi
DMG_PATH="$OUT_DIR/$DMG_NAME"

# detach_images_under <dir>: detaches every disk image whose file is inside <dir>
# (create-dmg mounts its read-write image at /Volumes/dmg.XXXXXX; a failed or
# interrupted run can leave it attached).
detach_images_under() {
    local dev
    for dev in $(hdiutil info 2>/dev/null | awk -v dir="$1/" '
        /^image-path[ \t]*:/ { p = $0; sub(/^image-path[ \t]*:[ \t]*/, "", p); hit = (index(p, dir) == 1); next }
        /^=+$/ { hit = 0; next }
        hit && $1 ~ /^\/dev\/disk[0-9]+$/ { print $1; hit = 0 }'); do
        hdiutil detach "$dev" -quiet 2>/dev/null \
            || hdiutil detach "$dev" -force -quiet 2>/dev/null \
            || print_warning "Could not detach $dev (hdiutil detach $dev -force)"
    done
}

cleanup_work_dir() {
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        detach_images_under "$WORK_DIR"
        rm -rf "$WORK_DIR"
    fi
}

print_step "Preparing a temporary build folder..."

mkdir -p "$RELEASE_ROOT"
RELEASE_ROOT_ABS=$(cd "$RELEASE_ROOT" && pwd -P)
# Leftovers of a run that was killed before its own cleanup.
for stale in "$RELEASE_ROOT_ABS"/.dmg-build.*; do
    [ -d "$stale" ] || continue
    detach_images_under "$stale"
    rm -rf "$stale"
done
WORK_DIR=$(mktemp -d "$RELEASE_ROOT_ABS/.dmg-build.XXXXXX")
trap cleanup_work_dir EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STAGING_DIR="$WORK_DIR/staging"
WORK_DMG="$WORK_DIR/$DMG_NAME"
mkdir -p "$STAGING_DIR"
# create-dmg copies the contents of the folder it's given: stage the app in one.
cp -R "$APP_BUNDLE" "$STAGING_DIR/"

print_success "Build folder ready"

###############################################################################
# Create DMG
###############################################################################

print_step "Creating DMG installer..."

# Layout: 600 × 400 window, the app on the left and the Applications link on the
# right (docs/ASSETS.md › DMG background).
DMG_OPTIONS=(
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
    DMG_OPTIONS+=(--background "$DMG_BACKGROUND")
else
    print_info "No $DMG_BACKGROUND: default Finder background"
fi
if [ -f "$VOLUME_ICON" ]; then
    DMG_OPTIONS+=(--volicon "$VOLUME_ICON")
fi

# create-dmg 1.3.0 exits 64, with no DMG, when the Finder-styling AppleScript fails
# (usually: the terminal may not control Finder). Retry once without the styling;
# any other failure stops here.
STYLING_SKIPPED=false
set +e
create-dmg "${DMG_OPTIONS[@]}" "$WORK_DMG" "$STAGING_DIR"
CREATE_DMG_STATUS=$?
set -e
if [ "$CREATE_DMG_STATUS" -eq 64 ]; then
    print_warning "The Finder styling failed (create-dmg exit 64); retrying without it (--skip-jenkins)"
    detach_images_under "$WORK_DIR"
    rm -f "$WORK_DIR"/*.dmg
    STYLING_SKIPPED=true
    set +e
    create-dmg "${DMG_OPTIONS[@]}" --skip-jenkins "$WORK_DMG" "$STAGING_DIR"
    CREATE_DMG_STATUS=$?
    set -e
fi
if [ "$CREATE_DMG_STATUS" -ne 0 ] || [ ! -f "$WORK_DMG" ]; then
    print_error "DMG creation failed (create-dmg exit $CREATE_DMG_STATUS, see its output above)"
    exit 1
fi
if ! hdiutil verify -quiet "$WORK_DMG"; then
    print_error "hdiutil verify failed for $WORK_DMG"
    exit 1
fi

print_success "DMG created: $DMG_NAME ($(du -sh "$WORK_DMG" | cut -f1))"

CHECKSUM=$(shasum -a 256 "$WORK_DMG" | cut -d' ' -f1)

###############################################################################
# Test DMG (--allow-adhoc): the DMG only, no notes, no publishing steps
###############################################################################

if [ "$RELEASE_BUILD" != true ]; then
    rm -rf "$ADHOC_DIR"
    mkdir -p "$ADHOC_DIR"
    mv "$WORK_DMG" "$DMG_PATH"
    echo ""
    print_rule
    print_warning "Local test DMG (not signed with the release certificate): don't publish it"
    print_rule
    print_info "DMG:     $DMG_PATH"
    print_info "SHA-256: $CHECKSUM"
    if [ "$STYLING_SKIPPED" = true ]; then
        print_warning "Default Finder layout: allow the terminal to control Finder and rerun for the styled window"
    fi
    print_rule
    exit 0
fi

###############################################################################
# Release notes
###############################################################################

print_step "Creating release notes..."

# What's New: commit subjects since the previous tag (none yet: first release).
PREVIOUS_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [ "$PREVIOUS_TAG" = "$TAG" ]; then
    # Rerun after tagging this version: compare with the tag before it.
    PREVIOUS_TAG=$(git describe --tags --abbrev=0 "$TAG^" 2>/dev/null || true)
fi
if [ -n "$PREVIOUS_TAG" ]; then
    LAST_COMMIT=$(git rev-parse -q --verify "$TAG^{commit}" 2>/dev/null || echo HEAD)
    WHATS_NEW=$(git log "$PREVIOUS_TAG..$LAST_COMMIT" --no-merges --format='- %s' | grep -v '^- chore(release)' || true)
    WHATS_NEW_SOURCE="commits since $PREVIOUS_TAG"
else
    WHATS_NEW="- First release."
    WHATS_NEW_SOURCE="no previous tag"
fi
[ -n "$WHATS_NEW" ] || WHATS_NEW="- "

ARCHS=$(lipo -archs "$APP_EXECUTABLE" 2>/dev/null || echo "unknown")
case "$ARCHS" in
    arm64) ARCH_TEXT="Apple silicon" ;;
    x86_64) ARCH_TEXT="Intel" ;;
    "x86_64 arm64"|"arm64 x86_64") ARCH_TEXT="Apple silicon or Intel" ;;
    *) ARCH_TEXT="$ARCHS" ;;
esac
MIN_MACOS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST" 2>/dev/null || echo "13.0")

cat > "$WORK_DIR/RELEASE_NOTES.md" <<NOTES
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

- macOS $MIN_MACOS or later, on $ARCH_TEXT ($ARCHS)

## Checksum

\`\`\`
$CHECKSUM  $DMG_NAME
\`\`\`
NOTES

print_success "Release notes created ($WHATS_NEW_SOURCE)"

###############################################################################
# Upload instructions
###############################################################################

BRANCH=$(git branch --show-current 2>/dev/null || echo "main")

cat > "$WORK_DIR/UPLOAD_INSTRUCTIONS.md" <<STEPS
# Publishing $APP_NAME $VERSION

Run these from the repository root. Nothing has been committed, tagged or pushed yet.

## 1. Review

- Edit \`$RELEASE_DIR/RELEASE_NOTES.md\` (What's New lists the $WHATS_NEW_SOURCE). Its checksum must be \`$CHECKSUM\`.
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

###############################################################################
# Move into the release folder
###############################################################################

print_step "Moving the release files into $RELEASE_DIR..."

mkdir -p "$RELEASE_DIR"

# A rerun replaces the DMG (a new build has a new checksum): keep the previous one.
PREVIOUS_DIR=""
if [ -f "$DMG_PATH" ]; then
    OLD_CHECKSUM=$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)
    if [ "$OLD_CHECKSUM" != "$CHECKSUM" ]; then
        PREVIOUS_DIR="$RELEASE_DIR/previous-$(date -u +%Y%m%dT%H%M%SZ)"
        mkdir -p "$PREVIOUS_DIR"
        mv "$DMG_PATH" "$PREVIOUS_DIR/"
        [ -f "$RELEASE_DIR/checksums.txt" ] && mv "$RELEASE_DIR/checksums.txt" "$PREVIOUS_DIR/"
    fi
fi
mv "$WORK_DMG" "$DMG_PATH"
echo "$CHECKSUM  $DMG_NAME" > "$RELEASE_DIR/checksums.txt"
mv "$WORK_DIR/UPLOAD_INSTRUCTIONS.md" "$RELEASE_DIR/UPLOAD_INSTRUCTIONS.md"

# Never overwrite notes you may have edited.
NOTES_PATH="$RELEASE_DIR/RELEASE_NOTES.md"
NOTES_STALE=false
if [ -f "$NOTES_PATH" ]; then
    if cmp -s "$WORK_DIR/RELEASE_NOTES.md" "$NOTES_PATH"; then
        rm -f "$RELEASE_DIR/RELEASE_NOTES.new.md"
    else
        mv "$WORK_DIR/RELEASE_NOTES.md" "$RELEASE_DIR/RELEASE_NOTES.new.md"
        grep -qF "$CHECKSUM" "$NOTES_PATH" || NOTES_STALE=true
    fi
else
    mv "$WORK_DIR/RELEASE_NOTES.md" "$NOTES_PATH"
fi

print_success "Release files in place"

###############################################################################
# Summary
###############################################################################

echo ""
print_rule
print_success "Release files ready: $APP_NAME $VERSION"
print_rule
echo ""
print_info "DMG:                 $DMG_PATH"
print_info "SHA-256:             $CHECKSUM"
print_info "Release notes:       $NOTES_PATH"
print_info "Checksums:           $RELEASE_DIR/checksums.txt"
print_info "Upload instructions: $RELEASE_DIR/UPLOAD_INSTRUCTIONS.md"
if [ -n "$PREVIOUS_DIR" ]; then
    print_warning "The previous DMG and checksums.txt are in $PREVIOUS_DIR (checksum $OLD_CHECKSUM)"
fi
if [ -f "$RELEASE_DIR/RELEASE_NOTES.new.md" ]; then
    print_warning "RELEASE_NOTES.md was kept; the freshly generated notes are RELEASE_NOTES.new.md"
fi
if [ "$NOTES_STALE" = true ]; then
    print_warning "RELEASE_NOTES.md doesn't contain this DMG's checksum: replace it with $CHECKSUM"
fi
if [ "$STYLING_SKIPPED" = true ]; then
    print_warning "The DMG has the default Finder layout: allow the terminal to control Finder"
    print_warning "(System Settings › Privacy & Security › Automation) and rerun for the styled window"
fi
echo ""
print_warning "Next steps:"
echo "  1. Test the DMG:   open \"$DMG_PATH\""
echo "  2. Edit the notes: $NOTES_PATH"
echo "  3. Publish:        follow $RELEASE_DIR/UPLOAD_INSTRUCTIONS.md"
echo ""
print_rule
