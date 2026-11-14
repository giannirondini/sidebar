import AppKit
import os

/// Opens a clicked favorite or list link, focusing an already open matching tab
/// when `TabFocus.decide` says to look for one (plan-v2 Phase 2). Anything that
/// goes wrong (no match, no permission, timeout, browser not running) opens the
/// link normally, exactly as before Phase 2.
@MainActor
final class TabFocusService {
    static let shared = TabFocusService()

    /// Per Apple Event. On timeout the link opens normally.
    var timeout: TimeInterval = 0.3

    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "tabs")
    /// Links whose lookup is running; a second click meanwhile is ignored, so a
    /// double-click can't open two tabs.
    private var inFlight: Set<UUID> = []

    func open(link: Link, in profile: Profile, allProfiles: [Profile], source: LinkClickSource, invert: Bool) {
        guard let url = URL(string: link.url) else { return }
        let target = BrowserManager.resolveTarget(link: link, profile: profile)
        let profileTargets = allProfiles.map { BrowserManager.resolveTarget(link: nil, profile: $0) }
        let decision = TabFocus.decide(target: target, profile: profile, profileTargets: profileTargets, source: source, invert: invert)

        // Only a running browser is asked: an Apple Event would launch a closed one.
        guard case .lookForTab(let bundleId) = decision else {
            logger.notice("Opening new in \(target.bundleId ?? "the default browser", privacy: .public): \(Self.reason(source: source, invert: invert, target: target, profile: profile, profileTargets: profileTargets), privacy: .public)")
            BrowserManager.open(url: url, target: target)
            return
        }
        guard let app = Self.runningApplication(bundleId: bundleId), let locator = TabLocators.locator(for: bundleId) else {
            logger.notice("Opening new: \(bundleId, privacy: .public) isn't running")
            BrowserManager.open(url: url, target: target)
            return
        }
        guard inFlight.insert(link.id).inserted else { return }

        let pid = app.processIdentifier
        let linkURL = link.url
        let exact = link.exactTabMatch ?? false
        let timeout = self.timeout
        let start = Date()
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                TabFocus.locateAndFocus(url: linkURL, exact: exact, pid: pid, locator: locator, timeout: timeout)
            }.value
            self?.finish(outcome, linkId: link.id, url: url, target: target, app: app, bundleId: bundleId, start: start)
        }
    }

    private func finish(
        _ outcome: TabFocus.Outcome,
        linkId: UUID,
        url: URL,
        target: BrowserTarget,
        app: NSRunningApplication,
        bundleId: String,
        start: Date
    ) {
        inFlight.remove(linkId)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        switch outcome {
        case .focused(let tab):
            logger.notice("Focused tab \(tab.tabIndex) of window \(tab.windowIndex) in \(bundleId, privacy: .public) (\(ms) ms)")
            Self.activate(app)
        case .noMatch:
            logger.notice("No open tab matched in \(bundleId, privacy: .public) (\(ms) ms); opening")
            BrowserManager.open(url: url, target: target)
        case .notPermitted(let permission):
            logger.notice("No Automation permission for \(bundleId, privacy: .public) (\(String(describing: permission), privacy: .public)); opening")
            if permission == .denied || permission == .notDetermined {
                // Settings › Permissions shows a hint for this browser.
                UserDefaults.standard.set(bundleId, forKey: UserDefaultsKeys.tabFocusPermissionHintBundleId)
            }
            BrowserManager.open(url: url, target: target)
        case .failed(let error):
            logger.error("Looking for an open tab in \(bundleId, privacy: .public) failed: \(String(describing: error), privacy: .public) (\(ms) ms); opening")
            BrowserManager.open(url: url, target: target)
        }
    }

    /// Why a click opens a new tab without looking (log only).
    private static func reason(source: LinkClickSource, invert: Bool, target: BrowserTarget, profile: Profile, profileTargets: [BrowserTarget]) -> String {
        guard let bundleId = target.bundleId, TabLocators.isSupported(bundleId: bundleId) else {
            return "this browser can't report its tabs"
        }
        guard TabFocus.prefersFocus(source: source, invert: invert) else {
            return source == .list ? "list link (⌥-click to switch to its tab)" : "⌥-click"
        }
        let ambiguous = TabFocus.isAmbiguous(target: target, profileTargets: profileTargets)
        return ambiguous && profile.focusesOpenTabs == nil
            ? "Switch to open tabs is off (several browser profiles)"
            : "Switch to open tabs is off for this profile"
    }

    static func runningApplication(bundleId: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            !$0.isTerminated && $0.bundleIdentifier?.caseInsensitiveCompare(bundleId) == .orderedSame
        }
    }

    /// Brings the browser forward. SidebArc is active after the click, so on
    /// macOS 14+ it hands activation over (cooperative activation).
    private static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
