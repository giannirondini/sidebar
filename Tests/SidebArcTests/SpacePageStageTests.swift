import AppKit
import Testing
@testable import SidebArcCore

/// The space transition moves pages on `SpacePageStage`, not the live page, because
/// AppKit resets the transform of its own views' layers on the next display pass
/// (the old list then flashed at x = 0 when a switch landed). These tests run in a
/// real, invisible window on a display so AppKit's display passes actually happen.
@MainActor
@Suite struct SpacePageStageTests {
    private let window: NSWindow
    private let stage = SpacePageStage()

    init() {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let root = NSView()
        root.wantsLayer = true
        window.contentView = root
        // On a display (or Core Animation never runs the animations), but invisible.
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderFrontRegardless()
        stage.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stage)
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stage.topAnchor.constraint(equalTo: root.topAnchor),
            stage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.layoutSubtreeIfNeeded()
    }

    private func image() -> NSImage {
        NSImage(size: NSSize(width: 320, height: 500), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
    }

    private func runLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    @Test func pageOffsetsSurviveDisplayPassesAndResizes() {
        stage.begin(outgoing: image())
        stage.setIncoming(image(), baseX: 320)
        stage.setOffset(-200)
        runLoop()
        #expect(stage.outgoing.transform.m41 == -200)
        #expect(stage.incoming.transform.m41 == -200)

        window.setContentSize(NSSize(width: 330, height: 500))
        window.contentView?.layoutSubtreeIfNeeded()
        runLoop()
        #expect(stage.outgoing.transform.m41 == -200)
        #expect(stage.incoming.transform.m41 == -200)
        window.orderOut(nil)
    }

    // Core Animation doesn't run animations to completion under `swift test`, so the
    // fade's completion is tested through what it calls (`hideNow`) and its guard.

    @Test func stageNeverTakesClicksAndHidesCleanly() {
        stage.begin(outgoing: image())
        #expect(!stage.isHidden)
        #expect(stage.hitTest(NSPoint(x: 10, y: 10)) == nil)
        stage.hideNow()
        #expect(stage.isHidden)
        #expect(stage.outgoing.contents == nil)
        #expect(stage.incoming.contents == nil)
        #expect(stage.layer?.opacity == 1)
        window.orderOut(nil)
    }

    @Test func aNewTransitionTakesOverFromAPendingFade() {
        stage.begin(outgoing: image())
        let landing = stage.generation
        stage.fadeOut(duration: 0.05)
        #expect(stage.layer?.opacity == 0)
        stage.begin(outgoing: image())   // the next switch takes the stage over
        // The pending fade's completion checks this and leaves the stage alone.
        #expect(stage.generation == landing + 1)
        #expect(stage.layer?.opacity == 1)
        #expect(stage.layer?.animation(forKey: "fadeOut") == nil)
        #expect(!stage.isHidden)
        window.orderOut(nil)
    }
}
