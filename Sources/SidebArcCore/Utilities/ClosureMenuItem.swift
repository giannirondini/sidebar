import AppKit

/// An `NSMenuItem` that runs a closure. `NSMenuItem.target` is weak, so the item
/// keeps its handler object alive itself.
final class ClosureMenuItem: NSMenuItem {
    private final class Handler: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func perform(_ sender: Any?) { action() }
    }

    private let handler: Handler

    init(title: String, state: NSControl.StateValue = .off, action: @escaping () -> Void) {
        handler = Handler(action)
        super.init(title: title, action: #selector(Handler.perform(_:)), keyEquivalent: "")
        target = handler
        self.state = state
    }

    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem is not decodable")
    }
}
