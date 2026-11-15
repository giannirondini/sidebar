import AppKit

/// Where the sidebar window goes at launch (pure, tested).
enum WindowPlacement {
    /// nil when `frame` intersects the visible area of **any** display, so a window
    /// saved on a secondary display stays there; otherwise the origin that centres it
    /// on the primary display (`visibleFrames[0]`). Checking only `NSScreen.main` (the
    /// menu-bar display at launch) moved such windows every time.
    static func originToShow(frame: NSRect, visibleFrames: [NSRect]) -> NSPoint? {
        guard let primary = visibleFrames.first else { return nil }
        if visibleFrames.contains(where: { $0.intersects(frame) }) { return nil }
        return NSPoint(x: primary.midX - frame.width / 2, y: primary.midY - frame.height / 2)
    }
}
