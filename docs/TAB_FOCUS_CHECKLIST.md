# Switch to open tabs: manual checklist

The tab locators talk to real browsers over Apple Events, so they can't run in `swift test`. Unit tests cover the URL matcher (`TabURLMatcherTests`) and the decisions (`TabFocusTests`, with a fake locator). Run this checklist after changing `TabLocator`, `TabFocus`, `TabFocusService`, the signing scripts, or after a macOS or browser major update.

Browsers in scope: **Chrome, Brave, Safari** (corporate set). Everything else opens a new tab.

## Before you start

1. Build with `./scripts/run.sh` or `./scripts/build.sh`, then `./scripts/verify-build.sh`. Expect `NSAppleEventsUsageDescription present` and `Designated requirement: identifier "io.github.giannirondini.sidebarc"`.
2. Watch the log while testing:
   ```bash
   log stream --predicate 'subsystem == "io.github.giannirondini.sidebarc" AND category == "tabs"'
   ```
   Each click logs `Focused tab …`, `No open tab matched …`, `No Automation permission …` or `… failed …` with milliseconds, or `Opening new …` with the reason it didn't look (browser can't report tabs, switch off, list link, not running). These are kept, so after the fact `log show --last 10m --predicate '<same predicate>'` works too.
3. **The favorite's profile must open in Chrome, Brave or Safari, with Switch to open tabs on** (Settings › Profiles). A profile with no browser follows the macOS default browser; if that's Dia or Arc, every click opens new (F2). With Chrome `Default` and `Profile 1` both in use, the switch is off by default (E1).
4. Optional, outside the app: the counts-only probe lists a running browser's tabs with the real locator. It needs Automation already granted to the terminal and never asks.
   ```bash
   SIDEBARC_TAB_PROBE=com.google.Chrome swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" --filter 'TabFocusTests/liveProbe'
   ```

## A. Permission

| # | Steps | Expected |
|---|---|---|
| A1 | `tccutil reset AppleEvents io.github.giannirondini.sidebarc`, Chrome running, click a favorite whose page is open | A new tab opens (as before Phase 2). **No prompt.** Settings › Permissions › Automation shows the hint and "Google Chrome: not asked yet" |
| A2 | Settings › Permissions › **Allow Browser Access…** | macOS asks "SidebArc wants to control Google Chrome". Allow → status "✓ allowed", hint gone |
| A3 | Click the same favorite | Chrome comes forward on that tab; no new tab |
| A4 | **Rebuild** (`./scripts/run.sh`), relaunch, click the favorite | Still focuses; no prompt. *If it opens a new tab and Settings says "not asked yet", the bundle-id requirement didn't keep the grant: record it in the plan's Decisions log* |
| A5 | System Settings › Privacy & Security › Automation › SidebArc › turn Chrome off; click the favorite | A new tab opens, no error. Settings shows "not allowed"; **Allow Browser Access…** opens System Settings › Automation |
| A6 | Accessibility grant (window attachment) after a rebuild | Still granted (same requirement change) |

## B. Locators (repeat for Chrome, Brave, Safari)

| # | Steps | Expected |
|---|---|---|
| B1 | Favorite's page open in a background tab of the front window | That tab is selected; felt time ≲ 150 ms; log shows the ms |
| B2 | Page open in a second window behind the first | That window comes to the front with the tab selected |
| B3 | Page open in a **minimised** window | The window is restored and focused, no new tab (fixed in `74fb21a`: it timed out during the restore animation) |
| B4 | Page open in a window on **another macOS Space** (desktop) | Note what happens (switches Space, or opens new): record it |
| B5 | Browser **not running** | Opens normally (launches the browser as before). The log has no tab lookup |
| B6 | Page not open anywhere | New tab, log "No open tab matched" |
| B7 | ~100 tabs over several windows | Still feels instant; note the ms |
| B8 | Chrome/Brave: page open **only in an incognito window** | Not focused; a new (normal) tab opens |
| B9 | Safari: with Settings (⌘,) or another non-browser window open | Still focuses the tab; if the log shows `failed`, record the error |
| B10 | Brave/Chrome: page open in an installed web app (PWA) window | Note whether it's focused |

## C. Matching

Use a favorite and change the open tab's URL.

| # | Favorite | Open tab | Expected |
|---|---|---|---|
| C1 | `https://github.com` | `https://github.com/anything` | Focused |
| C2 | `https://example.com/docs` | `https://example.com/docs2` | New tab |
| C3 | `https://youtube.com/watch?v=abc` | `…watch?v=abc&t=30` / `…watch?v=xyz` | Focused / new tab |
| C4 | `https://example.com/` | `https://www.example.com/` | New tab (`www.` is not equal) |
| C5 | `http://…` | `https://…` same page | New tab |
| C6 | Favorite with **Match Exact URL** on, tab one level deeper | | New tab; with the tab on the exact page: focused |
| C7 | `https://mail.google.com/mail/u/0/` | `…/mail/u/0/#inbox` | Focused (fragment ignored) |

## D. Behaviour

| # | Steps | Expected |
|---|---|---|
| D1 | Click a favorite (page open) | Focused |
| D2 | ⌥-click the same favorite | New tab |
| D3 | Click a pinned-list link (page open) | New tab (list default) |
| D4 | ⌥-click the list link | Focused |
| D5 | ⌘-click a list link | Still toggles multi-selection; nothing opens |
| D6 | Double-click a favorite quickly | One focus, never two tabs |
| D7 | Open All Links, a scheduled link firing, a scheduled-row click, Open in ▸, a note | Always a new tab |
| D8 | Profile with **Switch to open tabs** off | Favorites and ⌥-clicks always open new |

## E. Browser profiles (Chrome `Default` / `Profile 1`)

| # | Steps | Expected |
|---|---|---|
| E1 | Two SidebArc profiles routed to Chrome `Default` and `Profile 1` | Settings › Profiles shows **Switch to open tabs off** for both, with the orange warning |
| E2 | Click a favorite whose page is open in the other Chrome profile | New tab in the right Chrome profile (as before Phase 2) |
| E3 | Turn the switch on for one profile, repeat E2 | The tab in the **other** Chrome profile is focused: the accepted risk |
| E4 | Only one SidebArc profile routes to Chrome (or all to the same browser profile) | Switch on by default, no warning |

## F. Browsers without a locator

| # | Steps | Expected |
|---|---|---|
| F1 | Profile on Firefox, click a favorite whose page is open | New tab, no error, no prompt. Settings › Profiles says links always open a new tab; no "Match Exact URL" in the menu |
| F2 | Same with Dia or Arc | Same as F1 |

## Results

| Date | macOS | Browser + version | Build | Failed items / notes |
|---|---|---|---|---|
| 2026-11-14 | 27.2.1 | Chrome 157.0.8103.79, Brave 157.1.99.57, Safari 27.2 | `2b6b243` (ad-hoc) | All of A–F pass. Before `74fb21a`, B3 opened a duplicate (timeout during the restore animation) |
