import Testing
@testable import SidebArcCore

/// "Attachment enabled" is not "attached": the window is locked only while it is
/// beside a browser window (bug: opened with no browser running, the sidebar
/// could not be moved until attachment was turned off).
@Suite struct WindowAttachmentModeTests {
    private typealias Transition = WindowAttachmentService.WindowModeTransition

    private func transition(
        _ current: WindowAttachmentService.WindowMode,
        _ event: WindowAttachmentService.WindowModeEvent,
        enabled: Bool = true
    ) -> Transition {
        WindowAttachmentService.windowModeTransition(from: current, event: event, attachmentEnabled: enabled)
    }

    @Test func firstPlacementAttachesAndCapturesTheStandaloneFrame() {
        #expect(transition(.standalone, .placed) == Transition(mode: .attached, captureManualFrame: true, restoreManualFrame: false))
    }

    @Test func aRePlacementWhileAttachedNeverOverwritesTheStandaloneFrame() {
        #expect(transition(.attached, .placed) == Transition(mode: .attached, captureManualFrame: false, restoreManualFrame: false))
    }

    @Test func hidingWhileAttachedGoesBackToTheStandaloneFrame() {
        #expect(transition(.attached, .hidden) == Transition(mode: .standalone, captureManualFrame: false, restoreManualFrame: true))
    }

    @Test func hidingWhileStandaloneChangesNothing() {
        #expect(transition(.standalone, .hidden) == Transition(mode: .standalone, captureManualFrame: false, restoreManualFrame: false))
    }

    @Test func disablingWhileAttachedRestoresTheStandaloneFrame() {
        #expect(transition(.attached, .disabled, enabled: false) == Transition(mode: .standalone, captureManualFrame: false, restoreManualFrame: true))
    }

    /// The window was moved after attachment was enabled, never placed: turning
    /// attachment off (or losing Accessibility) must not snap it back.
    @Test func disablingWhileStandaloneDoesNotMoveTheWindow() {
        #expect(transition(.standalone, .disabled, enabled: false) == Transition(mode: .standalone, captureManualFrame: false, restoreManualFrame: false))
    }

    @Test func aLatePlacementAfterAttachmentWasTurnedOffIsIgnored() {
        #expect(transition(.standalone, .placed, enabled: false) == Transition(mode: .standalone, captureManualFrame: false, restoreManualFrame: false))
    }

    /// Launch with no browser running, activate one later, switch away and back.
    @Test func launchAloneThenBrowserThenAwayAndBack() {
        var mode = WindowAttachmentService.WindowMode.standalone
        var captures = 0
        var restores = 0
        for event: WindowAttachmentService.WindowModeEvent in [.placed, .placed, .hidden, .placed, .disabled] {
            let next = transition(mode, event)
            captures += next.captureManualFrame ? 1 : 0
            restores += next.restoreManualFrame ? 1 : 0
            mode = next.mode
        }
        #expect(mode == .standalone)
        #expect(captures == 2)
        #expect(restores == 2)
    }
}
