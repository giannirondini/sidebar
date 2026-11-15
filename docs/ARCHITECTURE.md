# SidebArc Architecture

**Last Updated:** 2026-02-10
**Status:** Post-Refactoring (All 5 Phases Complete)

## Overview

SidebArc is a macOS bookmark management application built with Swift and AppKit. It uses a workspace-based organization system with hierarchical folders and links, featuring drag-and-drop, inline editing, and automatic favicon/title fetching.

## Architecture Patterns

### 1. Unidirectional Data Flow

```
User Action → MainViewController → AppModel → AppState → DataStore → Disk
                     ↑                                        ↓
                     └──────── onChange callback ─────────────┘
```

- **AppModel**: Single source of truth, owns AppState
- **AppState**: Immutable data model (Codable)
- **DataStore**: Persistence layer (JSON + favicon storage)
- **MainViewController**: UI coordinator, observes AppModel via onChange callback

### 2. Component Architecture (Post-Refactoring)

**Base Classes** eliminate code duplication:
- `BaseControl`: Interactive controls with hover + pressed states (~40 lines saved per subclass)
- `BaseView`: Non-interactive views with hover state only (~40 lines saved per subclass)
- `InlineEditableTextField`: Reusable inline editing component (~80 lines saved per usage)

**Design System** ensures consistency:
- `ThemeConstants`: Centralized colors, fonts, spacing, opacity, animations
- Replaces 50+ hardcoded "magic numbers" throughout codebase

## Project Structure

```
Sources/SidebArcCore/
├── Components/
│   ├── Base/
│   │   ├── BaseControl.swift          # Base for interactive controls
│   │   ├── BaseView.swift             # Base for custom views
│   │   └── InlineEditableTextField.swift
│   ├── Buttons/
│   │   ├── IconTitleButton.swift      # Extends BaseControl
│   │   ├── CustomTextButton.swift     # Extends BaseControl
│   │   └── CustomToggle.swift         # Extends BaseControl
│   ├── Lists/
│   │   ├── NodeRowView.swift          # Extends BaseView
│   │   ├── WorkspaceRowView.swift     # Extends BaseView
│   │   └── ... (collection view items, layout)
│   ├── Inputs/
│   │   └── SearchBarView.swift
│   ├── Menus/
│   │   ├── BrowserMenus.swift         # Open in ▸ / Always open in ▸ / Profile ▸
│   │   └── SpaceMenu.swift            # A space's context menu (acts on that space)
│   └── Spaces/
│       ├── SpaceBarView.swift         # Bottom bar: gear, space icons, +
│       ├── SpaceHeaderView.swift      # Current space's icon and name (rename here)
│       └── SpaceIconView.swift        # A space's emoji/symbol or colour dot
├── ViewControllers/
│   ├── MainViewController.swift       # Main coordinator: layout, model binding, menus
│   ├── MainViewController+SpaceTransition.swift  # Swipe/click/keyboard space switch
│   ├── NodeListViewController.swift   # Manages collection view (~1300 lines)
│   ├── SearchCoordinator.swift        # Handles search/filtering (~65 lines)
│   └── ... (preferences, settings)
├── Models/
│   ├── Models.swift                   # AppState, Workspace, Node (Link/Folder)
│   ├── WorkspaceColor.swift
│   └── SidebarPosition.swift
├── State/
│   ├── AppModel.swift                 # Central state manager
│   └── DataStore.swift                # Persistence layer
├── Services/
│   ├── FaviconService.swift           # Async favicon fetching
│   ├── LinkTitleService.swift         # HTML title extraction
│   ├── BrowserManager.swift           # Browser selection & URL opening
│   ├── TabLocator.swift               # Lists/focuses browser tabs over Apple Events
│   ├── TabFocus.swift                 # Pure "focus an open tab or open new?" decisions
│   ├── TabFocusService.swift          # Runs TabFocus for clicks (off the main actor)
│   └── ... (window attachment, Arc import)
└── Utilities/
    ├── NodeFiltering.swift            # Recursive filtering
    ├── TabURLMatcher.swift            # Which open tab shows a link
    ├── URLNormalization.swift         # Favorites dedupe key
    ├── SpaceSwipe.swift               # Pure swipe decisions, spring, release velocity
    └── Theme/
        └── ThemeConstants.swift       # Design system constants
```

## Core Data Model

```swift
AppState                      // Root container (data.json, schemaVersion 2)
├── schemaVersion: Int
├── profiles: [Profile]       // At least one
├── workspaces: [Workspace]
└── selectedWorkspaceId: UUID?
                              // Settings shown: runtime only (AppModel.isSettingsShown)

Profile                       // Spaces sharing a browser setup and Favorites
├── id: UUID
├── name: String              // "Default", "Work", …
├── browserBundleId: String?  // nil → global default browser
├── browserProfiles: [String: String]  // browser bundle id → browser profile dir
└── favorites: [Link]         // Tile grid, max 12, shared by the profile's spaces

Workspace                     // A space
├── id: UUID
├── name: String
├── colorId: WorkspaceColorId
├── items: [Node]             // Root-level items (the pinned list)
├── profileId: UUID
└── icon: CustomIcon?         // Emoji or SF Symbol; nil = colour dot

Node                          // Recursive tree structure
├── .folder(Folder)
│   ├── id: UUID
│   ├── name: String
│   ├── isExpanded: Bool
│   └── children: [Node]      // Nested items
├── .link(Link)
│   ├── id: UUID
│   ├── title: String
│   ├── url: String
│   ├── faviconPath: String?
│   ├── customIcon: CustomIcon?
│   ├── scheduledOpenAt: Date?
│   └── browserBundleId: String?  // per-link browser override
└── .note(Note)               // Body in Notes/<id>.md
```

