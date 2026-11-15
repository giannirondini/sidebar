import AppKit
import Testing
@testable import SidebArcCore

/// Menu dispatch for `ClosureMenuItem` and the `BrowserMenus` builders.
/// Regression: a handler method named `perform(_:)` resolved to NSObject's
/// `performSelector:`, so every closure item silently did nothing in the app.
@MainActor
@Suite struct ClosureMenuItemTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func selectorIsNotPerformSelector() {
        let item = ClosureMenuItem(title: "X") {}
        #expect(item.action.map(NSStringFromSelector) == "runClosureMenuAction:")
    }

    @Test func performingTheItemRunsTheClosure() {
        var fired = 0
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "X") { fired += 1 })
        menu.update()
        #expect(menu.items[safe: 0]?.isEnabled == true)
        menu.performActionForItem(at: 0)
        #expect(fired == 1)
    }

    @Test func profileMenuAssignsAndCreates() throws {
        let personal = Profile(name: "Personal")
        let work = Profile(name: "Work")
        var assigned: UUID?
        var created = false
        let item = BrowserMenus.profileItem(
            profiles: [personal, work],
            currentProfileId: personal.id,
            assign: { assigned = $0 },
            newProfile: { created = true }
        )
        let submenu = try #require(item.submenu)
        #expect(submenu.items.map(\.title) == ["Personal", "Work", "", "New Profile…"])
        #expect(submenu.items[safe: 0]?.state == .on)

        submenu.performActionForItem(at: 1)
        #expect(assigned == work.id)
        submenu.performActionForItem(at: 3)
        #expect(created)
    }

    @Test func alwaysOpenInClearsAndSetsOverride() throws {
        let browsers = [BrowserInfo(bundleId: "com.apple.Safari", name: "Safari", icon: nil)]
        var received: [String?] = []
        let item = BrowserMenus.alwaysOpenInItem(browsers: browsers, current: "com.apple.Safari", profileBrowserName: "Firefox") {
            received.append($0)
        }
        let submenu = try #require(item.submenu)
        #expect(submenu.items[safe: 2]?.state == .on)
        submenu.performActionForItem(at: 0)
        submenu.performActionForItem(at: 2)
        #expect(received == [nil, "com.apple.Safari"])
    }

    @Test func exactMatchItemTogglesTheCurrentValue() {
        var received: [Bool] = []
        let menu = NSMenu()
        menu.addItem(BrowserMenus.exactMatchItem(isOn: false) { received.append($0) })
        menu.addItem(BrowserMenus.exactMatchItem(isOn: true) { received.append($0) })
        menu.update()
        let states = menu.items.map { $0.state }
        let enabled = menu.items.map { $0.isEnabled }
        #expect(states == [.off, .on])
        #expect(enabled == [true, true])
        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 1)
        #expect(received == [true, false])
    }
}
