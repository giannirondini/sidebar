#!/bin/bash
# Build, sign, and publish a new release to GitHub Releases.
# Names come from Bundler.toml (see scripts/lib/app-config.sh).
#
# Usage:
#   ./scripts/release.sh <version> [--dry-run]
#
#   Signed with the self-signed identity (.signing-config), not notarized (that needs a
#   paid Apple Developer ID). Users clear the quarantine flag once per download (xattr);
#   the release notes say how.
#   --dry-run      Build and sign only, skip git/GitHub operations
#
# Example:
#   ./scripts/release.sh 0.2.0
#   ./scripts/release.sh 0.2.0 --dry-run

set -e

# Parse arguments
usage() {
    echo "Usage: $0 <version> [--dry-run]"
    echo ""
    echo "Examples:"
    echo "  $0 0.2.0            # Full release (self-signed, not notarized)"
    echo "  $0 0.2.0 --dry-run  # Build only, skip git/GitHub"
    exit 1
}

if [ -z "$1" ]; then
    usage
fi

NEW_VERSION="$1"
DRY_RUN=false
for arg in "${@:2}"; do
    case $arg in
        --dry-run) DRY_RUN=true ;;
        *) echo "Unknown argument: $arg"; usage ;;
    esac
done

# Validate version format (semver: X.Y.Z or X.Y.Z-suffix)
if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'; then
    echo "❌ Invalid version format: $NEW_VERSION"
    echo "   Expected: MAJOR.MINOR.PATCH (e.g., 0.2.0, 1.0.0-beta.1)"
    exit 1
fi

# Ensure we're in the project root
cd "$(dirname "$0")/.."
source scripts/lib/app-config.sh

# A release must be signed with the self-signed identity: an ad-hoc release would let
# any app with the bundle id claim the users' grants, and a different identity between
# releases would reset them.
load_signing_config
if [ -z "$LOCAL_SIGNING_IDENTITY" ]; then
    echo "❌ A release needs LOCAL_SIGNING_IDENTITY (.signing-config)"
    echo "   See docs/BUILD_AND_CODESIGN.md › Self-signed identity"
    exit 1
fi

echo "🚀 Releasing $APP_NAME v${NEW_VERSION}"
echo "   (not notarized — signed with \"$LOCAL_SIGNING_IDENTITY\")"
if [ "$DRY_RUN" = true ]; then
    echo "   (dry-run mode — git/GitHub operations will be skipped)"
fi
echo ""

# Check prerequisites
if [ "$DRY_RUN" = false ]; then
    # Check for clean working tree (aside from VERSION and Bundler.toml which we'll change)
    if ! git diff --quiet -- ':!VERSION' ':!Bundler.toml'; then
        echo "❌ Working tree has uncommitted changes. Commit or stash them first."
        exit 1
    fi

    # Check that gh CLI is available
    if ! command -v gh &>/dev/null; then
        echo "❌ GitHub CLI (gh) is required. Install with: brew install gh"
        exit 1
    fi

    # Check that we're on main branch
    CURRENT_BRANCH=$(git branch --show-current)
    if [ "$CURRENT_BRANCH" != "main" ]; then
        echo "⚠️  Warning: You're on branch '$CURRENT_BRANCH', not 'main'"
        read -p "   Continue anyway? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Check that tag doesn't already exist
    if git rev-parse "v${NEW_VERSION}" &>/dev/null; then
        echo "❌ Tag v${NEW_VERSION} already exists"
        exit 1
    fi
fi

# Collect release description for the GitHub release
echo "📝 Preparing release description..."

# Get previous version from VERSION file to find merged PRs
PREV_VERSION=$(cat VERSION | tr -d '[:space:]')

# Build prefilled description from commits since last release
DESC_FILE=$(mktemp "${TMPDIR:-/tmp}/release-desc.XXXXXX")
{
    echo "### What's New"
    echo ""
    if git rev-parse "v${PREV_VERSION}" &>/dev/null; then
        COMMITS=$(git log "v${PREV_VERSION}..HEAD" --format="- %s" | grep -v "^- Release v" 2>/dev/null || true)
        if [ -n "$COMMITS" ]; then
            echo "$COMMITS"
        else
            echo "- "
        fi
    else
        echo "- "
    fi
    echo ""
    echo "# ----------------------------------------"
    echo "# Edit the release description above."
    echo "# Lines starting with # will be removed."
    echo "# Save and close the editor to continue."
    echo "# Delete all content to skip the description."
} > "$DESC_FILE"