### Schema migration

`DataStore.load()` probes `schemaVersion`. v1 files (Arcmark 0.1.x layout: `pinnedLinks` and `browserProfiles` on each workspace) are decoded by `SchemaV1` and converted by the pure `SchemaMigration.v1ToV2`:

1. Spaces with an identical `browserProfiles` dictionary share one profile ("Default", "Profile 2", …), `browserBundleId = nil`, so every space opens links where it did before.
2. A profile's favorites are its spaces' pinned links in space order, deduplicated by normalised URL (`URLNormalization`) and capped at 12.
3. Duplicates and overflow go into a "Favorites (migrated)" folder at the top of the space they came from. No link is dropped.

The original bytes are copied to `Backups/pre-v2-migration-<timestamp>.json` (outside the rotation) before the migrated state is saved.

## Profiles and browser routing

A link opens in: **link override → profile's browser → global default**, skipping any browser that isn't installed (`BrowserManager.resolveTarget`). The browser profile directory comes from the profile's `browserProfiles` for that browser, unless a link override points at a different browser. Favorites belong to the profile, so every space in it shows the same grid; unpinning moves a favorite into the current space. Deleting a profile moves its spaces and favorites to the first remaining profile (leftovers go to a folder). Notes open in the space's profile browser too; window attachment uses the global default browser.

## Switching to open tabs

Clicking a favorite focuses a browser tab that already shows it instead of opening a duplicate; a pinned-list link does so on ⌥-click (⌥ inverts both defaults). Open All Links, scheduled links, Open in ▸ and notes always open a new tab.

```
click → TabFocusService.open (main actor)
          resolveTarget → TabFocus.decide ─ openNew ──────────────► BrowserManager.open
                              │ lookForTab(browser)
          browser running? ── no ─────────────────────────────────► BrowserManager.open
          detached task: TabFocus.locateAndFocus
            AutomationPermission.check(ask: false) ─ not granted ─► open (+ Settings hint)
            TabLocator.tabURLs        (1 Apple Event, 300 ms timeout)
            TabURLMatcher.bestMatch   ─ none ─────────────────────► open
            TabLocator.activate       (re-check URL, select tab, raise window)
          main actor: NSRunningApplication.activate (yieldActivation on macOS 14+)
```

- **Locators** (`TabLocators.locator(for:)`, bundle ids compared case-insensitively): `ChromiumTabLocator` (Chrome, Brave) and `SafariTabLocator`. They send raw Apple Events built from four-char codes in each browser's dictionary (`NSAppleEventDescriptor.sendEvent(options:timeout:)`), addressed **by pid**, so an event never launches a closed browser. Not `NSAppleScript` (main thread only) or `osascript` (a child process: macOS attributes its privacy checks to SidebArc). Chromium incognito windows are listed empty. Activation re-reads the chosen tab's URL and gives up if it changed since the listing. Firefox has no scripting dictionary; Dia and Arc ship their own dictionaries and are not verified; Edge, Vivaldi, Canary and Helium aren't installed here: all of them open normally.
- **Matching** (`TabURLMatcher`): same scheme, host (case-insensitive) and port; prefix mode needs the tab's path at or below the link's path on a segment boundary and every query item of the link in the tab; exact mode (`Link.exactTabMatch`, "Match Exact URL") needs the same path and query items. Fragment ignored; `www.` and http/https are **not** equal. Separate from `URLNormalization` (favorites dedupe), which is unchanged.
- **Browser profiles**: AppleScript can't tell which Chrome profile owns a window. `TabFocus.isAmbiguous` is true when SidebArc's profiles open the same browser with different browser profiles; then `Profile.focusesOpenTabs` defaults to off (`nil` = automatic) and Settings › Profiles warns when it's switched on.
- **Permission**: the click path checks Automation with `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` and never prompts; denied, never asked or a reset grant open normally. Settings › Permissions shows the status per browser and asks on "Allow Browser Access…". Needs `NSAppleEventsUsageDescription` (Bundler.toml + `patch_info_plist`) and, under the hardened runtime, the Apple Events entitlement ([BUILD_AND_CODESIGN.md](BUILD_AND_CODESIGN.md)).
- **Tests**: `TabURLMatcherTests` (table), `TabFocusTests` (decisions, fake locator, Apple Event building, opt-in `SIDEBARC_TAB_PROBE`); real browsers: [TAB_FOCUS_CHECKLIST.md](TAB_FOCUS_CHECKLIST.md).

