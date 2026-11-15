import AppKit
import Testing
@testable import SidebArcCore

/// Launch placement: a window on any display stays; one off every display is centred
/// on the primary. Layout from a real setup: built-in primary, a Dell above it.
@Suite struct WindowPlacementTests {
    private let builtIn = NSRect(x: 0, y: 0, width: 2294, height: 1465)       // visible frame, below the menu bar
    private let dell = NSRect(x: -770, y: 1490, width: 3840, height: 2135)

    @Test func aWindowOnTheSecondaryDisplayStaysThere() {
        let onDell = NSRect(x: 100, y: 2500, width: 340, height: 900)
        #expect(WindowPlacement.originToShow(frame: onDell, visibleFrames: [builtIn, dell]) == nil)
    }

    @Test func aWindowOffEveryDisplayIsCentredOnThePrimary() {
        let lost = NSRect(x: 9000, y: 9000, width: 340, height: 900)
        let origin = WindowPlacement.originToShow(frame: lost, visibleFrames: [builtIn, dell])
        #expect(origin == NSPoint(x: builtIn.midX - 170, y: builtIn.midY - 450))
    }

    @Test func noDisplaysLeavesTheWindowAlone() {
        #expect(WindowPlacement.originToShow(frame: .zero, visibleFrames: []) == nil)
    }
}
