import AppKit

/// The bottom bar: the Settings gear, one icon per space, and `+` (Arc's space bar).
///
/// ```
/// [⚙︎]  [🚀][💼][●][📚] … scrolls …  [+]
/// ```
///
/// Space icons are centred while they fit and scroll horizontally (with faded edges)
/// when they don't; the selected one is kept in view. The selection is a separate
/// pill view behind the icons, so a space switch can slide it (Phase 3a.5).
/// Outside the swipe clip; register it with `SwipeGestureService.addExcludedView`
/// so a horizontal scroll here scrolls the bar instead of switching spaces.
@MainActor
final class SpaceBarView: NSView {
    struct Item: Equatable {
        let id: UUID
        let name: String
        let icon: CustomIcon?
        let colorId: WorkspaceColorId
    }

    var onSpaceSelected: ((UUID) -> Void)?
    var onSpaceContextMenu: ((UUID, NSEvent) -> Void)?
    var onAddSpace: (() -> Void)?
    var onSettings: (() -> Void)?

    private let buttonSize = ThemeConstants.Sizing.spaceBarButtonSize
    private let gap = ThemeConstants.Spacing.tiny
    private let fadeWidth = ThemeConstants.Spacing.huge
    /// Sub-point slack when deciding whether the bar can scroll further.
    private static let edgeTolerance: CGFloat = 0.5

    private let settingsButton = SpaceBarButton(symbolName: "gearshape", label: "Settings")
    private let addButton = SpaceBarButton(symbolName: "plus", label: "New Space")
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let selectionPill = NSView()
    private let fadeMask = CAGradientLayer()

    private var items: [Item] = []
    private var spaceButtons: [SpaceBarButton] = []
    private var selectedId: UUID?
    private var isSettingsShown = false
    /// While a space transition settles, the pill's frame belongs to its target.
    private var pillTargetId: UUID?
    private static let pillAnimationKey = "spaceTransition"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: ThemeConstants.Sizing.spaceBarHeight)
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        settingsButton.onTap = { [weak self] in self?.onSettings?() }
        addButton.onTap = { [weak self] in self?.onAddSpace?() }
        addSubview(settingsButton)
        addSubview(addButton)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.wantsLayer = true
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        scrollView.layer?.mask = fadeMask

        selectionPill.wantsLayer = true
        selectionPill.layer?.cornerRadius = ThemeConstants.CornerRadius.small
        selectionPill.layer?.backgroundColor = ThemeConstants.Colors.darkGray
            .withAlphaComponent(ThemeConstants.Opacity.subtle).cgColor
        documentView.addSubview(selectionPill)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Content

    func update(items newItems: [Item], selectedId newSelectedId: UUID?, isSettingsShown newSettingsShown: Bool) {
        let itemsChanged = newItems != items
        let selectionChanged = newSelectedId != selectedId || newSettingsShown != isSettingsShown
        items = newItems
        selectedId = newSelectedId
        isSettingsShown = newSettingsShown

        if itemsChanged {
            rebuildSpaceButtons()
        }
        updateSelection()
        if itemsChanged || selectionChanged {
            needsLayout = true
            layoutSubtreeIfNeeded()
            scrollSelectedIntoView()
        }
    }

    private func rebuildSpaceButtons() {
        spaceButtons.forEach { $0.removeFromSuperview() }
        spaceButtons = items.map { item in
            let button = SpaceBarButton(spaceIcon: item.icon, color: item.colorId.color, label: item.name)
            button.onTap = { [weak self] in self?.onSpaceSelected?(item.id) }
            button.onRightClick = { [weak self] event in self?.onSpaceContextMenu?(item.id, event) }
            documentView.addSubview(button)
            return button
        }
    }

    private func updateSelection() {
        settingsButton.isSelected = isSettingsShown
        let selectedIndex = isSettingsShown ? nil : items.firstIndex(where: { $0.id == selectedId })
        for (index, button) in spaceButtons.enumerated() {
            button.isSelected = index == selectedIndex
        }
        selectionPill.isHidden = selectedIndex == nil
    }

    // MARK: - Selection during a space transition

    private func buttonFrame(for spaceId: UUID) -> NSRect? {
        guard let index = items.firstIndex(where: { $0.id == spaceId }), index < spaceButtons.count else { return nil }
        return spaceButtons[index].frame
    }

    // The pill moves by its frame (which AppKit keeps) plus an additive animation,
    // never by a layer transform: AppKit resets the transforms of its views' layers.

    /// While a swipe is tracked: the pill sits `progress` (0…1) of the way from
    /// the selected space's icon toward `targetId`'s (nil: stays put).
    func setSelectionProgress(toward targetId: UUID?, progress: CGFloat) {
        guard let selectedId, let from = buttonFrame(for: selectedId) else { return }
        let to = targetId.flatMap { buttonFrame(for: $0) } ?? from
        selectionPill.frame = from.offsetBy(dx: (to.minX - from.minX) * progress, dy: 0)
    }

    /// Moves the pill from where it is now to `spaceId`'s icon with `animation`,
    /// built for `keyPath` from the start to the end offset (applied additively).
    /// Call inside the transition's `CATransaction` so it runs in step with the page.
    func settleSelection(on spaceId: UUID, animation: (_ keyPath: String, _ from: CGFloat, _ to: CGFloat) -> CAPropertyAnimation) {
        guard !isSettingsShown, let target = buttonFrame(for: spaceId), let layer = selectionPill.layer else { return }
        let currentX = selectionPill.frame.minX
        pillTargetId = spaceId
        layer.removeAnimation(forKey: Self.pillAnimationKey)
        selectionPill.frame = target
        let move = animation("position.x", currentX - target.minX, 0)
        move.isAdditive = true
        layer.add(move, forKey: Self.pillAnimationKey)
    }

    /// Ends a settle: the pill rests on its target; the next `update` takes over.
    func endSelectionTransition() {
        selectionPill.layer?.removeAnimation(forKey: Self.pillAnimationKey)
        pillTargetId = nil
    }

    /// The button of a space, e.g. to anchor a popover to it.
    func buttonView(for spaceId: UUID) -> NSView? {
        guard let index = items.firstIndex(where: { $0.id == spaceId }), index < spaceButtons.count else { return nil }
        return spaceButtons[index]
    }

    private func scrollSelectedIntoView() {
        guard let index = items.firstIndex(where: { $0.id == selectedId }), index < spaceButtons.count else { return }
        documentView.scrollToVisible(spaceButtons[index].frame.insetBy(dx: -fadeWidth, dy: 0))
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let height = bounds.height
        let y = (height - buttonSize) / 2

        settingsButton.frame = NSRect(x: 0, y: y, width: buttonSize, height: buttonSize)
        addButton.frame = NSRect(x: bounds.width - buttonSize, y: y, width: buttonSize, height: buttonSize)

        let scrollX = buttonSize + gap
        let scrollWidth = max(0, bounds.width - 2 * (buttonSize + gap))
        scrollView.frame = NSRect(x: scrollX, y: 0, width: scrollWidth, height: height)

        let count = CGFloat(spaceButtons.count)
        let contentWidth = count * buttonSize + max(0, count - 1) * gap
        let documentWidth = max(contentWidth, scrollWidth)
        documentView.frame = NSRect(x: 0, y: 0, width: documentWidth, height: height)

        // Centred while they fit; otherwise packed from the leading edge and scrolled.
        let startX = (documentWidth - contentWidth) / 2
        for (index, button) in spaceButtons.enumerated() {
            button.frame = NSRect(x: startX + CGFloat(index) * (buttonSize + gap), y: y, width: buttonSize, height: buttonSize)
        }
        if let pillId = pillTargetId ?? selectedId, let frame = buttonFrame(for: pillId) {
            selectionPill.frame = frame
        }
        updateFadeMask()
    }

    @objc private func scrollBoundsChanged() {
        updateFadeMask()
        spaceButtons.forEach { $0.refreshHoverState() }
    }

    /// Fades an edge only when there is more to scroll to on that side.
    private func updateFadeMask() {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let canScrollLeft = visible.minX > Self.edgeTolerance
        let canScrollRight = visible.maxX < documentView.frame.width - Self.edgeTolerance
        let fade = min(fadeWidth / width, 0.5)
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fadeMask.frame = scrollView.bounds
        fadeMask.colors = [canScrollLeft ? clear : opaque, opaque, opaque, canScrollRight ? clear : opaque]
        fadeMask.locations = [0, NSNumber(value: Double(fade)), NSNumber(value: Double(1 - fade)), 1]
        CATransaction.commit()
    }
}

