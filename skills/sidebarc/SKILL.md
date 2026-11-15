---
name: sidebarc
description: >
  Organize bookmarks, bookmark folders, favorites, and markdown notes in the
  SidebArc macOS app. Use this skill when the user asks to save a link, pin a
  favorite, organize or move bookmarks between SidebArc workspaces or profiles,
  take notes in SidebArc, or otherwise tidy their SidebArc sidebar. Not for creating files or folders
  on disk or in a code project.
last-updated: 2026-11-14
allowed-tools: Bash(./scripts/sidebarc.js:*)
---

# SidebArc Agent Skill

SidebArc is a macOS sidebar app for organizing bookmarks and short markdown
notes inside named, color-coded **workspaces**. This skill lets you create
and rearrange that content on the user's behalf — atomically, with no manual
file editing.

## Setup / prerequisites

- **SidebArc must be running.** All commands talk to a local HTTP server inside
  the running app.
- If a command exits with `code: "app_not_running"`, **stop and ask the user
  to launch SidebArc.app** before retrying. Do not loop on retries.
- You do not need network access; everything is on `127.0.0.1`.

## Glossary

- **Workspace** — a named, colored top-level container (e.g. "Reading",
  "Work"). Workspaces hold nodes. The agent can create and rename them, but
  **cannot delete workspaces** — this is a hard rule.
- **Folder** — a named container that can hold links, notes, and other
  folders. Nestable.
- **Link** — a bookmark with a title and a URL. The app fetches favicons
  automatically.
- **Note** — a markdown document with a title and a body. Body content is
  stored as a `.md` file and read/written with `notes:read` and `notes:write`.
- **Node** — any of folder, link, or note. Generic operations like
  `nodes:move` work on all three.
- **Profile** — a group of workspaces that share a browser setup and the
  Favorites grid (like an Arc profile, e.g. "Personal", "Work"). Every
  workspace belongs to exactly one profile (`profileId`). A profile can name a
  browser (`browserBundleId`, e.g. `org.mozilla.firefox`); `null` means the
  app's default browser. The agent can create, rename, and set the browser of
  profiles, and move workspaces between them, but **cannot delete profiles**.
- **Favorite** — a link in a profile's Favorites tile grid, shown at the top
  of every workspace in that profile (at most 12). Favorites are not nodes:
  use the `favorites:*` commands, not `nodes:*`.
- **Browser override** — a link can always open in a specific browser
  (`links:set-browser`), regardless of its workspace's profile.

## Common Actions

| User phrasing | Command |
|---|---|
| "Save this here" / "Add this to the workspace I'm in" | `workspaces:current` to get the id, then `links:create --workspace WS_ID --url URL` |
| "Save this link in my Reading workspace" | `links:create --workspace WS_ID --url URL` |
| "Add a folder called Reading" | `folders:create --workspace WS_ID --name "Reading"` |
| "Group these tabs into a Research folder in my Reading workspace" | create folder, then `nodes:move` each link with `--to-parent FOLDER_ID` |
| "Move this link to my Work workspace" | `nodes:move LINK_ID --to-workspace WORK_WS_ID` |
| "Rename this folder to Inbox" | `folders:rename FOLDER_ID --name "Inbox"` |
| "Take a note titled Plan" | `notes:create --workspace WS_ID --title "Plan"` |
| "Write up this meeting in a note" | `notes:create ... --content -` then pipe markdown to stdin |
| "What's in my Reading workspace?" | `tree WS_ID` |
| "Make a new workspace called Research" | `workspaces:create --name "Research"` |
| "Pin this to my favorites" | `workspaces:current` → its `profileId`, then `favorites:add --profile PROFILE_ID --url URL` |
| "Put my Work spaces in a Work profile that opens in Firefox" | `profiles:create --name "Work"`, `profiles:set-browser ID --browser org.mozilla.firefox`, then `workspaces:set-profile` per space |
| "Always open this link in Safari" | `links:set-browser LINK_ID --browser com.apple.Safari` |
| "What are my favorites?" | `profiles:list` |
| "Delete this bookmark" | `nodes:delete NODE_ID` (or `links:delete`) |

## Workflow

1. **Find ids first.** Run `sidebarc.js state` (or `sidebarc.js workspaces:list`
   plus `sidebarc.js tree WORKSPACE_ID`) to discover the workspace, folder,
   and node UUIDs you need. Never invent or guess ids.
   - When the user says "this workspace", "the current one", "the one I'm
     in", or "here", resolve it with `sidebarc.js workspaces:current`. The
     response is `{ selected, settingsSelected, workspace: { id, name, colorId } | null }`.
     If `selected` is false (e.g. the user is on the Settings screen),
     ask which workspace to use instead of guessing.
2. **Decide on a target.** Pick which workspace and (optionally) parent
   folder a new node should live in. If the user is ambiguous, ask.
3. **Compose atomic mutations.** Run one CLI command per action. Each
   command is a single API call; the running app updates the sidebar
   immediately.
4. **Confirm before destructive bulk work.** Before deleting multiple
   nodes — especially folders containing many children — or favorites,
   confirm with the user. Deletes are not undoable from the CLI. To take a
   favorite off the grid without losing it, prefer `favorites:unpin`.

## Writing note bodies

Three ways to supply note content, in order of preference for long
documents:

- `--content -` reads the body from stdin. Use this when piping or
  here-docs:

  ```bash
  ./scripts/sidebarc.js notes:write NOTE_ID --content - <<'EOF'
  # Heading
  Paragraph with **markdown**.
  EOF
  ```

