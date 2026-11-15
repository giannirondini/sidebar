import AppKit
import Testing
@testable import SidebArcCore

/// 3b.1 option B: the sidebar attaches to whichever profile browser (or the global
/// default) is frontmost.
@MainActor
@Suite struct WindowAttachmentBrowsersTests {
    private let chrome = "com.google.Chrome"
    private let safari = "com.apple.Safari"
    private let firefox = "org.mozilla.firefox"
    private let own = AppIdentity.bundleIdentifier

    private final class PermissionDelegate: WindowAttachmentServiceDelegate {
        var lostPermissions = 0
        func attachmentServiceDidLosePermissions(_ service: WindowAttachmentService) { lostPermissions += 1 }
        func attachmentService(_ service: WindowAttachmentService, shouldPositionWindow frame: NSRect, animated: Bool) {}
        func attachmentServiceShouldHideWindow(_ service: WindowAttachmentService) {}
        func attachmentServiceShouldShowWindow(_ service: WindowAttachmentService) {}
        func attachmentServiceSidebarWidth(_ service: WindowAttachmentService) -> CGFloat { 300 }
    }

    @Test func attachmentRequiresPermissionAndStopsWhenRevoked() {
        var trusted = false
        let service = WindowAttachmentService(permissionCheck: { trusted })
        let delegate = PermissionDelegate()
        service.delegate = delegate
        defer { service.disable() }
        #expect(!service.enable(browserBundleIds: [], position: .right))
        service.forceUpdate()
        #expect(delegate.lostPermissions == 0)
        trusted = true
        #expect(service.enable(browserBundleIds: [], position: .right))
        trusted = false
        service.forceUpdate()
        #expect(delegate.lostPermissions == 1)
        service.forceUpdate()
        #expect(delegate.lostPermissions == 1)
    }

    private func profile(_ browser: String?) -> Profile {
        var profile = Profile(name: browser ?? "Default")
        profile.browserBundleId = browser
        return profile
    }

    // MARK: - Which browsers

    @Test func everyProfileBrowserAndTheDefaultOnceEach() {
        let ids = WindowAttachmentService.attachmentBrowserIds(
            profiles: [profile(chrome), profile(safari), profile(nil), profile("COM.GOOGLE.CHROME")],
            globalDefault: chrome,
            installed: { _ in true }
        )
        #expect(ids == [chrome, safari])
    }

    @Test func anUninstalledProfileBrowserFallsBackToTheDefault() {
        let ids = WindowAttachmentService.attachmentBrowserIds(
            profiles: [profile(firefox), profile(safari)],
            globalDefault: chrome,
            installed: { $0 != self.firefox }
        )
        #expect(ids == [chrome, safari])
    }

    @Test func noDefaultAndNoProfileBrowserGivesNothing() {
        let ids = WindowAttachmentService.attachmentBrowserIds(profiles: [profile(nil)], globalDefault: nil, installed: { _ in true })
        #expect(ids.isEmpty)
    }

    // MARK: - Activation

    private func decide(_ activated: String?, after previous: String?) -> WindowAttachmentService.ActivationDecision {
        WindowAttachmentService.activationDecision(
            activated: activated, previous: previous, ownBundleId: own,
            browsers: [chrome.lowercased(), safari.lowercased()]
        )
    }

    @Test func aBrowserOfTheSetAttachesWhateverWasBefore() {
        #expect(decide(chrome, after: nil) == .attach)
        #expect(decide(safari, after: chrome) == .attach)      // switching browsers
        #expect(decide("com.apple.safari", after: "com.apple.finder") == .attach)
    }

    @Test func clickingTheSidebarAfterABrowserKeepsItVisible() {
        #expect(decide(own, after: safari) == .keepVisible)
        #expect(decide(own, after: "com.apple.finder") == .hide)
        #expect(decide(own, after: nil) == .hide)
    }

    @Test func otherAppsAndBrowsersOutsideTheSetHide() {
        #expect(decide("com.apple.finder", after: chrome) == .hide)
        #expect(decide(firefox, after: chrome) == .hide)
        #expect(decide(nil, after: chrome) == .hide)
    }

    @Test func positionUpdatesKeepSidebarVisibleWhenOwnAppIsFrontmost() {
        let ownPid: pid_t = 100
        #expect(WindowAttachmentService.positionUpdateDecision(frontmostPid: ownPid, ownPid: ownPid, hasBrowserWindow: false) == .keepVisible)
        #expect(WindowAttachmentService.positionUpdateDecision(frontmostPid: ownPid, ownPid: ownPid, hasBrowserWindow: true) == .keepVisible)
        #expect(WindowAttachmentService.positionUpdateDecision(frontmostPid: 200, ownPid: ownPid, hasBrowserWindow: false) == .hide)
        #expect(WindowAttachmentService.positionUpdateDecision(frontmostPid: nil, ownPid: ownPid, hasBrowserWindow: false) == .hide)
        #expect(WindowAttachmentService.positionUpdateDecision(frontmostPid: 200, ownPid: ownPid, hasBrowserWindow: true) == .update)
    }

    // MARK: - Short-lived instances (a link opened in a browser profile)

    @Test func aLaunchingSecondInstanceIsIgnored() {
        // Log 2026-11-15: pid 85986 (launched false) activated before the running 85858.
        #expect(WindowAttachmentService.isTransientInstance(pid: 85986, finishedLaunching: false, sameBrowserPids: [85858, 85986]))
    }

    @Test func aBrowserLaunchingAloneOrAlreadyRunningIsNot() {
        #expect(!WindowAttachmentService.isTransientInstance(pid: 85986, finishedLaunching: false, sameBrowserPids: [85986]))
        #expect(!WindowAttachmentService.isTransientInstance(pid: 85858, finishedLaunching: true, sameBrowserPids: [85858, 85986]))
        #expect(!WindowAttachmentService.isTransientInstance(pid: 85858, finishedLaunching: true, sameBrowserPids: [85858]))
    }
}
