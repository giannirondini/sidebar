import AppKit
import Testing
@testable import SidebArcCore

/// Opt-in, off-screen measurement of the pinned list with many rows:
/// `SIDEBARC_LIST_PROBE=1`. Prints timings only; asserts nothing about speed.
@MainActor
@Suite(.serialized) struct NodeListPerformanceProbe {
    nonisolated private static let enabled = ProcessInfo.processInfo.environment["SIDEBARC_LIST_PROBE"] != nil

    private func makeHostedList(rows: Int) throws -> (NSWindow, NodeListViewController, NSCollectionView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        let controller = NodeListViewController()
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 340, height: 800)
        window.orderFrontRegardless()
        let nodes: [Node] = (0..<rows).map { index in
            .link(Link(id: UUID(), title: "Link \(index)", url: "https://example.com/\(index)",
                       faviconPath: nil, customIcon: .sfSymbol("star")))
        }
        controller.reloadData(with: nodes, forceExpand: false, animated: false)
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let collection = try #require(controller.scrollView.documentView as? NSCollectionView)
        return (window, controller, collection)
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @Test(.enabled(if: enabled))
    func scrollingAndSelectionReloadCost() throws {
        let rows = 2000
        let (window, controller, collection) = try makeHostedList(rows: rows)
        defer { window.close() }
        let clock = ContinuousClock()
        let clipView = controller.scrollView.contentView
        let maxY = max(0, collection.bounds.height - clipView.bounds.height)

        // 1. Scrolling: 400 steps of 12 pt (like trackpad ticks), each laid out and
        //    drawn, so the layout invalidation and the shadow layers are included.
        let steps = 400
        var y: CGFloat = 0
        let scroll = clock.measure {
            for _ in 0..<steps {
                y = min(maxY, y + 12)
                clipView.scroll(to: NSPoint(x: 0, y: y))
                controller.scrollView.reflectScrolledClipView(clipView)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }

        // 2. What `updateShadows` allocates per scroll event: two gradient layers.
        let gradients = clock.measure {
            for _ in 0..<steps {
                let top = CAGradientLayer()
                top.colors = [NSColor.white.cgColor, NSColor.black.cgColor]
                let bottom = CAGradientLayer()
                bottom.colors = [NSColor.white.cgColor, NSColor.black.cgColor]
                _ = (top, bottom)
            }
        }

        // 3. `reloadVisibleSelection`: one `reloadItems` per row of the whole list,
        //    against one batched call, each followed by a layout and a draw.
        clipView.scroll(to: .zero)
        controller.scrollView.reflectScrolledClipView(clipView)
        let all = (0..<rows).map { IndexPath(item: $0, section: 0) }
        let perRow = clock.measure {
            for indexPath in all {
                collection.reloadItems(at: [indexPath])
            }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        let batched = clock.measure {
            collection.reloadItems(at: Set(all))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        let scrollMs = milliseconds(scroll)
        print("[list probe] \(rows) rows, \(steps) scroll steps: \(String(format: "%.1f", scrollMs)) ms total, \(String(format: "%.3f", scrollMs / Double(steps))) ms/step")
        print("[list probe] gradient layers (2 per step) alone: \(String(format: "%.3f", milliseconds(gradients) / Double(steps))) ms/step")
        print("[list probe] selection reload: per-row \(String(format: "%.1f", milliseconds(perRow))) ms, batched \(String(format: "%.1f", milliseconds(batched))) ms")
    }
}
