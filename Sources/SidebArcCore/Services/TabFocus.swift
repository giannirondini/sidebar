import Foundation

/// Where a link was clicked; sets whether focusing an open tab is the default.
enum LinkClickSource: Equatable, Sendable {
    /// Favorites grid: focuses a matching open tab by default.
    case favorite
    /// Pinned list: opens a new tab by default.
    case list
}

/// The pure part of "focus an open tab instead of opening a duplicate"
/// whether to look, and what to do with what was found.
/// `TabFocusService` runs it against real browsers.
enum TabFocus {
    enum Decision: Equatable {
        case openNew
        /// Look for an open tab in this (running, scriptable) browser first.
        case lookForTab(bundleId: String)
    }

    enum Outcome: Equatable {
        case focused(TabRef)
        case noMatch
        /// Not allowed to send Apple Events (denied, never asked, grant reset).
        case notPermitted(AutomationPermission)
        case failed(TabLocatorError)
    }

    /// Favorites focus by default and list links open new; ⌥-click inverts.
    static func prefersFocus(source: LinkClickSource, invert: Bool) -> Bool {
        (source == .favorite) != invert
    }

    /// AppleScript can't tell which browser profile owns a window. The browser is
    /// ambiguous when SidebArc's profiles open it with more than one browser
    /// profile (a different directory, or one with and one without), so a matching
    /// tab may belong to another browser profile.
    /// `profileTargets` are `resolveTarget(link: nil, profile:)` of every profile.
    static func isAmbiguous(target: BrowserTarget, profileTargets: [BrowserTarget]) -> Bool {
        guard let browser = target.bundleId else { return false }
        func dir(_ target: BrowserTarget) -> String? {
            guard let dir = target.profileDir, !dir.isEmpty else { return nil }
            return dir
        }
        var dirs: Set<String?> = [dir(target)]
        for other in profileTargets {
            guard let otherBrowser = other.bundleId,
                  otherBrowser.caseInsensitiveCompare(browser) == .orderedSame else { continue }
            dirs.insert(dir(other))
        }
        return dirs.count > 1
    }

    /// The profile's switch, or automatic: on unless the browser is ambiguous.
    static func isEnabled(profile: Profile, ambiguous: Bool) -> Bool {
        profile.focusesOpenTabs ?? !ambiguous
    }

    static func decide(
        target: BrowserTarget,
        profile: Profile,
        profileTargets: [BrowserTarget],
        source: LinkClickSource,
        invert: Bool,
        isSupported: (String) -> Bool = TabLocators.isSupported
    ) -> Decision {
        guard prefersFocus(source: source, invert: invert),
              let browser = target.bundleId, isSupported(browser) else { return .openNew }
        let ambiguous = isAmbiguous(target: target, profileTargets: profileTargets)
        guard isEnabled(profile: profile, ambiguous: ambiguous) else { return .openNew }
        return .lookForTab(bundleId: browser)
    }

    /// Lists the tabs, picks the closest match to `url` and focuses it inside the
    /// browser. Blocking (Apple Events), so call it off the main actor; the caller
    /// activates the browser app on `.focused` and opens normally otherwise.
    static func locateAndFocus(
        url: String,
        exact: Bool,
        pid: pid_t,
        locator: TabLocator,
        timeout: TimeInterval,
        permission: (pid_t) -> AutomationPermission = { AutomationPermission.check(pid: $0, ask: false) }
    ) -> Outcome {
        let allowed = permission(pid)
        guard allowed == .granted else { return .notPermitted(allowed) }
        do {
            let windows = try locator.tabURLs(pid: pid, timeout: timeout)
            let tabs = windows.enumerated().flatMap { window, urls in
                urls.enumerated().map { TabRef(windowIndex: window + 1, tabIndex: $0.offset + 1, url: $0.element) }
            }
            guard let index = TabURLMatcher.bestMatch(item: url, exact: exact, candidates: tabs.map(\.url)) else {
                return .noMatch
            }
            let tab = tabs[index]
            return try locator.activate(tab, pid: pid, timeout: timeout) ? .focused(tab) : .noMatch
        } catch let error as TabLocatorError {
            return .failed(error)
        } catch {
            return .failed(.unexpectedReply)
        }
    }
}
