# Chrome Bookmarks HTML Import Architecture

This document describes how Chrome exports bookmarks, the Netscape Bookmark HTML format, and how SidebArc parses and imports them.

## Overview

Chrome (and all Chromium-based browsers) can export bookmarks as an HTML file via the Bookmark Manager. Unlike Arc, which stores bookmarks in a JSON file at a known path, Chrome has no stable file-system path that can be read directly — the user must manually export. Settings › **Import from Chrome** opens a file picker (`.html` only); the file is parsed off the main thread and added as one new **space**, "Imported Bookmarks", in the current space's profile. Favorites are not touched.

## The Netscape Bookmark File Format

### Background

The Netscape Bookmark File format dates back to the 1990s Netscape Navigator browser. It became the de facto standard for bookmark interchange between browsers. Chrome, Firefox, Safari, Edge, Brave, and virtually all browsers support exporting and importing this format.

The format is **not valid XML or XHTML**. It uses a loose, non-standard HTML dialect with unclosed tags and non-standard elements. This is why the parser scans for a few tags with a regex rather than using an XML/HTML parser.

### Specification Reference

There is no official W3C specification. The format is documented through reverse engineering and community documentation:
- Microsoft's original documentation: [Netscape Bookmark File Format](https://learn.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/platform-apis/aa753582(v=vs.85))
- The `NETSCAPE-Bookmark-file-1` DOCTYPE identifier is the universal marker

### File Structure

```html
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<!-- This is an automatically generated file.
     It will be read and overwritten.
     DO NOT EDIT! -->
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3 ADD_DATE="..." LAST_MODIFIED="..." PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
    <DL><p>
        <DT><A HREF="https://example.com" ADD_DATE="1234567890" ICON="data:image/...">Example</A>
        <DT><H3 ADD_DATE="..." LAST_MODIFIED="...">Subfolder</H3>
        <DL><p>
            <DT><A HREF="https://nested.com" ADD_DATE="1234567890">Nested Link</A>
        </DL><p>
    </DL><p>
    <DT><H3 ADD_DATE="..." LAST_MODIFIED="...">Other bookmarks</H3>
    <DL><p>
        <DT><A HREF="https://other.com" ADD_DATE="1234567890">Other Link</A>
    </DL><p>
</DL><p>
```

### Key Elements

| Element | Meaning | Example |
|---------|---------|---------|
| `<!DOCTYPE NETSCAPE-Bookmark-file-1>` | File format identifier | Always first line |
| `<DL>` | Definition List — opens a group of items | Wraps folder contents |
| `</DL>` | Closes a definition list | Ends folder contents |
| `<DT>` | Definition Term — prefix for each item | Before every link or folder |
| `<H3>` | Folder header | `<DT><H3>Folder Name</H3>` |
| `<A HREF="...">` | Bookmark link | `<DT><A HREF="url">Title</A>` |
| `<p>` | Decorative — has no semantic meaning | Ignored by parser |

### Common Attributes on Elements

**On `<H3>` (folder headers):**
- `ADD_DATE` — Unix timestamp when folder was created
- `LAST_MODIFIED` — Unix timestamp of last modification
- `PERSONAL_TOOLBAR_FOLDER="true"` — marks the Bookmarks bar folder

**On `<A>` (links):**
- `HREF` — the bookmark URL
- `ADD_DATE` — Unix timestamp when bookmark was created
- `ICON` — base64-encoded favicon (data URI), ignored by our parser
- `ICON_URI` — URL to favicon (Firefox), ignored by our parser

### Chrome's Top-Level Folder Structure

Chrome always exports with these top-level folders:

| Folder Name | Chrome UI Location | `PERSONAL_TOOLBAR_FOLDER` |
|-------------|-------------------|---------------------------|
| `Bookmarks bar` | Chrome's bookmarks bar | `true` |
| `Other bookmarks` | "Other Bookmarks" section | not set |
| `Mobile bookmarks` | Synced mobile bookmarks | not set |

These are structural containers, not user-created folders. The importer **flattens** them — their children are merged into the root level of the new space.

## How to Export from Chrome

1. Open Chrome
2. Click the three-dot menu → **Bookmarks and lists** → **Bookmark manager**
3. In the Bookmark Manager, click the three-dot menu (top-right) → **Export bookmarks**
4. Save the HTML file

This produces a file typically named `bookmarks_MM_DD_YY.html`.

## Import Algorithm

### Step 1: Validation

