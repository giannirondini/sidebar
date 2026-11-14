# Changelog

## 2026-11-14

- Skill renamed to `sidebarc` for the SidebArc fork; CLI renamed to
  `scripts/sidebarc.js`.
- The CLI discovers the running app via
  `~/Library/Application Support/io.github.giannirondini.sidebarc/agent-endpoint.json`,
  so it drives SidebArc, never an Arcmark install on the same Mac.
- Narrowed the trigger to SidebArc bookmarks and notes, so requests such as
  "create a folder" in a code project don't invoke the app's API.
