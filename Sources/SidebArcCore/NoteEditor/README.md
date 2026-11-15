# Note Editor — bundled assets

This directory is copied verbatim into `SidebArc.app/Contents/Resources/NoteEditor/`
and served by `NoteServer` over a token-authenticated loopback HTTP listener.

## Layout

- `index.html` — minimal two-tab UI (Edit / Preview).
- `editor.css` — hand-written styles, no framework.
- `editor.js` — load/save logic against `/api/notes/<uuid>`.
- `vendor/marked.min.js` — markdown parser, fetched from npm.
- `vendor/purify.min.js` — HTML sanitizer for the preview pane.

## Vendored library versions

| File              | Package    | Version | Source                                                              |
| ----------------- | ---------- | ------- | ------------------------------------------------------------------- |
| `marked.min.js`   | marked     | 13.0.3  | https://cdn.jsdelivr.net/npm/marked@13.0.3/marked.min.js            |
| `purify.min.js`   | dompurify  | 3.4.18  | https://registry.npmjs.org/dompurify/-/dompurify-3.4.18.tgz        |

To update, replace the file in `vendor/` with a newer minified build from npm
and update the table above. There is no build step — the file is shipped as-is.

`auth.js` takes the per-launch API token from the URL fragment and keeps it in
the tab's history state; the static files need no token, so the page loads them
with plain `<script src>`/`<link>` under a CSP that forbids inline code.

The editor sends one save at a time, each based on the content revision it last
saw; if another client changed the note, the server answers 409 and the editor
keeps the local text visible instead of overwriting. Pending edits are flushed on
page hide with a keepalive request (best effort; browsers cap keepalive bodies at
64 KiB, larger ones are sent normally and may be cut off).