// MARK: - Buttons

/// A square button of the space bar: a space's icon (or colour dot), or a symbol
/// (gear, `+`). Unselected content is dimmed; hover shows a faint background.
@MainActor
final class SpaceBarButton: BaseControl {
    var onTap: (() -> Void)?
    var onRightClick: ((NSEvent) -> Void)?

    /// Selected space: full-opacity icon (the pill behind it is drawn by the bar).
    /// Selected gear: its own background, since it has no pill.
    var isSelected = false {
        didSet {
            setAccessibilitySelected(isSelected)
            updateAppearance()
        }
    }

    private let content: NSView
    private let drawsOwnSelection: Bool

    init(spaceIcon: CustomIcon?, color: NSColor, label: String) {
        let iconView = SpaceIconView()
        iconView.iconSize = ThemeConstants.Sizing.iconMedium
        iconView.configure(icon: spaceIcon, color: color)
        content = iconView
        drawsOwnSelection = false
        super.init(frame: .zero)
        setup(label: label)
    }

    init(symbolName: String, label: String) {
        let imageView = NSImageView()
        let config = NSImage.SymbolConfiguration(pointSize: ThemeConstants.Sizing.iconSmall, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        imageView.contentTintColor = ThemeConstants.Colors.darkGray
        imageView.imageScaling = .scaleNone
        content = imageView
        drawsOwnSelection = true
        super.init(frame: .zero)
        setup(label: label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(label: String) {
        layer?.cornerRadius = ThemeConstants.CornerRadius.small
        toolTip = label
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.widthAnchor.constraint(equalToConstant: ThemeConstants.Sizing.iconMedium),
            content.heightAnchor.constraint(equalToConstant: ThemeConstants.Sizing.iconMedium),
        ])
        updateAppearance()
    }

    override func handleHoverStateChanged() {
        updateAppearance()
    }

    override func handlePressedStateChanged() {
        updateAppearance()
    }

    override func performAction() {
        onTap?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override func accessibilityPerformPress() -> Bool {
        onTap?()
        return true
    }

    private func updateAppearance() {
        let background: NSColor
        if drawsOwnSelection && isSelected {
            background = ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.subtle)
        } else if isPressed {
            background = ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.extraSubtle)
        } else if isHovered && !isSelected {
            background = ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.minimal)
        } else {
            background = .clear
        }
        layer?.backgroundColor = background.cgColor
        content.alphaValue = isSelected || isHovered ? ThemeConstants.Opacity.full : ThemeConstants.Opacity.medium
    }
}

/// Top-left origin, so the bar lays out like the rest of the sidebar.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