1. Check the file exists on disk
2. Read as UTF-8 string
3. Validate the content contains `NETSCAPE-Bookmark-file-1`, `<DL>`, or `<dl>` to confirm it's a bookmark file
4. If validation fails, return `.invalidHTML` error

### Step 2: Tokenizing

The parser scans the whole file once, in document order, for four tokens (one regex, `.caseInsensitive` and `.dotMatchesLineSeparators`):

```
Folder:  <H3 …>Name</H3>    → folder name
Link:    <A …>Title         → attributes and title (text up to the next tag)
Open:    <DL …>             → begins a list
Close:   </DL>              → ends the innermost list
```

Line breaks don't matter: a minified one-line file parses like Chrome's one-element-per-line output, and a link's attributes may span lines. `<DT>` and `<p>` are ignored.

`HREF` is found **anywhere** among the link's attributes, in any case, double-quoted, single-quoted or unquoted. The attribute pattern is quote-aware, so a `>` inside a quoted value (`TAGS="a>b"`) doesn't end the tag. The title is the text after `<A …>` up to the next `<`, so a missing `</A>` can't swallow the next link. `HREF` values are used as written (no entity decoding).

### Step 3: Nesting

The parser keeps a stack of levels, the root first and one per open folder, and a stack of open lists:

```
levels: [Level]        — Level = (folderName, nodes being built); levels[0] is the root
openLists: [Bool]      — one per open <DL>: whether it opened a folder level
pendingFolderName      — set by <H3>, consumed by the next <DL>
```

#### State Machine

```
On <H3>Name</H3>:
  Flush a pending folder (see below)
  pendingFolderName = Name (entities decoded)

On <A … HREF=url …>Title:
  Flush a pending folder
  Skip if the URL is empty, javascript:, chrome:// or malformed
  Append a Link (title entity-decoded, "Untitled" if empty) to the innermost level

On <DL>:
  If a folder name is pending: push a level for it, openLists.push(true)
  Else (the root list):        openLists.push(false)

On </DL>:
  Flush a pending folder
  Pop openLists (a stray </DL> with nothing open is ignored)
  If that <DL> opened a folder level: close the level

Close a level:
  Pop it; if it's a top-level Chrome folder directly under the root, append its
  nodes to the root (flatten), else wrap them in a Folder in the parent level

Flush a pending folder:
  An <H3> not followed by its <DL> becomes an empty folder in the current level

At the end of the file:
  Flush a pending folder, then close every level still open into its parent
```

**No link is dropped by a malformed file**: a missing `</DL>` leaves levels open, and they are closed into their parents at the end of the file, so their links land in the folder they were written in.

#### Visual Example

Given this HTML:
```html
<DL>
  <DT><H3>Bookmarks bar</H3>
  <DL>
    <DT><A HREF="https://a.com">A</A>
    <DT><H3>Dev</H3>
    <DL>
      <DT><A HREF="https://b.com">B</A>
    </DL>
  </DL>
</DL>
```

Parser trace:
```
<DL>                    → no pending folder: openLists=[false]
<H3>Bookmarks bar</H3>  → pending "Bookmarks bar"
<DL>                    → push level "Bookmarks bar", openLists=[false, true]
<A HREF=a.com>A         → Link(A) into "Bookmarks bar"
<H3>Dev</H3>            → pending "Dev"
<DL>                    → push level "Dev", openLists=[false, true, true]
<A HREF=b.com>B         → Link(B) into "Dev"
</DL>                   → close "Dev": Folder(Dev, [B]) into "Bookmarks bar"
</DL>                   → close "Bookmarks bar": top-level under the root → FLATTEN
</DL>                   → the root list: nothing to close

Result: [Link(A), Folder(Dev, [Link(B)])]
```

Without the last two `</DL>`s the result is the same: both levels are closed at the end of the file.

### Step 4: Top-Level Folder Flattening

The following folder names are recognized as Chrome's structural containers and flattened:

```swift
static let topLevelFolderNames: Set<String> = [
    "Bookmarks bar",
    "Other bookmarks",
    "Mobile bookmarks",
    "Bookmarks Bar"       // alternate capitalization
]
```

Flattening means: when one of these folders is closed directly under the root (by its `</DL>` or at the end of the file), its children are appended to the root rather than wrapped in a Folder node.

This ensures the user doesn't see Chrome's internal folder structure in SidebArc. A user with bookmarks in both "Bookmarks bar" and "Other bookmarks" gets all of them at the root level.

### Step 5: Apply to SidebArc

