# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SidebArc is a macOS bookmark management application built with Swift and AppKit (a fork of Arcmark; Swift package `SidebArc`, modules `SidebArcCore` (library), `SidebArcApp` (entry point) and `SidebArcTests`). It provides a workspace-based organization system for links and folders with features like drag-and-drop, inline editing, and automatic favicon/title fetching.

## Development Commands

**IMPORTANT**: Never run `./scripts/run.sh` or any build/run scripts automatically. The user will run these scripts in the background when needed.

### Building and Testing
```bash
# Development builds (ad-hoc signing)
./scripts/build.sh                  # Build app only
./scripts/build.sh --dmg            # Build app and create DMG

# Production builds (Developer ID + notarization)
./scripts/build.sh --production     # Build with Developer ID signing
./scripts/build.sh --production --dmg  # Build and create notarized DMG

# Release (build + sign + tag + push + GitHub release)
./scripts/release.sh 0.2.0         # Full release
./scripts/release.sh 0.2.0 --dry-run  # Build only, skip git/GitHub

# Other commands
./scripts/create-dmg.sh             # Create DMG from existing build
./scripts/run.sh                    # Build and run the app

# Testing (swift-testing; the plugin path works around an intermittent
# "TestingMacros plugin not found" build failure with Command Line Tools only)
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
# Single test: --filter is a regex over "Suite/testName"
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" --filter 'ModelTests/testJSONRoundTrip\('

# Library build (Swift PM only)
swift build -c release
```

**Prerequisite:** `brew install mint`. swift-bundler runs through Mint at the revision pinned in `Mintfile`; the first build installs it.

**App identity:** `Bundler.toml` is the single source. Its `[apps.SidebArc]` key names `SidebArc.app` and the executable inside it; `identifier` is the bundle id (`io.github.giannirondini.sidebarc`). Scripts read both via `scripts/lib/app-config.sh`; Swift mirrors them in `AppIdentity` (`Constants.swift`), and `AppIdentityTests` fails if they drift. There is no in-app updater: "Check for Updates…" opens `AppIdentity.releasesURL`.

**Build System:** The app uses Swift Bundler to create macOS app bundles. The build script automatically:
- Reads version from `VERSION` file and syncs to Bundler.toml
- Builds the app with Swift Bundler
- Patches Info.plist to ensure CFBundleIdentifier is present
- Code signs the app (ad-hoc for development, Developer ID for production)
- Verifies the build
- Optionally creates a DMG installer with `--dmg` flag
- Optionally notarizes the DMG with `--production --dmg`

**Production Signing**: For distribution outside the Mac App Store, use `--production` flag with proper code signing credentials configured in `.notarization-config`. See [docs/PRODUCTION_SIGNING.md](docs/PRODUCTION_SIGNING.md) for setup.

See [docs/BUILD_AND_CODESIGN.md](docs/BUILD_AND_CODESIGN.md) for detailed information about the build process, code signing, and verification.

### Version Management

The app version is managed through a centralized `VERSION` file in the project root. To update the version:

```bash
echo "0.2.0" > VERSION
```

