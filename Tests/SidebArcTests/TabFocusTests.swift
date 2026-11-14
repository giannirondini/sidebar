import AppKit
import Foundation
import Testing
@testable import SidebArcCore

/// `TabFocus` decisions and `locateAndFocus` against a fake locator. The real
/// locators talk to browsers, so they are covered by the manual checklist
/// (`docs/TAB_FOCUS_CHECKLIST.md`) and the opt-in probe at the end.
@Suite struct TabFocusTests {
    private let chrome = "com.google.Chrome"

    private func target(_ bundleId: String?, _ dir: String? = nil) -> BrowserTarget {
        BrowserTarget(bundleId: bundleId, profileDir: dir)
    }

    // MARK: - Default and modifier

    @Test func favoritesFocusAndListLinksOpenNewUnlessInverted() {
        #expect(TabFocus.prefersFocus(source: .favorite, invert: false))
        #expect(!TabFocus.prefersFocus(source: .favorite, invert: true))
        #expect(!TabFocus.prefersFocus(source: .list, invert: false))
        #expect(TabFocus.prefersFocus(source: .list, invert: true))
    }

    // MARK: - Browser-profile ambiguity

    @Test func twoBrowserProfilesOfTheSameBrowserAreAmbiguous() {
        // The user's setup: one SidebArc profile per Chrome profile.
        let work = target(chrome, "Profile 1")
        let all = [target(chrome, "Default"), work]
        #expect(TabFocus.isAmbiguous(target: work, profileTargets: all))
    }

    @Test func oneBrowserProfileIsNotAmbiguous() {
        let only = target(chrome, "Default")
        #expect(!TabFocus.isAmbiguous(target: only, profileTargets: [only, only]))
        #expect(!TabFocus.isAmbiguous(target: target(chrome), profileTargets: [target(chrome)]))
    }

    @Test func withAndWithoutBrowserProfileIsAmbiguous() {
        #expect(TabFocus.isAmbiguous(target: target(chrome), profileTargets: [target(chrome, "Default")]))
        // An empty directory means no browser profile.
        #expect(!TabFocus.isAmbiguous(target: target(chrome, ""), profileTargets: [target(chrome)]))
    }

    @Test func otherBrowsersDoNotMakeItAmbiguous() {
        let safari = target("com.apple.Safari")
        let all = [target(chrome, "Default"), target(chrome, "Profile 1"), safari]
        #expect(!TabFocus.isAmbiguous(target: safari, profileTargets: all))
    }

    @Test func bundleIdsCompareCaseInsensitively() {
        let all = [target("com.google.chrome", "Default")]
        #expect(TabFocus.isAmbiguous(target: target(chrome, "Profile 1"), profileTargets: all))
    }

    @Test func noBrowserIsNeverAmbiguous() {
        #expect(!TabFocus.isAmbiguous(target: target(nil), profileTargets: [target(nil, "x")]))
    }

    // MARK: - decide

    private func decide(
        _ target: BrowserTarget,
        profile: Profile = Profile(name: "P"),
        others: [BrowserTarget] = [],
        source: LinkClickSource = .favorite,
        invert: Bool = false
    ) -> TabFocus.Decision {
        TabFocus.decide(target: target, profile: profile, profileTargets: [target] + others, source: source, invert: invert)
    }

    @Test func favoriteInSupportedBrowserLooksForTab() {
        #expect(decide(target(chrome)) == .lookForTab(bundleId: chrome))
        #expect(decide(target("com.apple.Safari")) == .lookForTab(bundleId: "com.apple.Safari"))
        #expect(decide(target("com.brave.Browser")) == .lookForTab(bundleId: "com.brave.Browser"))
    }

    @Test func listLinkOpensNewUnlessInverted() {
        #expect(decide(target(chrome), source: .list) == .openNew)
        #expect(decide(target(chrome), source: .list, invert: true) == .lookForTab(bundleId: chrome))
        #expect(decide(target(chrome), invert: true) == .openNew)
    }

    @Test func unsupportedOrUnknownBrowserOpensNew() {
        #expect(decide(target("org.mozilla.firefox")) == .openNew)
        #expect(decide(target("company.thebrowser.dia")) == .openNew)
        #expect(decide(target(nil)) == .openNew)
    }