echo "   Opening editor to edit release description..."
if git rev-parse "v${PREV_VERSION}" &>/dev/null; then
    echo "   (prefilled with commits since v${PREV_VERSION})"
fi
${VISUAL:-${EDITOR:-vi}} "$DESC_FILE"

# Strip comment lines; command substitution strips trailing newlines
RELEASE_DESCRIPTION=$(grep -v '^#' "$DESC_FILE" | sed '/./,$!d')
rm -f "$DESC_FILE"

if [ -n "$RELEASE_DESCRIPTION" ]; then
    echo "  ✓ Release description captured"
else
    echo "  ℹ️  No description provided, continuing without"
fi
echo ""

# Step 1: Update version
echo "📌 Step 1: Updating version to ${NEW_VERSION}..."
echo "$NEW_VERSION" > VERSION
echo "  ✓ VERSION file updated"
echo ""

# Step 2: Build the DMG
echo "────────────────────────────────────────"
echo "📦 Step 2: Building DMG (self-signed, not notarized)..."
./scripts/build.sh --dmg
echo "────────────────────────────────────────"
echo ""

# Verify DMG was created
DMG_PATH=".build/dmg/${APP_NAME}-${NEW_VERSION}.dmg"
if [ ! -f "$DMG_PATH" ]; then
    echo "❌ DMG not found at $DMG_PATH"
    exit 1
fi
echo "  ✓ DMG ready: $DMG_PATH"

echo ""

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "✅ Dry run complete!"
    echo ""
    echo "Artifacts:"
    echo "  📦 DMG: $DMG_PATH"
    echo ""
    echo "To finish the release manually:"
    echo "  git add VERSION Bundler.toml"
    echo "  git commit -m 'Release v${NEW_VERSION}'"
    echo "  git tag -a v${NEW_VERSION} -m 'Release version ${NEW_VERSION}'"
    echo "  git push origin main v${NEW_VERSION}"
    echo "  gh release create v${NEW_VERSION} ${DMG_PATH} --title 'v${NEW_VERSION}'"
    exit 0
fi

# Step 3: Commit changes
echo ""
echo "📝 Step 3: Committing release changes..."
git add VERSION Bundler.toml
git commit -m "Release v${NEW_VERSION}"
echo "  ✓ Changes committed"

# Step 4: Tag and push
echo ""
echo "🏷️  Step 4: Tagging and pushing..."
git tag -a "v${NEW_VERSION}" -m "Release version ${NEW_VERSION}"
git push origin main "v${NEW_VERSION}"
echo "  ✓ Pushed to origin with tag v${NEW_VERSION}"

# Step 5: Create GitHub Release
echo ""
echo "🐙 Step 5: Creating GitHub Release..."
if [ -n "$RELEASE_DESCRIPTION" ]; then
    GH_RELEASE_NOTES="## $APP_NAME v${NEW_VERSION}

${RELEASE_DESCRIPTION}"
else
    GH_RELEASE_NOTES="## $APP_NAME v${NEW_VERSION}"
fi
GH_RELEASE_NOTES="${GH_RELEASE_NOTES}

### Install
This build isn't notarized by Apple, so macOS blocks it until the download's quarantine flag is cleared. After dragging **${APP_NAME}.app** to Applications, run once:

\`\`\`bash
xattr -dr com.apple.quarantine /Applications/${APP_NAME}.app
\`\`\`

Accessibility and Automation permissions carry over from the previous release."
gh release create "v${NEW_VERSION}" "$DMG_PATH" \
    --title "v${NEW_VERSION}" \
    --notes "$GH_RELEASE_NOTES"
echo "  ✓ GitHub Release created"

echo ""
echo "════════════════════════════════════════"
echo "✅ $APP_NAME v${NEW_VERSION} released!"
echo ""
echo "  📦 DMG: $DMG_PATH"
echo "  🏷️  Tag: v${NEW_VERSION}"
echo "  🐙 Release: $(gh release view "v${NEW_VERSION}" --json url --jq .url 2>/dev/null)"
echo ""
echo "Users update by downloading the DMG (\"Check for Updates…\" opens the releases page)."
echo "════════════════════════════════════════"