The build script automatically reads this file and updates `Bundler.toml` and Info.plist accordingly. The version follows [Semantic Versioning](https://semver.org/): `MAJOR.MINOR.PATCH`.

For complete distribution workflow including DMG creation and beta testing, see [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md).

## Architecture

### Data Flow Architecture

The application follows a unidirectional data flow pattern:

1. **AppModel** - Central state manager that owns `AppState` and coordinates all mutations
   - Single source of truth for application state
   - Exposes an `onChange` callback for UI updates
   - All state mutations go through AppModel methods (no direct state manipulation)
   - Automatically persists to disk via `DataStore` after every mutation

2. **DataStore** - Handles persistence layer
   - Saves/loads JSON to `~/Library/Application Support/io.github.giannirondini.sidebarc/data.json` (folder named after the bundle id, `AppIdentity.dataDirectoryName`)
   - Manages favicon storage in `Icons/` subdirectory
   - Provides default state initialization

3. **MainViewController** - Primary UI controller
   - Observes AppModel via `onChange` callback
   - Manages NSCollectionView for hierarchical node display
   - Handles drag-and-drop, inline editing, and context menus
   - Never directly mutates state - always calls AppModel methods

### Core Data Model

The data model is defined in `Models.swift`:

- **AppState** - Root container: `schemaVersion` (currently 2), `profiles`, `workspaces`, selected workspace ID, `isSettingsSelected`
- **Profile** - Groups spaces that share a browser setup and the Favorites grid: `name`, `browserBundleId` (nil = global default browser), `browserProfiles` (browser bundle id → browser profile dir), `favorites: [Link]` (max `Profile.maxFavorites` = 12)
- **Workspace** - Named, colored container with hierarchical `items` and a `profileId` (every space belongs to exactly one profile)
- **Node** - Enum of `Folder`, `Link` or `Note`
  - `Folder` - Contains nested children and isExpanded state
  - `Link` - URL, title, optional favicon path, custom icon, schedule, and `browserBundleId` (per-link browser override)
  - `Note` - Title and custom icon; the body is a `.md` file in `Notes/`

All models are Codable and use UUID-based identification. The Node enum uses custom encoding to serialize the tagged union structure.

**Schema versions.** `DataStore.load()` reads `schemaVersion` first (`SchemaVersionProbe`). A v1 file is decoded by the read-only `SchemaV1` mirror and upgraded by the pure `SchemaMigration.v1ToV2` (`Persistence/SchemaMigration.swift`); the bytes are first copied to `Backups/pre-v2-migration-<ts>.json`, which the 10-file backup rotation never prunes, then the result is saved. Every load runs `AppState.repaired()` (at least one profile; dangling `profileId`s fall back to the first). The v2 model carries no legacy fields; add a new `SchemaVn` mirror + migration for the next change instead.

### Profiles, Favorites and browser routing

- **Favorites** are the tile grid at the top (`PinnedTabsView`), stored on the space's **profile**, so all spaces in a profile show the same grid. `pinLink` moves a list link into the current profile's favorites; `unpinLink` moves it into the *current* space's list (as in Arc). Async updates (favicons) find a favorite in any profile.
- **Where a link opens:** `BrowserManager.resolveTarget(link:profile:)` → link override → profile's browser → global default (`UserDefaults`). A browser that isn't installed is skipped (next level applies). The browser profile dir is `profile.browserProfiles[browser]` only when the browser is the profile's own; an override to another browser opens without one. Notes open like links without an override (the space's profile). Window attachment and the global browser picker deliberately stay on the global default.
- **Deleting a profile** moves its spaces to the first remaining profile and merges its favorites there (dedupe by `URLNormalization.key`, cap 12); what doesn't fit goes into a "Favorites (from <name>)" folder. The last profile can't be deleted. New spaces join the current space's profile.
- **Never drop links:** migration, profile deletion and Arc import all use `Profile.appendFavorites`, which returns the leftovers; callers put them in a folder.
- **UI:** Settings › Profiles (`ProfileSettingsView`: browser and browser-profile pickers, rename/delete); space menus › Profile ▸; link/favorite menus › Open in ▸ / Always open in ▸ (`BrowserMenus`); an override shows the browser icon as a badge (warning symbol if not installed).
- **Arc import** maps each Arc profile (`space.profile`, `topAppsContainerIDs` pairs) to the fork profile with the same name ("Default" for Arc's default) and imports its favorites (`AppModel.applyArcImport`).
- **Agent API v2** (`NoteServer`, `skills/sidebarc`): `/api/profiles` (list, create, patch name/browser; no delete), `/api/profiles/:id/favorites`, `/api/favorites/:id` (move, unpin, delete), `profileId` on workspace payloads, `browser_bundle_id` on link patch. The endpoint file reports `schemaVersion: 2` (API version, not the data schema).

### Key Components

**Services** (all MainActor singletons):
- **FaviconService** - Async favicon fetching with disk caching and failure cooldown
- **LinkTitleService** - HTML title extraction from URLs
- **BrowserManager** - Browser resolution (`resolveTarget`), URL opening, installed browsers, browser-profile detection (Chrome, Chrome Canary, Helium, Firefox)

**UI Components**:
- **MainViewController** - Collection view-based hierarchical list with animations (reduced from 1352 to 596 lines through Phase 3 refactoring)
- **NodeListViewController** - Manages collection view, drag-drop, context menus (extracted from MainViewController)
- **SearchCoordinator** - Handles search/filtering logic (extracted from MainViewController)
- **SettingsContentViewController** - Settings page: workspace list, default browser, profiles (`ProfileSettingsView`), permissions, import
- **NodeCollectionViewItem** - Reusable cell with icon, title, hover states, delete button
- **SearchBarView** - Search field that filters nodes
- **IconTitleButton** - Custom button for paste action
- **ListFlowLayout** - Custom NSCollectionViewLayout for vertical list

### UI Component Architecture (Post-Refactoring)

**Base Classes** (located in `Components/Base/`):
- **BaseControl** - Base class for all interactive controls with hover and pressed state management
  - Eliminates ~40 lines of tracking area and mouse event code per subclass
  - Provides `handleHoverStateChanged()` and `handlePressedStateChanged()` override points
  - Used by: `IconTitleButton`, `CustomToggle`, `CustomTextButton`
- **BaseView** - Base class for custom views with hover state management (no pressed state)
  - Simpler than BaseControl, designed for non-interactive views like rows
  - Used by: `NodeRowView`, `WorkspaceRowView`
- **InlineEditableTextField** - Reusable component for inline text editing
  - Encapsulates commit/cancel logic, focus management, and callbacks
  - Eliminates ~80 lines of duplicate editing code per component
  - Used by: `NodeRowView`, `WorkspaceRowView`

**Design System** (located in `Utilities/Theme/`):
- **ThemeConstants** - Centralized design system constants
  - Colors: Brand colors and semantic values (darkGray, white, settingsBackground)
  - Opacity: Standard opacity levels (full, high, medium, low, subtle, extraSubtle, minimal)
  - Fonts: Typography styles (bodyRegular, bodySemibold, bodyMedium, bodyBold)
  - Spacing: Layout spacing values (tiny=4, small=6, medium=8, regular=10, large=14, extraLarge=16, huge=20)
  - CornerRadius: Rounding values (small=6, medium=8, large=12)
  - Sizing: Standard sizes (iconSmall=14, iconMedium=18, iconLarge=22, buttonHeight=32, rowHeight=44)
  - Animation: Timing values (durationFast=0.15s, durationNormal=0.2s, durationSlow=0.3s)
  - Replaces 50+ hardcoded "magic numbers" throughout the codebase

**Component Patterns**:
All interactive controls extend BaseControl or BaseView and use ThemeConstants for consistency:

```swift
// Example: Custom button extending BaseControl
final class MyButton: BaseControl {
    override func handleHoverStateChanged() {
        layer?.backgroundColor = isHovered
            ? ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.minimal).cgColor
            : NSColor.clear.cgColor
    }

    override func handlePressedStateChanged() {
        layer?.backgroundColor = isPressed
            ? ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.subtle).cgColor
            : NSColor.clear.cgColor
    }
}
```

### State Mutation Pattern

All mutations follow this pattern:
```swift
// 1. Validate preconditions
// 2. Call updateWorkspace or updateNode with closure
// 3. Closure modifies inout parameter
// 4. AppModel automatically persists and notifies observers
```

Examples:
- `addFolder(name:parentId:)` - Inserts new folder node
- `moveNode(id:toParentId:index:)` - Moves node in hierarchy, handles reordering logic
- `renameNode(id:newName:)` - Updates node display name
- `deleteNode(id:)` - Recursively removes node from tree

### Node Hierarchy Operations

The AppModel uses recursive tree traversal for node operations:
- `insertNode(_:parentId:index:nodes:)` - Recursive insertion into parent
- `updateNode(id:nodes:_:)` - Recursive update with mutation closure
- `removeNode(id:nodes:)` - Recursive removal returning deleted node
- `findNodeLocation(id:nodes:parentId:)` - Returns NodeLocation with parent ID and index

When moving nodes, the system:
1. Validates the move isn't to a descendant (prevents cycles)
2. Removes node from old location
3. Adjusts target index if needed (accounts for removal in same parent)
4. Inserts at new location

### UI Update Strategy

**Collection View Animations**:
- Calculates diff between old and new visible rows
- Uses `performBatchUpdates` for insertions/deletions
- Animates inserted rows with fade + slide from offset
- Creates bitmap snapshots for deletion animation
- Skips animations when query is active or window not visible

**Inline Rename**:
- Triggered via context menu or for new folders
- `scheduleInlineRename(for:)` sets `pendingInlineRenameId`
- After data reload, `handlePendingInlineRename()` activates edit mode
- Edit mode managed by NodeCollectionViewItem with commit/cancel callbacks

### Workspace Colors

WorkspaceColorId enum defines 8 color themes (Blush, Apricot, Butter, Leaf, Mint, Sky, Periwinkle, Lavender). Each color affects:
- Window background color (color at 0.92 alpha)
- View layer background color

## Important Patterns

### AppKit-Specific Patterns
- Uses `@MainActor` extensively for UI thread safety
- Custom NSCollectionViewLayout for list metrics
- Context menus via NSMenuDelegate with dynamic population
- Drag-and-drop via NSPasteboardWriting/NSPasteboardReading

### State Management
- Never expose mutable state directly - only through methods
- Use `inout` parameters in private update methods for efficient mutations
- All persistence is automatic - callers never call save()
- Use `notify: false` parameter to suppress onChange callback if needed

### Search/Filter
- NodeFiltering recursively filters tree, expanding folders with matches
- MainViewController forces folder expansion when query is active
- Filtering preserves hierarchy (keeps parent folders if children match)
- The drag and drop is disabled when searching/filtering

### Testing
- Tests use temporary directory for DataStore to avoid polluting real data
- Model operations tested via AppModel integration (not isolated units)
- Tests verify both state mutation and JSON round-trip encoding
- All tests use swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`); XCTest is not available with Command Line Tools only
- swift-testing runs tests in parallel: don't share mutable global state (UserDefaults, real data dir) between tests
- Fixtures go in the suite's `init()` (a fresh instance per test), not `setUp`
- ThemeConstants has comprehensive unit tests validating all design values
- Opt-in acceptance tests run against real files only when an env var points at a **copy**: `SIDEBARC_V1_FIXTURE` (v1 `data.json` → migration, zero lost links) and `SIDEBARC_ARC_FIXTURE` (`StorableSidebar.json` → favorites per profile). They print counts only; never commit those files
- Menu items with closures use `ClosureMenuItem`. Never name an `@objc` action method `perform(_:)`: `#selector` resolves to NSObject's `performSelector:`, which throws inside AppKit's dispatch and is swallowed, so the item silently does nothing (`ClosureMenuItemTests` guards this)

## Refactoring History

The codebase underwent a comprehensive refactoring (2026-02-10) to eliminate code duplication and improve maintainability:

**Phase 1 - Foundation (✅ Complete)**:
- Created base classes: `BaseControl`, `BaseView`, `InlineEditableTextField`
- Created `ThemeConstants` for centralized design system
- Added comprehensive unit tests for all base classes

**Phase 2 - Component Migration (✅ Complete)**:
- Migrated 5 components to extend base classes
- Replaced hardcoded values with ThemeConstants references
- Eliminated ~520 lines of duplicate code

**Phase 3 - ViewController Decomposition (✅ Complete)**:
- Extracted `NodeListViewController` from `MainViewController` (~800 lines)
- Extracted `SearchCoordinator` from `MainViewController` (~65 lines)
- Reduced `MainViewController` from 1352 to 596 lines (56% reduction)
- Created `WorkspaceManagementView` for settings (~380 lines); never wired in, removed on 2026-11-14 (Settings uses `SettingsContentViewController`)

**Phase 4 - Remaining Components (✅ Complete)**:
- Migrated `SearchBarView`, `WorkspaceSwitcherView`, `SidebarPositionSelector` to use ThemeConstants
- Migrated nested button classes in `WorkspaceSwitcherView` to extend BaseControl
- Eliminated ~205 additional lines of duplicate code

**Phase 5 - Polish & Documentation (✅ Complete)**:
- Added comprehensive inline documentation to all base classes
- Enhanced ThemeConstants with detailed usage examples
- Updated CLAUDE.md with new architecture details
- Created component usage examples

**Total Impact**:
- **Code reduction**: ~1,145 lines eliminated (14.1% of original codebase)
- **Zero functional regressions**: All features work as before
- **Improved consistency**: All components use centralized design constants
- **Better maintainability**: Base classes eliminate duplicate patterns
- **Enhanced testability**: Clear separation of concerns with coordinator pattern
