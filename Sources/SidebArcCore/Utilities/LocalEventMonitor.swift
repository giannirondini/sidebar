import AppKit

/// An `NSEvent` local monitor that is removed when this object goes away, so the
/// monitor lives exactly as long as whoever holds it.
final class LocalEventMonitor {
    private let token: Any?

    init(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
    }

    deinit {
        if let token {
            NSEvent.removeMonitor(token)
        }
    }
}