    @Test func ambiguousBrowserIsOffUntilTheProfileOptsIn() {
        let mine = target(chrome, "Default")
        let others = [target(chrome, "Profile 1")]
        #expect(decide(mine, others: others) == .openNew)

        let optedIn = Profile(name: "P", focusesOpenTabs: true)
        #expect(decide(mine, profile: optedIn, others: others) == .lookForTab(bundleId: chrome))
    }

    @Test func profileSwitchOffAlwaysOpensNew() {
        let off = Profile(name: "P", focusesOpenTabs: false)
        #expect(decide(target(chrome), profile: off) == .openNew)
        #expect(decide(target(chrome), profile: off, source: .list, invert: true) == .openNew)
    }

    @Test func locatorRegistry() {
        #expect(TabLocators.isSupported(bundleId: "com.google.Chrome"))
        #expect(TabLocators.isSupported(bundleId: "com.brave.Browser"))
        #expect(TabLocators.isSupported(bundleId: "com.apple.Safari"))
        #expect(!TabLocators.isSupported(bundleId: "org.mozilla.firefox"))
        #expect(!TabLocators.isSupported(bundleId: "company.thebrowser.dia"))
        #expect(!TabLocators.isSupported(bundleId: "company.thebrowser.Browser"))
    }

    // MARK: - locateAndFocus

    final class FakeLocator: TabLocator, @unchecked Sendable {
        var windows: [[String]] = []
        var listError: TabLocatorError?
        var activateResult = true
        var listed = 0
        var activated: [TabRef] = []

        func tabURLs(pid: pid_t, timeout: TimeInterval) throws -> [[String]] {
            listed += 1
            if let listError { throw listError }
            return windows
        }

        func activate(_ tab: TabRef, pid: pid_t, timeout: TimeInterval) throws -> Bool {
            activated.append(tab)
            return activateResult
        }
    }

    private func locate(_ url: String, exact: Bool = false, _ locator: FakeLocator, permission: AutomationPermission = .granted) -> TabFocus.Outcome {
        TabFocus.locateAndFocus(url: url, exact: exact, pid: 1, locator: locator, timeout: 0.3, permission: { _ in permission })
    }

    @Test func focusesTheClosestTabWithOneBasedIndices() {
        let locator = FakeLocator()
        locator.windows = [
            ["https://other.com/"],
            ["https://example.com/docs/a/b", "https://example.com/docs/a", "https://example.com/docs/b"],
        ]
        let expected = TabRef(windowIndex: 2, tabIndex: 2, url: "https://example.com/docs/a")
        #expect(locate("https://example.com/docs", locator) == .focused(expected))
        #expect(locator.activated == [expected])
    }

    @Test func emptyIncognitoWindowsKeepIndicesAligned() {
        let locator = FakeLocator()
        locator.windows = [[], ["https://example.com/"]]
        #expect(locate("https://example.com/", locator) == .focused(TabRef(windowIndex: 2, tabIndex: 1, url: "https://example.com/")))
    }

    @Test func noMatchDoesNotActivate() {
        let locator = FakeLocator()
        locator.windows = [["https://www.example.com/"]]
        #expect(locate("https://example.com/", locator) == .noMatch)
        #expect(locator.activated.isEmpty)
    }

    @Test func exactModeSkipsDeeperTabs() {
        let locator = FakeLocator()
        locator.windows = [["https://example.com/docs/a"]]
        #expect(locate("https://example.com/docs", exact: true, locator) == .noMatch)
    }

    @Test func tabThatChangedBeforeActivationIsNoMatch() {
        let locator = FakeLocator()
        locator.windows = [["https://example.com/"]]
        locator.activateResult = false
        #expect(locate("https://example.com/", locator) == .noMatch)
    }

    @Test func withoutPermissionNoEventIsSent() {
        for permission in [AutomationPermission.denied, .notDetermined, .notRunning, .other(-50)] {
            let locator = FakeLocator()
            #expect(locate("https://example.com/", locator, permission: permission) == .notPermitted(permission))
            #expect(locator.listed == 0)
        }
    }

    @Test func listingFailureIsReported() {
        let locator = FakeLocator()
        locator.listError = .appleEvent(-1712)
        #expect(locate("https://example.com/", locator) == .failed(.appleEvent(-1712)))
        #expect(locator.activated.isEmpty)
    }

    @Test func permissionStatusMapping() {
        #expect(AutomationPermission(status: noErr) == .granted)
        #expect(AutomationPermission(status: OSStatus(errAEEventNotPermitted)) == .denied)
        #expect(AutomationPermission(status: OSStatus(errAEEventWouldRequireUserConsent)) == .notDetermined)
        #expect(AutomationPermission(status: OSStatus(procNotFound)) == .notRunning)
        #expect(AutomationPermission(status: -1) == .other(-1))
    }

