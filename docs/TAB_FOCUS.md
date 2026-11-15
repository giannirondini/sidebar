# Switching to open tabs

_Moved from CLAUDE.md on 2026-11-15. The rules most tasks need are summarised in [CLAUDE.md](../CLAUDE.md)._

- A **favorite click** focuses an already open tab showing it; a **pinned-list click** opens new; **⌥-click** inverts (⌘-click in the list is multi-select). Open All Links, scheduled links, Open in ▸ and notes always open new. Entry point: `MainViewController.openClickedLink` → `TabFocusService.open`.
- `TabFocus` (pure, unit-tested) decides; `TabLocator` (`ChromiumTabLocator` for Chrome/Brave, `SafariTabLocator`) lists tab URLs in one Apple Event and focuses a tab; `TabURLMatcher` matches. Raw Apple Events (`NSAppleEventDescriptor.sendEvent`, 300 ms timeout) sent **by pid** from a detached task: never `NSAppleScript` (main thread only) or `osascript` (child process); never send to a browser that isn't running (it would launch). Any failure opens normally.
- **Matching:** same scheme/host/port; prefix = tab path at or below the link's on a segment boundary + the link's query items in the tab; exact (`Link.exactTabMatch`, "Match Exact URL") = same path and query. Lossless: an encoded `/` (`%2F`) is not a separator, `//` keeps its empty segment (only one trailing `/` is ignored), `?flag` ≠ `?flag=`. Fragment ignored; `www.` and http/https are **not** equal. `URLNormalization` (favorites dedupe) is separate and must not change.
- **Browser profiles:** AppleScript can't tell which Chrome profile owns a window. `TabFocus.isAmbiguous` (profiles open the same browser with different browser-profile dirs) makes `Profile.focusesOpenTabs` default off (`nil` = automatic); Settings › Profiles warns when it's on.
- **Permission:** the click path uses `AEDeterminePermissionToAutomateTarget(askUserIfNeeded: false)` and never prompts; Settings › Permissions shows per-browser status and asks ("Allow Browser Access…"). A click without permission stores `tabFocusPermissionHintBundleId` for a Settings hint.
- **Not supported** (open new, no error): Firefox (no dictionary), Dia and Arc (own dictionaries, not verified; Dia is personal-Mac only), Edge/Vivaldi/Canary/Helium (not installed). Add a browser only after verifying it on a Mac: `TabLocators.locator(for:)`.
- Manual checklist for real browsers: [TAB_FOCUS_CHECKLIST.md](TAB_FOCUS_CHECKLIST.md).

## Click flow

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

- Chromium incognito windows are listed empty. Activation re-reads the chosen tab's URL and gives up (opens new) if it changed since the listing.
- Apple Events need `NSAppleEventsUsageDescription` in Info.plist (`Bundler.toml` + `patch_info_plist`), or macOS denies them without a prompt.
- **Tests:** `TabURLMatcherTests` (table), `TabFocusTests` (decisions, fake locator, Apple Event building, opt-in `SIDEBARC_TAB_PROBE`); real browsers: [TAB_FOCUS_CHECKLIST.md](TAB_FOCUS_CHECKLIST.md).

