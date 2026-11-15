# Internals

_Data flow and data model moved from CLAUDE.md on 2026-11-15 and merged with the matching parts of [ARCHITECTURE.md](ARCHITECTURE.md), which is now the overview (project structure, design decisions). The rules most tasks need are in [CLAUDE.md](../CLAUDE.md)._

## Data Flow Architecture

The application follows a unidirectional data flow pattern (diagram in [ARCHITECTURE.md › Data flow](ARCHITECTURE.md#data-flow)):

1. **AppModel** - Central state manager that owns `AppState` and coordinates all mutations
   - Single source of truth for application state
   - Exposes an `onChange` callback for UI updates
   - All state mutations go through AppModel methods (no direct state manipulation)
   - Automatically persists to disk via `DataStore` after every mutation

2. **DataStore** - Handles persistence layer
   - Saves/loads JSON to `~/Library/Application Support/io.github.giannirondini.sidebarc/data.json` (folder named after the bundle id, `AppIdentity.dataDirectoryName`)
   - Keeps favicons in `Icons/`, note bodies in `Notes/<id>.md`, rotating backups in `Backups/` (10 files, once per session) and the agent endpoint in `agent-endpoint.json`
   - Provides default state initialization

3. **MainViewController** - Primary UI controller
   - Observes AppModel via `onChange` callback and lays out search, Favorites, the space page, the space bar and Settings
   - Delegates the list (collection view, drag-and-drop, inline editing, context menus) to `NodeListViewController`
   - Never directly mutates state - always calls AppModel methods

## Core Data Model

The data model is defined in `Models.swift`:

```swift
AppState                      // Root of data.json
├── schemaVersion: Int        // 2
├── profiles: [Profile]       // At least one
├── workspaces: [Workspace]
└── selectedWorkspaceId: UUID?
                              // Settings shown: runtime only (AppModel.isSettingsShown)

Profile                       // Spaces sharing a browser setup and Favorites
├── id: UUID
├── name: String              // "Default", "Work", …
├── browserBundleId: String?  // nil → global default browser
├── browserProfiles: [String: String]  // browser bundle id → browser profile dir
├── favorites: [Link]         // Tile grid, max Profile.maxFavorites (12), shared by the profile's spaces
└── focusesOpenTabs: Bool?    // nil = automatic (see TAB_FOCUS.md)

Workspace                     // A space
├── id: UUID
├── name: String
├── colorId: WorkspaceColorId
├── items: [Node]             // Root-level items (the pinned list)
├── profileId: UUID           // Every space belongs to exactly one profile
└── icon: CustomIcon?         // nil = colour dot

Node                          // Recursive tree (tagged union, custom Codable)
├── .folder(Folder)
│   ├── id: UUID
│   ├── name: String
│   ├── children: [Node]
│   └── isExpanded: Bool
├── .link(Link)
│   ├── id: UUID
│   ├── title: String
│   ├── url: String
│   ├── faviconPath: String?
│   ├── customIcon: CustomIcon?
│   ├── scheduledOpenAt: Date?
│   ├── browserBundleId: String?  // Per-link browser override
│   └── exactTabMatch: Bool?      // "Match Exact URL" for tab focus
└── .note(Note)
    ├── id: UUID
    ├── title: String
    └── customIcon: CustomIcon?   // Body in Notes/<id>.md

CustomIcon                    // .emoji(String) | .sfSymbol(String) | .cachedFavicon(String)
```

- The UI says "Space"; code, data keys and the agent API keep `workspace`.
- All models are Codable and use UUID-based identification.
- Files written before Phase 3a still carry an `isSettingsSelected` key; it is ignored.

### Schema versions

`DataStore.load()` reads `schemaVersion` first (`SchemaVersionProbe`). A v1 file (Arcmark 0.1.x layout: `pinnedLinks` and `browserProfiles` on each workspace) is decoded by the read-only `SchemaV1` mirror and upgraded by the pure `SchemaMigration.v1ToV2` (`Persistence/SchemaMigration.swift`):

1. Spaces with an identical `browserProfiles` dictionary share one profile ("Default", "Profile 2", …), `browserBundleId = nil`, so every space opens links where it did before.
2. A profile's favorites are its spaces' pinned links in space order, deduplicated by normalised URL (`URLNormalization`) and capped at 12.
3. Duplicates and overflow go into a "Favorites (migrated)" folder at the top of the space they came from. No link is dropped.

The original bytes are first copied to `Backups/pre-v2-migration-<ts>.json`, which the 10-file backup rotation never prunes, then the result is saved. Every load runs `AppState.repaired()` (at least one profile; dangling `profileId`s fall back to the first). The v2 model carries no legacy fields; add a new `SchemaVn` mirror + migration for the next change instead.

## Export and import (Phase 3b.3)

Settings › Import & Export › **Export Data…** / **Import Data…** move everything to another Mac (`Persistence/DataTransfer.swift`, `AppModel.exportData`, `AppModel.applyDataImport`).

- **Export** creates `SidebArc Export <yyyy-MM-dd HH.mm>/` in a chosen folder (never overwriting: " 2", " 3", … is appended) with `export.json` (manifest: `format` = `io.github.giannirondini.sidebarc.export`, `formatVersion` 1, `schemaVersion`, `exportedAt`, `appVersion`), an exact copy of `data.json`, `Notes/` and `Icons/`. Not exported: app preferences (UserDefaults), `agent-endpoint.json` (it holds a token), `Backups/`.
- **Import** accepts only such a folder. `DataTransfer.readPackage` validates without changing anything: a missing or foreign manifest, a newer `formatVersion` or schema, or a missing or unreadable `data.json` is refused. A v1 `data.json` is migrated (`DataStore.decodeState`, shared with `load()`). After a confirmation with counts, `applyDataImport` backs up the current data **as an export** to `Backups/pre-import-<ts>/` (never pruned; nothing changes if the backup fails; Import Data… on that folder undoes the import), copies the export's `Notes/` and `Icons/` in (same-name files are replaced, others kept), then replaces the state in one mutation and selects the export's selected space.
- **Icon paths** are absolute. `DataTransfer.remapIconPaths` points every `Link.faviconPath` and `CustomIcon.cachedFavicon` inside an `Icons/` folder at this Mac's `Icons/` (space trees, space icons, favorites); a `faviconPath` elsewhere is dropped and re-fetched. Without it, custom favicon icons would show a globe forever on a Mac with another home folder.
- **Per-Mac settings in the data:** `Profile.browserProfiles` (browser profile folder names) and browser choices come over as they are; check Settings › Profiles after importing on another Mac.
- Tests: `DataTransferTests` (two temp data folders as two Macs).

## Key Components

The file-by-file map is in [ARCHITECTURE.md › Project structure](ARCHITECTURE.md#project-structure). Details not listed there:

- **FaviconService**, **LinkTitleService** - `shared` singletons; favicons are cached on disk with a cooldown after failures
- **SettingsContentViewController** - Settings page: space list (drag to reorder), default browser, profiles (`ProfileSettingsView`), permissions, import
- **NodeCollectionViewItem** - Reusable cell with icon, title, hover states, delete button
- **IconTitleButton** - Icon + title button; `.listRow` style is the "+ Add from Clipboard" row

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
