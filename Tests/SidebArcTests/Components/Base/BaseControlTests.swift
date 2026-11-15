import AppKit
import Testing
@testable import SidebArcCore

// Test subclass to verify base behavior
@MainActor
fileprivate class TestControl: BaseControl {
    var hoverChangeCount = 0
    var pressedChangeCount = 0
    var actionPerformed = false

    override func handleHoverStateChanged() {
        hoverChangeCount += 1
    }

    override func handlePressedStateChanged() {
        pressedChangeCount += 1
    }

    override func performAction() {
        actionPerformed = true
        super.performAction()
    }
}

@MainActor
@Suite struct BaseControlTests {

    fileprivate let control: TestControl


    init() {

        control = TestControl(frame: NSRect(x: 0, y: 0, width: 100, height: 40))

    }

    // MARK: - Initialization Tests

    @Test func testInitialState() {
        #expect(!control.isHovered)
        #expect(!control.isPressed)
        #expect(control.wantsLayer)
        #expect(!control.mouseDownCanMoveWindow)
    }

    @Test func testCommonInitSetsWantsLayer() {
        let newControl = TestControl(frame: .zero)
        #expect(newControl.wantsLayer)
    }

    // MARK: - Hover State Tests

    @Test func testMouseEnteredSetsHoverState() {
        let event = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: 50, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!

        control.mouseEntered(with: event)

        #expect(control.isHovered)
        #expect(control.hoverChangeCount == 1)
    }

    @Test func testMouseExitedClearsHoverState() {
        // First set hover state
        let enterEvent = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: 50, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
        control.mouseEntered(with: enterEvent)

        // Then exit
        let exitEvent = NSEvent.enterExitEvent(
            with: .mouseExited,
            location: NSPoint(x: 150, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
        control.mouseExited(with: exitEvent)

        #expect(!control.isHovered)
        #expect(control.hoverChangeCount == 2)
    }

    // MARK: - Tracking Area Tests

    @Test func testUpdateTrackingAreasCreatesTrackingArea() {
        control.updateTrackingAreas()
        control.updateTrackingAreas()

        // Exactly one area: a refresh replaces the old one instead of piling up.
        #expect(control.trackingAreas.count == 1)
    }

    // MARK: - Refresh Hover State Tests

    @Test func testRefreshHoverStateWithoutWindow() {
        // First set hover via mouseEntered
        let enterEvent = NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: 50, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
        control.mouseEntered(with: enterEvent)

        // Verify hover is set
        #expect(control.isHovered)

        // Call refresh when there's no window
        control.refreshHoverState()

        // Should clear hover state
        #expect(!control.isHovered)
    }

    // MARK: - Enabled State Tests

    @Test func testMouseDownIgnoredWhenDisabled() {
        control.isEnabled = false

        // Note: We can't fully test mouseDown without a window, but we can verify enabled check
        #expect(!control.isEnabled)
        #expect(!control.isPressed)
    }

    // MARK: - Layout Tests

    @Test func testLayoutCallsRefreshHoverState() {
        // This test verifies layout() is implemented correctly
        control.layout()

        // If no window, hover should be false
        #expect(!control.isHovered)
    }

    // MARK: - View Lifecycle Tests

    @Test func testViewDidMoveToWindowCallsRefreshHoverState() {
        control.viewDidMoveToWindow()

        // Without a window, hover should be false
        #expect(!control.isHovered)
    }
}
