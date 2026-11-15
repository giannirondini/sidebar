import AppKit
import Testing
@testable import SidebArcCore

/// Accessibility → AppKit window frames. Geometry from a real setup: built-in display
/// (primary) 2294 × 1490 pt at (0, 0), a Dell 3840 × 2160 pt above it at (-770, 1490).
/// Flipping with the external display's height put the sidebar 670 pt too high.
@Suite struct WindowAttachmentGeometryTests {
    private let primaryHeight: CGFloat = 1490
    private let external = NSRect(x: -770, y: 1490, width: 3840, height: 2160)

    @Test func windowOnThePrimaryDisplay() {
        // 100 pt below the top of the primary display.
        let frame = WindowAttachmentService.cocoaFrame(
            axOrigin: CGPoint(x: 200, y: 100), size: CGSize(width: 1000, height: 800), primaryScreenHeight: primaryHeight)
        #expect(frame == NSRect(x: 200, y: 590, width: 1000, height: 800))
        #expect(frame.maxY == primaryHeight - 100)
    }

    @Test func windowOnAnExternalDisplayAboveThePrimary() {
        // Accessibility y is relative to the primary's top, so the external display's
        // top edge is at y = -2160. The window starts 625 pt below that edge.
        let axTopOfExternal = primaryHeight - external.maxY
        let frame = WindowAttachmentService.cocoaFrame(
            axOrigin: CGPoint(x: 0, y: axTopOfExternal + 625), size: CGSize(width: 1600, height: 980), primaryScreenHeight: primaryHeight)

        #expect(external.contains(frame))
        #expect(frame.maxY == external.maxY - 625)
        #expect(frame.height == 980)
    }
}
