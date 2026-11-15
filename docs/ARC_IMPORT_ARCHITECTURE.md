# Arc Browser Import

How Arc stores its sidebar and how SidebArc imports it (`ArcImportService.swift`, `AppModel.applyArcImport`).

## Overview

Settings › **Import from Arc Browser** reads `~/Library/Application Support/Arc/StorableSidebar.json` directly (there is no file picker; if the file doesn't exist, Settings says Arc wasn't found). The import adds one **space** per Arc space with pinned content, keeping the folder hierarchy, and merges each Arc profile's **Favorites** into the SidebArc profile with the same name. Existing spaces are kept; the selected space doesn't change. Parsing runs off the main thread (`Task.detached`); the result is applied in one `AppModel` mutation.

## Arc JSON structure

### Root

```json
{
  "sidebar": { "containers": [ /* usually two: one empty or metadata-only, one with the data */ ] },
  "version": 1
}
```

The importer uses the **first container that has both `spaces` and `items`**, whatever its index:

```json
{
  "spaces": [ /* strings and space objects */ ],
  "items": [ /* strings and item objects */ ],
  "topAppsContainerIDs": [ {"default": true}, "15C1…" ]
}
```

`spaces` and `items` mix string references with objects; the strings are skipped.

### Spaces

```json
{
  "id": "space-uuid",
  "title": "Work",
  "containerIDs": ["unpinned", "unpinned-container-id", "pinned", "pinned-container-id"],
  "profile": {"default": true}
}
```