`SettingsContentViewController.applyChromeImport`:

1. **Create the space and its complete node tree** with `AppModel.applyChromeImport`, in the current space's profile. The model selects it and saves and notifies once.
2. **Stay on Settings**: it doesn't call `selectWorkspace` (that would close Settings). Leaving Settings shows the new space. Arc import, by contrast, leaves the selection unchanged.

## Data Mapping

| Chrome HTML Element | SidebArc Concept | Notes |
|---------------------|-----------------|-------|
| `<H3>` folder header | Folder node | Name extracted from inner text; imported collapsed |
| `<A HREF>` link | Link node | URL from HREF attribute, title from inner text |
| `<DL>...</DL>` block | Folder children | Nesting depth preserved |
| Bookmarks bar folder | (flattened) | Children merged into root |
| Other bookmarks folder | (flattened) | Children merged into root |
| Mobile bookmarks folder | (flattened) | Children merged into root |
| `ADD_DATE` attribute | (ignored) | Not imported |
| `ICON` attribute | (ignored) | Favicons fetched fresh by FaviconService |
| `LAST_MODIFIED` attribute | (ignored) | Not imported |

## HTML Entity Decoding

Titles, folder names **and `HREF` values** are decoded with `HTMLEntities.decode` (`Utilities/HTMLEntities.swift`, shared with the page-title fetch), in one pass: decimal and hex references (`&#39;`, `&#x27;`) and the named ones these files use (`&amp;`, `&lt;`, `&gt;`, `&quot;`, `&apos;`, `&nbsp;`, dashes, quotes, `&hellip;`, …). Unknown or malformed references stay as written, and nothing is decoded twice (`&amp;lt;` → `&lt;`).

Chrome writes `HREF` raw (only `"` becomes `&quot;`); Firefox-style files escape it, so `…?a=1&amp;b=2` is imported as `…?a=1&b=2`.

## URL Validation

The decoded `HREF` goes through `ImportedURL.normalized` (`Utilities/ImportedURL.swift`, shared with the Arc import): it's trimmed, and characters a strict parser rejects (spaces, `"`, `<`, `|`, non-ASCII text, …) are percent-encoded after the scheme and host; existing `%XX` escapes and the host are left alone. `URL(string:)` is strict on macOS 13 and lenient from macOS 14, so without this a link with a space would be skipped on one and kept on the other. The encoded string is what's stored.

Links are skipped if any of these conditions are true:

| Condition | Reason |
|-----------|--------|
| URL string is empty | No valid URL |
| Starts with `javascript:` | Bookmarklets, not navigable URLs |
| Starts with `chrome://` | Chrome-internal pages, not accessible from other browsers |
| `URL(string:)` returns `nil` after encoding | Malformed URL that Foundation can't parse |

A relative string is kept (imports never drop links) but `BrowserManager.validatedLinkURL` never opens it.

## Why Not XMLParser or HTML Parsing Libraries?

The Netscape Bookmark format has several properties that make XML/HTML parsers a poor choice:

1. **Not valid XML**: The `<p>` tags are unclosed, `<DT>` tags are unclosed, and there's no proper root element
2. **Not valid HTML5**: The DOCTYPE is non-standard (`NETSCAPE-Bookmark-file-1`)
3. **No need for DOM**: We only need four token types (folder, link, DL open, DL close) — a full DOM is unnecessary overhead
4. **Few, simple tokens**: four tag types carry all the structure, wherever the line breaks fall
5. **Zero dependencies**: Regex scanning uses Foundation's `NSRegularExpression`, no third-party libraries needed

The single-pass regex scan is simple, fast, and tolerant of minified or slightly malformed files.

## Example: Complete Flow

### Input: Chrome Bookmarks HTML
```html
<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3 PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
    <DL><p>
        <DT><A HREF="https://github.com" ADD_DATE="1700000000">GitHub</A>
        <DT><H3>Development</H3>
        <DL><p>
            <DT><A HREF="https://stackoverflow.com" ADD_DATE="1700000001">Stack Overflow</A>
            <DT><A HREF="javascript:void(0)">Some Bookmarklet</A>
        </DL><p>
    </DL><p>
    <DT><H3>Other bookmarks</H3>
    <DL><p>
        <DT><A HREF="https://example.com" ADD_DATE="1700000002">Example &amp; More</A>
    </DL><p>
</DL><p>
```

### Output: SidebArc Structure
```
Space: "Imported Bookmarks" (color: ember)
├── Link: "GitHub" (https://github.com)
├── Folder: "Development"
│   └── Link: "Stack Overflow" (https://stackoverflow.com)
└── Link: "Example & More" (https://example.com)
```

