import AppKit

/// The space's icon and name, between the Favorites grid and the pinned list
/// (Arc's "🚀 Me" row). The only place the current space's name is shown.
///
/// - Double-click the name: inline rename.
/// - Click the icon: the icon picker.
/// - Right-click: the space menu.
@MainActor
final class SpaceHeaderView: BaseView {
    var onRename: ((String) -> Void)?
    /// The icon was clicked; the argument is the view to anchor a popover to.
    var onIconClicked: ((NSView) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    private let metrics = ListMetrics()
    private let iconView = SpaceIconView()
    private let titleField = InlineEditableTextField()

    var isRenaming: Bool { titleField.isEditing }

    /// The icon, to anchor the icon picker to.
    var iconAnchorView: NSView { iconView }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.iconSize = metrics.iconSize
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = ThemeConstants.Fonts.bodyMedium
        titleField.textColor = ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.medium)
        addSubview(titleField)

        // Same icon column and title inset as a top-level row of the pinned list.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: metrics.rowHeight),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: metrics.leftPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: metrics.iconSize),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: ThemeConstants.Spacing.large),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ThemeConstants.Spacing.extraLarge),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    func configure(name: String, icon: CustomIcon?, color: NSColor) {
        iconView.configure(icon: icon, color: color)
        // Never touch the title while it is being edited: `text` is the live typed
        // value, and any reload (a favicon arriving) would otherwise end the rename.
        guard !titleField.isEditing else { return }
        titleField.text = name
        setAccessibilityLabel(name)
    }

    func beginInlineRename() {
        titleField.beginInlineRename(onCommit: { [weak self] newName in
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self?.onRename?(trimmed)
        }, onCancel: {})
    }

    func cancelInlineRename() {
        titleField.cancelInlineRename()
    }

    // While not renaming, the header takes every click itself (the label would
    // otherwise swallow them); while renaming, the field editor needs them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !titleField.isEditing else { return super.hitTest(point) }
        return frame.contains(point) ? self : nil  // `point` is in the superview's coordinates
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if iconView.frame.insetBy(dx: -ThemeConstants.Spacing.tiny, dy: -ThemeConstants.Spacing.tiny).contains(point) {
            if event.clickCount == 1 {
                onIconClicked?(iconView)
            }
            return
        }
        if event.clickCount == 2 {
            beginInlineRename()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }
}