    // MARK: - Apple Event building

    @Test func specifiersAreObjectSpecifiers() throws {
        let spec = AE.property("URL ", of: AE.every("CrTb", of: AE.every(AE.window)))
        #expect(spec.descriptorType == AE.code("obj "))
        let record = try #require(spec.coerce(toDescriptorType: AE.code("reco")))
        #expect(record.forKeyword(AE.code("want"))?.typeCodeValue == AE.code("prop"))
        #expect(record.forKeyword(AE.code("seld"))?.typeCodeValue == AE.code("URL "))
        let tabs = try #require(record.forKeyword(AE.code("from"))?.coerce(toDescriptorType: AE.code("reco")))
        #expect(tabs.forKeyword(AE.code("want"))?.typeCodeValue == AE.code("CrTb"))
        #expect(tabs.forKeyword(AE.code("form"))?.enumCodeValue == AE.code("indx"))

        let item = try #require(AE.item(3, of: "bTab", in: AE.item(2, of: AE.window)).coerce(toDescriptorType: AE.code("reco")))
        #expect(item.forKeyword(AE.code("seld"))?.int32Value == 3)
    }

    /// Activation addresses the window by id, so un-minimising or raising it
    /// (which renumbers windows) can't redirect later events to another window.
    @Test func windowByIdSpecifierKeepsTheReturnedId() throws {
        for id in [NSAppleEventDescriptor(string: "1234"), NSAppleEventDescriptor(int32: 77)] {
            let window = AE.byId(id, of: AE.window)
            let tab = try #require(AE.item(2, of: "CrTb", in: window).coerce(toDescriptorType: AE.code("reco")))
            let container = try #require(tab.forKeyword(AE.code("from"))?.coerce(toDescriptorType: AE.code("reco")))
            #expect(container.forKeyword(AE.code("want"))?.typeCodeValue == AE.code("cwin"))
            #expect(container.forKeyword(AE.code("form"))?.enumCodeValue == AE.code("ID  "))
            #expect(container.forKeyword(AE.code("seld")) == id)
        }
    }

    @Test func parsesNestedURLLists() throws {
        func list(_ items: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let list = NSAppleEventDescriptor.list()
            for (index, item) in items.enumerated() { list.insert(item, at: index + 1) }
            return list
        }
        let reply = list([
            list([NSAppleEventDescriptor(string: "https://a.com/"), NSAppleEventDescriptor(string: "https://b.com/")]),
            list([]),
            list([NSAppleEventDescriptor(typeCode: AE.code("msng"))]),
        ])
        #expect(try AE.nestedStrings(reply) == [["https://a.com/", "https://b.com/"], [], [""]])
        #expect(try AE.nestedStrings(NSAppleEventDescriptor.null()) == [])
        #expect(throws: TabLocatorError.unexpectedReply) { try AE.nestedStrings(NSAppleEventDescriptor(string: "x")) }
        #expect(try AE.strings(list([NSAppleEventDescriptor(string: "normal"), NSAppleEventDescriptor(string: "incognito")])) == ["normal", "incognito"])
    }

    // MARK: - Opt-in live probe

    /// `SIDEBARC_TAB_PROBE=<bundle id>` lists that running browser's tabs with the
    /// real locator and prints counts and timing only (no URLs). Never focuses a
    /// tab and never asks for permission: it needs Automation already granted to
    /// the process running the tests (e.g. Terminal).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEBARC_TAB_PROBE"] != nil))
    func liveProbe() throws {
        let bundleId = try #require(ProcessInfo.processInfo.environment["SIDEBARC_TAB_PROBE"])
        let locator = try #require(TabLocators.locator(for: bundleId), "No locator for \(bundleId)")
        let app = try #require(
            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.caseInsensitiveCompare(bundleId) == .orderedSame },
            "\(bundleId) is not running"
        )
        let permission = AutomationPermission.check(pid: app.processIdentifier, ask: false)
        print("[tab probe] \(bundleId) permission: \(permission)")
        guard permission == .granted else { return }
        let start = Date()
        let windows = try locator.tabURLs(pid: app.processIdentifier, timeout: 2)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("[tab probe] \(bundleId): \(windows.count) windows, \(windows.map(\.count).reduce(0, +)) tabs, \(ms) ms")
    }
}
