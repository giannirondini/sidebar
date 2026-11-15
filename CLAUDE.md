# CLAUDE.md

Guidance for Claude Code in this repository. The rules most tasks need are here; details are in the files listed under **Where to look**.

## Project

SidebArc is a macOS bookmark sidebar built with Swift and AppKit (a fork of Arcmark). Swift package `SidebArc`: `SidebArcCore` (library), `SidebArcApp` (entry point), `SidebArcTests`. Links, folders and notes organised in spaces, with drag-and-drop, inline editing and automatic favicon/title fetching.

**Terms.** The UI says **Space**; code, data keys and the agent API keep `workspace`. **Favorites** = the tile grid at the top (`Profile.favorites`, shared by a profile's spaces). **Pinned list** = a space's tree (`Workspace.items`). **Profile** = spaces that share a browser setup and the Favorites.

## Commands

**Never run `./scripts/*.sh`** (build, run, release, DMG): the user runs them. `swift build` is fine.

```bash
# Tests (swift-testing; the plugin path works around an intermittent
# "TestingMacros plugin not found" build failure with Command Line Tools only)
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
# Single test: --filter is a regex over "Suite/testName"
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" --filter 'ModelTests/testJSONRoundTrip\('
```

- **App identity:** `Bundler.toml` is the single source (`[apps.SidebArc]`; `identifier` = `io.github.giannirondini.sidebarc`). Scripts read it via `scripts/lib/app-config.sh`; Swift mirrors it in `AppIdentity` (`Constants.swift`); `AppIdentityTests` fails if they drift. The version is the `VERSION` file.
- **Signing:** `dev_sign` signs with the self-signed identity in the git-ignored `.signing-config`, else ad-hoc pinned to the bundle id. `NSAppleEventsUsageDescription` must reach Info.plist (`patch_info_plist`), or Apple Events are denied with no prompt.
- Builds use swift-bundler through Mint (`brew install mint`, pinned in `Mintfile`). No in-app updater: "Check for Updates…" opens `AppIdentity.releasesURL`.

## Architecture rules

- **`AppModel`** owns `AppState` and is the single source of truth. Every mutation goes through an `AppModel` method, which persists through `DataStore` (`~/Library/Application Support/io.github.giannirondini.sidebarc/data.json`) and calls `onChange`. UI code never mutates state; callers never call `save()`; `notify: false` suppresses `onChange`.
- **Model** (`Models.swift`): `AppState` (`schemaVersion` 2, `profiles`, `workspaces`, selected workspace) → `Workspace` (`items`, `profileId`, optional `icon` and `customColor`) → `Node` = `Folder` | `Link` | `Note` (body in `Notes/*.md`). Whether Settings is shown is runtime state (`AppModel.isSettingsShown`), never saved.
- **Schema changes:** new fields on synthesized-Codable models (`Profile`, `Link`, `Workspace`) must be `Optional` (synthesized decoding ignores defaults, so a non-optional field fails every existing file); anything else needs a `SchemaVn` mirror and a migration (`Persistence/SchemaMigration.swift`). **Bump `AppState.currentSchemaVersion` for any change an older version would lose on save, including a new Optional field**: older versions refuse a newer schema at startup (`DataStore.LoadIssue.newerSchema`) but strip unknown fields from a same-version file without notice. Confirm a backup exists first.
- **Never drop links:** migration, profile deletion and Arc import use `Profile.appendFavorites` and put the leftovers in a folder. Favorites cap: `Profile.maxFavorites` (12). `URLNormalization` (favorites dedupe) must not change.
- **Browsers:** where a link opens is `BrowserManager.resolveTarget(link:profile:)`. **Never spawn a browser executable as a child process** (macOS attributes its privacy checks to SidebArc, and a closed Chrome exits silently); launch through LaunchServices. Window attachment follows whichever profile browser (or the default) is in front (`WindowAttachmentService`; diagnose with the `attach` log category).
- **Tab focus:** raw Apple Events by pid (`NSAppleEventDescriptor.sendEvent`, 300 ms) from a detached task. Never `NSAppleScript` or `osascript`, never send to a browser that isn't running (it would launch), and clicks never prompt for Automation. Add a browser only after verifying it on a Mac.
- **Spaces:** user navigation goes through `requestSpaceSwitch(to:)`, never `model.selectWorkspace`. Model reloads are held while a transition runs. **Never move or animate an AppKit view through its layer `transform`** (AppKit can reset it).
- **Space colours:** read them through `Workspace.color` (opaque) / `Workspace.backgroundColor`, never `colorId.color` (a custom colour wins). Paint the background **once**, on `MainViewController`'s layer: `window.backgroundColor` stays clear and the window root is `SidebarBackdropViewController` (blur), or the opacity stacks.
- **Screen coordinates:** Accessibility frames use the primary display's top-left origin; flip with the primary display's height, never `NSScreen.main`.

## UI rules

- `ThemeConstants` (`Utilities/Theme/`) for colours, opacity, fonts, spacing, sizes and animation: no magic numbers.
- Interactive controls extend `BaseControl` (hover + pressed); hover-only views extend `BaseView`; inline renames use `InlineEditableTextField` (all in `Components/Base/`).
- Menu items with closures use `ClosureMenuItem`. Never name an `@objc` action method `perform(_:)`: `#selector` resolves to NSObject's `performSelector:`, which throws inside AppKit's dispatch and is swallowed, so the item silently does nothing (`ClosureMenuItemTests` guards this). A menu that disables items needs `autoenablesItems = false`.

## Testing

- Tests use a temporary directory for `DataStore` and never read real data, browser folders or the keychain.
- Model operations are tested through `AppModel` (integration, not isolated units), checking both the mutation and the JSON round trip.
- All tests use swift-testing (`import Testing`, `@Suite`, `@Test`, `#expect`, `#require`); XCTest is not available with Command Line Tools only.
- swift-testing runs tests in parallel: don't share mutable global state (UserDefaults, the real data dir) between tests. Fixtures go in the suite's `init()` (a fresh instance per test), not `setUp`.
- Opt-in acceptance tests run against real files only when an env var points at a **copy**: `SIDEBARC_V1_FIXTURE` (v1 `data.json` → migration, zero lost links) and `SIDEBARC_ARC_FIXTURE` (`StorableSidebar.json` → favorites per profile). They print counts only; never commit those files.
- `SIDEBARC_TAB_PROBE=<bundle id>` runs an opt-in, counts-only probe of a running browser's tabs with the real locator (needs Automation granted to the terminal; never asks, never focuses).
- When the app misbehaves and the cause isn't certain, verify first (an off-screen-window probe test or temporary diagnostics) before changing code.

## Where to look

| Topic | File |
|---|---|
| Build steps, signing, Info.plist, permissions troubleshooting | [docs/BUILD_AND_CODESIGN.md](docs/BUILD_AND_CODESIGN.md) |
| Versioning, DMG, releases | [docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) |
| Data flow, data model, mutation pattern, node tree operations, list updates, space colours, search | [docs/INTERNALS.md](docs/INTERNALS.md) |
| Profiles, Favorites, browser routing, window attachment, browser profiles, Arc import, agent API v2 | [docs/PROFILES_AND_BROWSERS.md](docs/PROFILES_AND_BROWSERS.md) |
| Switching to open tabs | [docs/TAB_FOCUS.md](docs/TAB_FOCUS.md), manual checklist [docs/TAB_FOCUS_CHECKLIST.md](docs/TAB_FOCUS_CHECKLIST.md) |
| Space layout, space bar, header, menu, Settings, transitions, Favorites grid | [docs/SPACES.md](docs/SPACES.md) |
| Base classes, `ThemeConstants`, component patterns | [docs/COMPONENT_USAGE_GUIDE.md](docs/COMPONENT_USAGE_GUIDE.md) |
| Project structure, architecture overview | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Refactoring history (2026-02-10) | [docs/REFACTORING_PLAN.md](docs/REFACTORING_PLAN.md) |
