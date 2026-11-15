# Internals

_Moved from CLAUDE.md on 2026-11-15. The rules most tasks need are summarised in [CLAUDE.md](../CLAUDE.md)._ [ARCHITECTURE.md](ARCHITECTURE.md) covers some of the same ground (data model, data flow) in its own words; merging the two is a follow-up.

## Data Flow Architecture

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

## Core Data Model

The data model is defined in `Models.swift`:

- **AppState** - Root container: `schemaVersion` (currently 2), `profiles`, `workspaces`, selected workspace ID. Whether Settings is shown is runtime state (`AppModel.isSettingsShown`), not saved; older files' `isSettingsSelected` key is ignored
- **Profile** - Groups spaces that share a browser setup and the Favorites grid: `name`, `browserBundleId` (nil = global default browser), `browserProfiles` (browser bundle id → browser profile dir), `favorites: [Link]` (max `Profile.maxFavorites` = 12), `focusesOpenTabs: Bool?` (nil = automatic)
- **Workspace** - Named, colored container with hierarchical `items`, a `profileId` (every space belongs to exactly one profile) and an optional `icon: CustomIcon?` (emoji or SF Symbol; nil shows the colour dot). The UI says "Space"; code, data keys and the agent API keep `workspace`
- **Node** - Enum of `Folder`, `Link` or `Note`
  - `Folder` - Contains nested children and isExpanded state
  - `Link` - URL, title, optional favicon path, custom icon, schedule, `browserBundleId` (per-link browser override) and `exactTabMatch: Bool?`
  - `Note` - Title and custom icon; the body is a `.md` file in `Notes/`

All models are Codable and use UUID-based identification. The Node enum uses custom encoding to serialize the tagged union structure.

**Schema versions.** `DataStore.load()` reads `schemaVersion` first (`SchemaVersionProbe`). A v1 file is decoded by the read-only `SchemaV1` mirror and upgraded by the pure `SchemaMigration.v1ToV2` (`Persistence/SchemaMigration.swift`); the bytes are first copied to `Backups/pre-v2-migration-<ts>.json`, which the 10-file backup rotation never prunes, then the result is saved. Every load runs `AppState.repaired()` (at least one profile; dangling `profileId`s fall back to the first). The v2 model carries no legacy fields; add a new `SchemaVn` mirror + migration for the next change instead.

## Key Components

**Services** (all MainActor singletons):
- **FaviconService** - Async favicon fetching with disk caching and failure cooldown
- **LinkTitleService** - HTML title extraction from URLs
- **BrowserManager** - Browser resolution (`resolveTarget`), URL opening, installed browsers, browser-profile detection (Chrome, Chrome Canary, Helium)
- **TabFocusService** - Click → focus an open tab or open new (`TabFocus`, `TabLocator`, `TabURLMatcher`)

**UI Components**:
- **MainViewController** - Layout, model binding, menus (~1000 lines; the space transition is in `MainViewController+SpaceTransition`)
- **NodeListViewController** - Manages collection view, drag-drop, context menus (extracted from MainViewController)
- **SearchCoordinator** - Handles search/filtering logic (extracted from MainViewController)
- **SettingsContentViewController** - Settings page: space list (drag to reorder), default browser, profiles (`ProfileSettingsView`), permissions, import
- **NodeCollectionViewItem** - Reusable cell with icon, title, hover states, delete button
- **SearchBarView** - Search field that filters nodes
- **IconTitleButton** - Icon + title button; `.listRow` style is the "+ Add from Clipboard" row
- **SpaceBarView**, **SpaceHeaderView**, **SpaceIconView**, **SpaceMenu** - Space bar, header, icon/colour dot and space menu (`Components/Spaces`, `Components/Menus`)
- **ListFlowLayout** - Custom NSCollectionViewLayout for vertical list

## State Mutation Pattern

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

## Node Hierarchy Operations

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

## UI Update Strategy

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

## Workspace Colors

WorkspaceColorId enum defines 8 color themes, shown as Blush, Apricot, Butter, Leaf, Mint, Sky, Periwinkle, Lavender (the cases are `ember`, `ruby`, `coral`, `tangerine`, `moss`, `ocean`, `indigo`, `graphite`; `settingsBackground` is Settings' colour, not offered for spaces). Each color affects:
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
