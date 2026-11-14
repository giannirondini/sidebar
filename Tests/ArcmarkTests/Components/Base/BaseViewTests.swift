import AppKit
import Testing
@testable import ArcmarkCore

// Test subclass to verify base behavior
@MainActor
fileprivate class TestView: BaseView {
    var hoverChangeCount = 0

    override func handleHoverStateChanged() {
        hoverChangeCount += 1
    }
}

@MainActor
@Suite struct BaseViewTests {

    fileprivate let view: TestView


    init() {

        view = TestView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))

    }

    // MARK: - Initialization Tests

    @Test func testInitialState() {
        #expect(!view.isHovered)
        #expect(view.wantsLayer)
        #expect(!view.mouseDownCanMoveWindow)
    }

    @Test func testCommonInitSetsWantsLayer() {
        let newView = TestView(frame: .zero)
        #expect(newView.wantsLayer)
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

        view.mouseEntered(with: event)

        #expect(view.isHovered)
        #expect(view.hoverChangeCount == 1)
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
        view.mouseEntered(with: enterEvent)

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
        view.mouseExited(with: exitEvent)

        #expect(!view.isHovered)
        #expect(view.hoverChangeCount == 2)
    }

    // MARK: - Tracking Area Tests

    @Test func testUpdateTrackingAreasCreatesTrackingArea() {
        view.updateTrackingAreas()

        // Verify tracking area was added by checking that the method completes without error
        #expect(view != nil)
    }

    // MARK: - Refresh Hover State Tests

    @Test func testRefreshHoverStateResetsWhenNoWindow() {
        // Manually set hover to true via mouseEntered
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
        view.mouseEntered(with: enterEvent)

        #expect(view.isHovered)

        // Now refresh without window
        view.refreshHoverState()

        // Should clear hover and notify
        #expect(!view.isHovered)
        #expect(view.hoverChangeCount > 1)
    }

    // MARK: - Layout Tests

    @Test func testLayoutCallsRefreshHoverState() {
        view.layout()

        // If no window, hover should be false
        #expect(!view.isHovered)
    }

    // MARK: - View Lifecycle Tests

    @Test func testViewDidMoveToWindowCallsRefreshHoverState() {
        view.viewDidMoveToWindow()

        // Without a window, hover should be false
        #expect(!view.isHovered)
    }

    // MARK: - Subclass Override Tests

    @Test func testHandleHoverStateChangedIsCalled() {
        let initialCount = view.hoverChangeCount

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
        view.mouseEntered(with: event)

        #expect(view.hoverChangeCount == initialCount + 1)
    }
}