- `--file path/to/file.md` reads a file from disk.

- `--content "..."` for short snippets that fit on a single command line.

`notes:read NOTE_ID` prints the body to stdout so you can fetch existing
content before editing.

## Moving across workspaces

`nodes:move` is the universal mover. It accepts:

- `--to-workspace ID` — moves to a different workspace. Omit to move within
  the current workspace.
- `--to-parent ID` — drops the node inside that folder. Pass the literal
  `root` to move to the workspace root.
- `--index N` — position within the parent (0-based). Omit to append.
  When moving within the same workspace, omitting `--to-parent` keeps the
  current parent. A cross-workspace move without it goes to the root.

Combinations:

- Same workspace, reorder: `nodes:move ID --to-parent FOLDER_ID --index 0`
- Cross workspace, into a folder: `nodes:move ID --to-workspace WS --to-parent FOLDER_ID`
- Cross workspace, to root: `nodes:move ID --to-workspace WS --to-parent root`

## Rules and limits

- **Never delete a workspace or a profile.** There is no command for
  either; do not try. If the user explicitly asks, explain that they must be
  removed manually from the app (deleting a profile moves its workspaces and
  favorites to another profile).
- A profile holds at most 12 favorites. `favorites:add` fails with
  `favorites_full` when the grid is full, and with `duplicate_favorite` when
  the URL is already a favorite (the error message carries its id).
- Browsers are identified by bundle id (e.g. `com.google.Chrome`,
  `org.mozilla.firefox`, `com.apple.Safari`). Pass `default` to clear a
  profile's browser or a link's override.
- Workspace **color names**: Blush, Apricot, Butter, Leaf, Mint, Sky,
  Periwinkle, Lavender, Rose, Peach, Sand, Sage, Seafoam, Cornflower, Orchid,
  Stone. Case-insensitive; raw enum cases (ember, ruby, coral, tangerine,
  moss, ocean, indigo, graphite) also work. Setting a color replaces a custom
  color picked in the app; `colorId` reports the preset even while a custom
  color is set.
- Every command exits non-zero on failure and prints `{ error, code, ... }`
  to stderr. Inspect `code` — `app_not_running`, `workspace_not_found`,
  `parent_not_folder`, `node_not_found`, `profile_not_found`,
  `favorite_not_found` are the common ones.
- Typed delete commands reject a node of a different type; use `nodes:delete`
  only when deleting any node type is intended.

## Commands Reference

```
state                                  Dump the full AppState JSON.
tree WORKSPACE_ID                      Dump one workspace's tree.

workspaces:list                          Each entry includes its profileId.
workspaces:current                       Workspace currently visible in the app.
workspaces:create        --name "X" [--color NAME] [--profile ID]
workspaces:rename ID     --name "Y"
workspaces:set-color ID  --color NAME
workspaces:set-profile ID --profile PROFILE_ID

profiles:list                            Profiles with workspaceIds and favorites.
profiles:create          --name "X"
profiles:rename ID       --name "Y"
profiles:set-browser ID  --browser BUNDLE_ID|default

favorites:add    --profile ID --url URL [--title T]
favorites:move   ID  --index N
favorites:unpin  ID  --workspace WS_ID   Moves it into that workspace's list.
favorites:delete ID

folders:create   --workspace ID [--parent ID|root] --name "X" [--expanded true|false]
folders:rename   ID  --name "Y"
folders:delete   ID

links:create     --workspace ID [--parent ID|root] --url URL [--title T]
links:rename     ID  --title "Y"
links:set-url    ID  --url URL
links:set-browser ID --browser BUNDLE_ID|default
links:delete     ID

notes:create     --workspace ID [--parent ID|root] --title T [--content TEXT | --file PATH | --content -]
notes:rename     ID  --title "Y"
notes:read       ID
notes:write      ID  --content TEXT | --file PATH | --content -
notes:delete     ID

nodes:move       ID [--to-workspace ID] [--to-parent ID|root] [--index N]
nodes:delete     ID
```

## Examples

Group two existing links into a new folder inside the Reading workspace:

```bash
# 1. Find the ids.
./scripts/sidebarc.js workspaces:list
# -> [{"id":"...reading...","name":"Reading", ...}]

./scripts/sidebarc.js tree READING_WS_ID
# Pick out the two link ids from the tree output.

# 2. Create the folder.
FOLDER_ID=$(./scripts/sidebarc.js folders:create \
  --workspace READING_WS_ID --name "Research" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

# 3. Move each link into it.
./scripts/sidebarc.js nodes:move LINK_ID_1 --to-parent "$FOLDER_ID"
./scripts/sidebarc.js nodes:move LINK_ID_2 --to-parent "$FOLDER_ID"
```

Create a note in Reading and fill it with markdown from stdin:

```bash
NOTE_ID=$(./scripts/sidebarc.js notes:create \
  --workspace READING_WS_ID --title "Weekly plan" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

./scripts/sidebarc.js notes:write "$NOTE_ID" --content - <<'EOF'
# Weekly plan

- Finish the report
- Email the team
EOF
```

Save a link in Work, then move it to a Reading subfolder:

```bash
LINK_ID=$(./scripts/sidebarc.js links:create \
  --workspace WORK_WS_ID --url "https://anthropic.com" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

./scripts/sidebarc.js nodes:move "$LINK_ID" \
  --to-workspace READING_WS_ID --to-parent RESEARCH_FOLDER_ID
```