### What Happened
1. **"Bookmarks bar"** folder was flattened — its children (GitHub link, Development folder) went to root
2. **"Other bookmarks"** folder was flattened — its child (Example link) went to root
3. **"Some Bookmarklet"** with `javascript:` URL was skipped
4. **`&amp;`** in "Example &amp; More" was decoded to `&`
5. All `ADD_DATE` attributes were ignored

## Differences from Arc Import

| Aspect | Arc Import | Chrome Import |
|--------|-----------|---------------|
| Source | Fixed path (`~/Library/.../StorableSidebar.json`) | User-selected HTML file |
| Format | JSON | Netscape Bookmark HTML |
| Parser | JSONDecoder + Codable models | Single-pass regex tokenizer |
| Spaces | Multiple (one per Arc space, in the Arc profile's profile) | Single ("Imported Bookmarks", current profile) |
| Top-level folders | N/A (Arc spaces become spaces) | Flattened into root |
| Favorites | Per Arc profile (`topAppsContainerIDs`) | None |
| File picker | No (reads from known path) | Yes (NSOpenPanel, .html filter) |
| Post-import | Selection unchanged; one `AppModel` mutation | Selects the new space, stays on Settings; one `AppModel` mutation |
| Color assignment | Cyclic (ember, ruby, coral, ...) | Always `.ember` |

## Edge Cases Handled

### 1. Empty Bookmarks File
If the file contains valid Netscape headers but no `<DT>` entries, returns `.noBookmarksFound`.

### 2. Empty Link Titles
Links with empty inner text (e.g., `<DT><A HREF="url"></A>`) get the title "Untitled".

### 3. Nested Top-Level Folders
Only the immediate children of Chrome's structural folders are flattened. If "Bookmarks bar" contains a user folder called "My Stuff", that folder is preserved as-is — only "Bookmarks bar" itself is unwrapped.

### 4. Deep Nesting
Folder nesting of arbitrary depth is fully preserved. The stack-based parser naturally handles this.

### 5. Mixed Content
Folders and links at the same level are preserved in file order. A sequence of link-folder-link produces exactly that order in the output.

### 6. Non-Chrome Browsers
All Chromium browsers (Brave, Edge, Vivaldi, Opera), Firefox and Safari export the same Netscape format, so the parser reads their files too. Only the four folder names above are flattened (exact, case-sensitive match); other browsers' top-level folders (Firefox's "Bookmarks Toolbar", for example) are imported as ordinary folders.

### 7. Case Variations
All regex patterns use `.caseInsensitive` to handle `<DL>` vs `<dl>`, `<DT>` vs `<dt>`, etc. Some browsers output lowercase HTML.

## Favicon Handling

Favicons are NOT extracted from the HTML file's `ICON` or `ICON_URI` attributes. Instead:

1. Links are created with `faviconPath: nil`
2. When shown, the list (`NodeListViewController`) requests favicons from `FaviconService`
3. `FaviconService` fetches fresh favicons asynchronously from each site
4. Favicons are cached in `~/Library/Application Support/io.github.giannirondini.sidebarc/Icons/`

Rationale: Chrome's exported `ICON` attributes contain base64-encoded data URIs that would need to be decoded and saved to disk. Fetching fresh favicons is simpler, produces consistent results with the rest of the app, and avoids storing potentially stale icons.

## Error Handling

| Error | When | User-Facing Message |
|-------|------|---------------------|
| `.fileNotFound` | File doesn't exist at the provided URL | "The selected file could not be found." |
| `.invalidHTML` | File lacks `NETSCAPE-Bookmark-file-1`, `<DL>`, or `<dl>` | "The selected file is not a valid Chrome bookmarks HTML file." |
| `.noBookmarksFound` | Valid file structure but no links or folders parsed | "No bookmarks were found in the file." |
| `.parsingFailed(detail)` | Unexpected error during regex compilation or parsing | "Failed to parse Chrome bookmarks: [detail]" |

## Concurrency Model

- The `importFromChrome` method is `async` and returns a `Result` type
- `Task.yield()` is called first to allow the UI to update (show loading spinner)
- `Task.detached` offloads the CPU-intensive parsing to a background thread
- The caller (`handleChromeImport` in `SettingsContentViewController`) runs on `@MainActor`
- A concurrent import guard prevents both Arc and Chrome import from running simultaneously