## Key Design Decisions

### State Management
- **All mutations through AppModel methods** - no direct state access
- **Automatic persistence** - DataStore saves after every mutation
- **Observer pattern** - onChange callback for UI updates
- **Recursive tree operations** - insertNode, updateNode, removeNode, findNodeLocation

### UI Updates
- **Collection view animations** - calculated diffs for smooth insertions/deletions
- **Inline rename pattern** - scheduled via `pendingInlineRenameId`, executed after data reload
- **Hover state management** - centralized in base classes, no duplicate tracking area code
- **Design consistency** - all components use ThemeConstants for colors/fonts/spacing

### ViewController Decomposition (Phase 3)
- **MainViewController** - Coordinator between search, Favorites, the space page, the space bar and Settings (596 lines after Phase 3; ~1000 since profiles, tab focus and the Phase 3a space UI). The space switch lives in `MainViewController+SpaceTransition` (see [SPACES.md](SPACES.md))
- **NodeListViewController** (~1300 lines) - Collection view, drag-drop, context menus
- **SearchCoordinator** (~65 lines) - Search/filtering logic
- **SettingsContentViewController** - Settings page (workspace list, default browser, profiles, permissions, import). The extracted `WorkspaceManagementView` was never wired in and was removed on 2026-11-14

## Component Patterns

### Creating Interactive Controls

```swift
final class MyButton: BaseControl {
    override func handleHoverStateChanged() {
        layer?.backgroundColor = isHovered
            ? ThemeConstants.Colors.darkGray
                .withAlphaComponent(ThemeConstants.Opacity.minimal).cgColor
            : NSColor.clear.cgColor
    }

    override func handlePressedStateChanged() {
        // Update appearance based on isPressed
    }
}
```

### Creating Custom Views

```swift
final class MyRowView: BaseView {
    override func handleHoverStateChanged() {
        // Update appearance based on isHovered
    }
}
```

### Using ThemeConstants

```swift
// Colors
layer?.backgroundColor = ThemeConstants.Colors.darkGray.cgColor

// With opacity
let hoverColor = ThemeConstants.Colors.darkGray
    .withAlphaComponent(ThemeConstants.Opacity.minimal)

// Fonts
label.font = ThemeConstants.Fonts.bodyRegular

// Spacing
stackView.spacing = ThemeConstants.Spacing.regular

// Animation
CATransaction.setAnimationDuration(ThemeConstants.Animation.durationFast)
```

## Testing Strategy

- **Model tests** - JSON round-trip, move operations, filtering
- **ThemeConstants tests** - Validates all design values (16 tests)
- **Base class tests** - Currently skipped (Swift 6 concurrency + XCTest issues)
- **Total: 20 tests** - All passing, zero failures

## Refactoring Impact (2026-02-10)

**Code Reduction:**
- Eliminated 1,145 lines of duplicate code (14.1% reduction)
- MainViewController: 1352 → 596 lines (56% reduction)

**Improvements:**
- Zero functional regressions
- Centralized design system (ThemeConstants)
- Eliminated 6+ instances of duplicate hover state logic
- Eliminated 3+ instances of duplicate inline editing logic
- Consistent component patterns across all UI

**Documentation:**
- 900+ lines of comprehensive inline documentation
- Component usage guide (400+ lines)
- Architecture and refactoring history documented

## Dependencies

- **Swift 6** with strict concurrency
- **AppKit** for macOS UI
- **Swift Bundler** for app bundle creation
- No external dependencies for core functionality

## Build System

```bash
# Build app bundle
./scripts/build.sh

# Build and run
./scripts/run.sh

# Run tests
swift test
```

See [BUILD_AND_CODESIGN.md](BUILD_AND_CODESIGN.md) for details on build process and code signing.

## Future Considerations

**Optional Enhancements:**
- Folder structure reorganization (move files into categorized subdirectories)
- Visual regression testing suite
- Async XCTest infrastructure for base class tests
- Performance benchmarking and profiling
- Memory leak testing with Instruments

**Architecture is Stable:**
- All 5 refactoring phases complete
- Production-ready with comprehensive documentation
- Ready for new feature development

## Resources

- [CLAUDE.md](../CLAUDE.md) - Rules most tasks need (agents and contributors)
- [INTERNALS.md](INTERNALS.md) - Data flow, mutation pattern, node tree operations, list updates
- [PROFILES_AND_BROWSERS.md](PROFILES_AND_BROWSERS.md) - Profiles, Favorites, browser routing
- [TAB_FOCUS.md](TAB_FOCUS.md) - Switching to open tabs
- [SPACES.md](SPACES.md) - Space layout, space bar, transitions
- [REFACTORING_PLAN.md](REFACTORING_PLAN.md) - Complete refactoring history
- [COMPONENT_USAGE_GUIDE.md](COMPONENT_USAGE_GUIDE.md) - Component usage patterns
- [BUILD_AND_CODESIGN.md](BUILD_AND_CODESIGN.md) - Build system details
