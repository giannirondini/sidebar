import AppKit

@MainActor
final class PinnedTabsView: NSView {

    var onLinkClicked: ((UUID) -> Void)?
    var onLinkRightClicked: ((UUID, NSEvent) -> Void)?

    private var tileViews: [PinnedTabTileView] = []
    private var currentLinks: [Link] = []
    /// Columns used by the last layout; the height depends on it.
    private var layoutColumns = ThemeConstants.Sizing.pinnedTileMinColumns

    /// Columns that fit `width` with tiles at least `pinnedTileMinWidth` wide,
    /// never fewer than `pinnedTileMinColumns`.
    static func columnCount(forWidth width: CGFloat) -> Int {
        let gap = ThemeConstants.Sizing.pinnedTileSpacing
        let fitting = Int(((width + gap) / (ThemeConstants.Sizing.pinnedTileMinWidth + gap)).rounded(.down))
        return max(ThemeConstants.Sizing.pinnedTileMinColumns, fitting)
    }

    /// Rows needed for `count` tiles in `columns` columns.
    static func rowCount(tiles count: Int, columns: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        return (count + columns - 1) / columns
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }

    func update(pinnedLinks: [Link]) {
        currentLinks = pinnedLinks
        isHidden = pinnedLinks.isEmpty

        // Remove excess tiles
        while tileViews.count > pinnedLinks.count {
            tileViews.removeLast().removeFromSuperview()
        }

        // Add new tiles if needed
        while tileViews.count < pinnedLinks.count {
            let tile = PinnedTabTileView(frame: .zero)
            tile.onTileClicked = { [weak self] linkId in
                self?.onLinkClicked?(linkId)
            }
            tile.onTileRightClicked = { [weak self] linkId, event in
                self?.onLinkRightClicked?(linkId, event)
            }
            addSubview(tile)
            tileViews.append(tile)
        }

        // Configure each tile
        for (index, link) in pinnedLinks.enumerated() {
            tileViews[index].configure(link: link, iconsDirectory: nil)
            fetchFaviconIfNeeded(for: link)
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let count = tileViews.count
        guard count > 0 else { return }

        let gap = ThemeConstants.Sizing.pinnedTileSpacing
        let tileHeight = ThemeConstants.Sizing.pinnedTileHeight
        let totalWidth = bounds.width
        let columns = Self.columnCount(forWidth: totalWidth)
        if columns != layoutColumns {
            layoutColumns = columns
            invalidateIntrinsicContentSize()
        }

        var y: CGFloat = 0
        var placed = 0

        while placed < count {
            let remaining = count - placed
            // A short last row stretches its tiles across the full width (as before).
            let cols = min(remaining, columns)
            let tileWidth = (totalWidth - gap * CGFloat(cols - 1)) / CGFloat(cols)

            for col in 0..<cols {
                let x = CGFloat(col) * (tileWidth + gap)
                tileViews[placed + col].frame = NSRect(x: x, y: y, width: tileWidth, height: tileHeight)
            }

            placed += cols
            y += tileHeight + gap
        }
    }

    override var intrinsicContentSize: NSSize {
        let count = currentLinks.count
        guard count > 0 else { return NSSize(width: NSView.noIntrinsicMetric, height: 0) }

        let tileHeight = ThemeConstants.Sizing.pinnedTileHeight
        let gap = ThemeConstants.Sizing.pinnedTileSpacing
        let rows = Self.rowCount(tiles: count, columns: layoutColumns)
        let height = CGFloat(rows) * tileHeight + CGFloat(rows - 1) * gap

        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    func tileView(for linkId: UUID) -> PinnedTabTileView? {
        tileViews.first(where: { $0.linkId == linkId })
    }

    private func fetchFaviconIfNeeded(for link: Link) {
        guard link.faviconPath == nil || !FileManager.default.fileExists(atPath: link.faviconPath ?? "") else { return }
        guard let url = URL(string: link.url) else { return }

        FaviconService.shared.favicon(for: url, cachedPath: link.faviconPath) { _, path in
            guard let path else { return }
            NotificationCenter.default.post(
                name: .init("UpdateLinkFavicon"),
                object: nil,
                userInfo: ["linkId": link.id, "path": path]
            )
        }
    }
}