## Testing

### Test Helper: HTML Generation

Tests use a `createBookmarksHTML(body:)` helper that wraps content in the standard Netscape header:

```swift
func createBookmarksHTML(body: String) -> String {
    return """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
    \(body)
    </DL><p>
    """
}
```

### Test Cases (`ChromeImportTests`)

| Test | What It Verifies |
|------|-----------------|
| Basic link parsing | URL and title extracted correctly from `<A>` |
| Folder with nested links | `<H3>` + `<DL>` creates Folder with children |
| Deep nesting (3+ levels) | Stack handles arbitrary depth |
| Top-level folders flattened | "Bookmarks bar" and "Other bookmarks" unwrapped |
| Empty bookmarks file | Returns `.noBookmarksFound` |
| Invalid/non-HTML file | Returns `.invalidHTML` |
| HTML entities decoded | `&amp;`, `&#39;`, etc. in titles |
| Order preserved | Links appear in file order |
| Empty title | Falls back to "Untitled" |
| Space properties | Name is "Imported Bookmarks", colorId is `.ember` |
| File not found | Returns `.fileNotFound` |
| Invalid URLs skipped | `javascript:`, `chrome://`, empty URLs |
| HTML entities in folder names | Entity decoding applies to `<H3>` content too |
| Entities not double-decoded | `&amp;lt;` stays `&lt;` (one pass) |
| Mixed content | Folders and links at same level, correct order |
| Missing `</DL>` | Folders left open at the end of the file keep their links, in place |
| Minified one-line file | Every link and folder imported regardless of line breaks |
| `HREF` in any position | After other attributes, lower case, single-quoted, unquoted, with a quoted `>` in another attribute |
| Heading without list, stray `</DL>` | Empty folder kept; a stray close doesn't break the structure |
| `HREF` entities and spaces | `&amp;` and `&#38;` decoded, `&quot;` and spaces percent-encoded, in any quoting; bookmarklets still skipped |

## References

### Source Files
- **ChromeImportService.swift** — Parser and import logic
- **SettingsContentViewController.swift** — UI (file picker, buttons, status display)
- **ChromeImportTests.swift** — Unit tests
- **Models.swift** — `Node`, `Folder`, `Link` data models
- **ArcImportService.swift** — `ImportWorkspace` struct (shared between importers)
- **AppModel.swift** — `applyChromeImport`

### External References
- [Netscape Bookmark File Format (Microsoft)](https://learn.microsoft.com/en-us/previous-versions/windows/internet-explorer/ie-developer/platform-apis/aa753582(v=vs.85))
- [Chrome Bookmark Manager](https://support.google.com/chrome/answer/188842) — Google's help article on managing bookmarks
- [Chromium source: bookmark_html_writer.cc](https://source.chromium.org/chromium/chromium/src/+/main:chrome/browser/bookmarks/bookmark_html_writer.cc) — Chrome's actual HTML export implementation

## Appendix: Browser Compatibility

The Netscape Bookmark HTML format is exported by all major browsers. The parser should work with exports from:

| Browser | Export Location | Tested |
|---------|----------------|--------|
| Google Chrome | Bookmark Manager → Export | Yes (upstream) |
| Brave | Bookmark Manager → Export | Expected (same Chromium base) |
| Microsoft Edge | Favorites → Export | Expected (same Chromium base) |
| Vivaldi | Bookmarks → Export | Expected (same Chromium base) |
| Opera | Bookmarks → Export | Expected (same Chromium base) |
| Firefox | Library → Import/Export → Export HTML | Expected (same format) |
| Safari | File → Export Bookmarks | Expected (same format) |

All Chromium-based browsers use the same `bookmark_html_writer.cc` code to generate the HTML, so their output is identical in structure.

### Troubleshooting Import Issues

If import fails:

1. **"Not a valid Chrome bookmarks HTML file"**: The file may be a different format (JSON, XML, or plain text). Ensure you used Chrome's "Export bookmarks" option, not a third-party tool.

2. **"No bookmarks were found"**: The file is valid HTML but contains no `<DT><A>` links. This can happen if Chrome has no bookmarks at all.

3. **Missing bookmarks after import**: Check if some bookmarks had `javascript:` or `chrome://` URLs — these are intentionally skipped. Bookmarklets (JavaScript snippets saved as bookmarks) are not importable.

4. **Garbled characters in titles**: The parser assumes UTF-8 encoding (which Chrome always uses). If the file was re-saved in a different encoding, titles may not decode correctly.