`containerIDs` alternates markers and ids. The **pinned container** is the element after `"pinned"`, wherever it appears (`ArcSpace.pinnedContainerId`); the unpinned container (Arc's temporary tabs) is ignored. A space without a `"pinned"` entry is skipped. A space without `profile` belongs to Arc's default profile.

### Items

| Kind | Recognised by | Example fields |
|---|---|---|
| Container | the id a space or `topAppsContainerIDs` points to; may be missing from `items` | `childrenIds` |
| Folder | non-empty `childrenIds` | `title`, `parentID`, `childrenIds` |
| Link | `data.tab` with a non-empty `savedURL` that `URL(string:)` accepts | `data.tab.savedTitle`, `data.tab.savedURL` |

```json
{ "id": "folder-uuid", "title": "Development", "parentID": "pinned-container-id", "childrenIds": ["link-uuid"] }
{ "id": "link-uuid", "title": null, "parentID": "folder-uuid",
  "data": { "tab": { "savedTitle": "GitHub", "savedURL": "https://github.com", "timeLastActiveAt": 1704931200 } } }
```

Anything else (an empty folder, a tab without a usable URL, other item kinds) is skipped.

## Import algorithm

1. **Decode** `ArcData`. A JSON error → `invalidJSON`; no container with `spaces` and `items` → `noDataContainer`.
2. **Item map**: `items` objects by id.
3. **Spaces**, in Arc's order: find the pinned container, build its tree, skip the space if the tree is empty, name it (`title`, or "Untitled"; duplicates become "Work 2", "Work 3", …) and give it a colour by its index in Arc's space list (`ember`, `ruby`, `coral`, `tangerine`, `moss`, `ocean`, `indigo`, `graphite`, then repeat).
4. **Tree** (`buildNodeHierarchy`): when the parent is in the item map and has `childrenIds`, its children are those ids **in that order** (Arc's order). Otherwise (a container missing from `items`) the children are the items whose `parentID` is the parent, minus any item listed in some folder's `childrenIds`, so nothing appears twice. Folders recurse, skipping any child already on the path from the root (an item listing itself, or A → B → A in a corrupt file): only that edge is dropped, so the import can't recurse forever.
5. **Favorites** (`convertFavorites`): `topAppsContainerIDs` alternates `[profile, containerId, …]`. Each container's tree is flattened to its links, in order, giving one `ImportProfile` per Arc profile with at least one favorite. A missing or malformed list imports no favorites.

### Arc profiles

`space.profile` and the profile entries of `topAppsContainerIDs` are decoded as opaque JSON (`ArcJSON`) and reduced to an `ArcProfileKey`: a canonical key (equal JSON → equal key) and a name.

| Arc value | SidebArc profile name |
|---|---|
| `{"default": true}` (the only shape seen in real data) | "Default" (`Profile.defaultName`) |
| `{"custom": {"_0": {"directoryBasename": "Profile 1"}}}` (assumed shape) | "Arc Profile 1" |
| anything else | "Arc Profile" |

### Applying (`AppModel.applyArcImport`)

1. Each Arc profile maps to the existing profile with the same name (case-insensitive), or a new profile with that name.
2. Each imported space is appended to the spaces, in its Arc profile's profile.
3. Each Arc profile's favorites are merged into that profile with `Profile.appendFavorites` (deduplicated by `URLNormalization.key`, capped at `Profile.maxFavorites`, 12). Leftovers go into an expanded "Favorites (from Arc)" folder at the top of that profile's first imported space, else its first space. Favorites are imported even when all of that profile's spaces were skipped as empty. If no space exists at all, the state is left unchanged rather than drop links.

## Data mapping

| Arc | SidebArc | Notes |
|---|---|---|
| Space | Space (`Workspace`) | One per Arc space with pinned content |
| Pinned container | The space's pinned list (`items`) | |
| Unpinned container | — | Temporary tabs aren't imported |
| `topAppsContainerIDs` | `Profile.favorites` | Per Arc profile; overflow goes to a folder |
| `space.profile` | `Profile` | Matched by name |
| Folder item | `Folder` | Full nesting, imported **collapsed**; no title → "Untitled Folder" |
| Link item | `Link` | `savedURL` → `url`; `savedTitle` → `title` (empty or missing → "Untitled"); favicon fetched later |

## Decoding

Arc's format isn't documented and changes between versions, so decoding is lenient:

- `ArcContainer` decodes an object as `ArcContainerObject` and anything else as `.empty`.
- `ArcContainerObject` decodes `spaces`, `items` and `topAppsContainerIDs` with `try?`, so a missing or unexpected field becomes `nil` instead of failing.
- `ArcSpaceOrString` and `ArcItemOrString` handle the mixed string/object arrays.
- `ArcJSON` holds fields whose shape is only partly known (profiles).
- Optional fields (`title`, `savedTitle`, `savedURL`, `profile`) may be `null` or absent.

## Favicons

Favicons are not copied from Arc. Links are created with `faviconPath: nil`, and the list (`NodeListViewController`) and the Favorites grid (`PinnedTabsView`) ask `FaviconService` for them when shown; they are cached in the data directory's `Icons/`.

## Errors

| Case | Message |
|---|---|
| File missing (Settings) | "Arc browser not found or no bookmarks available. Please ensure Arc is installed and has bookmarks." |
| `fileNotFound` | "Arc bookmark file not found. Please locate StorableSidebar.json in Arc's data directory." |
| `invalidJSON` | "Invalid Arc bookmark file format. The file may be corrupted." |
| `noDataContainer` | "No bookmark data found in Arc file. Make sure you have bookmarks in Arc." |
| `parsingFailed` (e.g. the file can't be read) | "Failed to parse Arc bookmarks: …" |

## Tests

`ArcImportTests` covers null titles and URLs, `childrenIds` ordering and deep nesting, the `parentID` fallback, `containerIDs` with unpinned before pinned, favorites per profile, custom profile keys, malformed `topAppsContainerIDs`, spaces without `profile` and cycles in `childrenIds`. The opt-in `SIDEBARC_ARC_FIXTURE` test runs against a **copy** of a real `StorableSidebar.json` and prints counts only.

## Arc versions

The format was checked with Arc 1.36.0, 1.37.0 and 1.79.1 (Chromium 123–132). If Arc changes it, update the Codable models in `ArcImportService.swift` and add a test with the new shape.
