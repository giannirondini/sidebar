import AppKit

/// Edits one space's custom colour in the shared macOS colour panel, with its
/// opacity slider (the sidebar background's opacity).
///
/// The panel sends a change for every step of a drag; they are applied at most every
/// `ThemeConstants.Animation.colorPreviewInterval` (each one is a normal `AppModel`
/// mutation, so it is saved), and the last value is always applied. The space is
/// captured when the panel opens: switching spaces doesn't move the edit.
@MainActor
final class SpaceColorPanel: NSObject {
    static let shared = SpaceColorPanel()

    private var workspaceId: UUID?
    private var apply: ((UUID, SpaceColor) -> Void)?
    private var pending: SpaceColor?
    private var isFlushScheduled = false

    /// Opens the panel on `workspace`'s current background (preset colours start at
    /// their standard opacity). `apply` receives every change for that space.
    func edit(_ workspace: Workspace, apply: @escaping (UUID, SpaceColor) -> Void) {
        flush()
        let panel = NSColorPanel.shared
        // Detach first: setting the colour must not report a change for the old space.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = workspace.backgroundColor
        panel.title = "\(workspace.name) Color"

        workspaceId = workspace.id
        self.apply = apply
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let color = SpaceColor(sender.color) else { return }
        pending = color
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ThemeConstants.Animation.colorPreviewInterval) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        isFlushScheduled = false
        guard let workspaceId, let apply, let color = pending else { return }
        pending = nil
        apply(workspaceId, color)
    }
}
