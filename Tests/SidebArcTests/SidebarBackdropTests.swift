import AppKit
import Testing
@testable import SidebArcCore

/// The window root: a behind-window blur that stays active when
/// the sidebar isn't key, with the main view filling it.
@MainActor
@Suite struct SidebarBackdropTests {
    init() {
        _ = NSApplication.shared
    }

    @Test func blurStaysActiveBehindTheWindowWithTheContentFillingIt() throws {
        let content = NSViewController()
        content.view = NSView()
        let backdrop = SidebarBackdropViewController(content: content)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 500),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.contentViewController = backdrop
        window.setContentSize(NSSize(width: 300, height: 500))
        backdrop.view.layoutSubtreeIfNeeded()

        let blur = try #require(backdrop.view as? NSVisualEffectView)
        #expect(blur.blendingMode == .behindWindow)
        #expect(blur.state == .active)
        #expect(content.view.superview === blur)
        #expect(content.view.frame == blur.bounds)
        #expect(backdrop.children.contains(content))
    }
}
