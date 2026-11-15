# Changelog

## 2026-11-14 (agent API v2)

- Profiles: `profiles:list`, `profiles:create`, `profiles:rename`,
  `profiles:set-browser`, and `workspaces:set-profile`; `workspaces:create`
  takes `--profile`. Workspace payloads include `profileId`. Profiles can't be
  deleted from the CLI.
- Favorites (the per-profile tile grid): `favorites:add`, `favorites:move`,
  `favorites:unpin`, `favorites:delete`.
- `links:set-browser` sets or clears a link's browser override.
- `state` reflects data schema v2 (`profiles`, `workspaces[].profileId`;
  `pinnedLinks` and per-workspace `browserProfiles` are gone). The endpoint
  file reports `schemaVersion: 2`.

## 2026-11-14

- Skill renamed to `sidebarc` for the SidebArc fork; CLI renamed to
  `scripts/sidebarc.js`.
- The CLI discovers the running app via
  `~/Library/Application Support/io.github.giannirondini.sidebarc/agent-endpoint.json`,
  so it drives SidebArc, never an Arcmark install on the same Mac.
- Narrowed the trigger to SidebArc bookmarks and notes, so requests such as
  "create a folder" in a code project don't invoke the app's API.
