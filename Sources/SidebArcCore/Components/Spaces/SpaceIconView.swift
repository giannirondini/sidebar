import AppKit

/// A space's icon: its emoji or SF Symbol (`Workspace.icon`) or, without one, a dot
/// in the space's colour. Used by Settings › Spaces, the space bar and the space header.
@MainActor
final class SpaceIconView: NSView {
    /// Side of the emoji or symbol.
    var iconSize: CGFloat = ThemeConstants.Sizing.iconMedium {
        didSet { applyContent() }
    }

    /// Diameter of the colour dot shown when the space has no icon.
    var dotSize: CGFloat = ThemeConstants.Sizing.iconSmall {
        didSet { applyContent() }
    }

    private static let dotBorderWidth: CGFloat = 2
    private static let dotBorderOpacity: CGFloat = 0.20

    private let imageView = NSImageView()
    private let dotView = NSView()
    private var dotWidth: NSLayoutConstraint!
    private var dotHeight: NSLayoutConstraint!
    private var icon: CustomIcon?
    private var color: NSColor = WorkspaceColorId.defaultColor().color

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.masksToBounds = true
        dotView.layer?.borderWidth = Self.dotBorderWidth
        dotView.layer?.borderColor = ThemeConstants.Colors.darkGray
            .withAlphaComponent(Self.dotBorderOpacity).cgColor
        addSubview(dotView)

        dotWidth = dotView.widthAnchor.constraint(equalToConstant: dotSize)
        dotHeight = dotView.heightAnchor.constraint(equalToConstant: dotSize)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dotView.centerXAnchor.constraint(equalTo: centerXAnchor),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotWidth,
            dotHeight,
        ])
        applyContent()
    }

    func configure(icon: CustomIcon?, color: NSColor) {
        self.icon = icon
        self.color = color
        applyContent()
    }

    private func applyContent() {
        dotWidth.constant = dotSize
        dotHeight.constant = dotSize
        dotView.layer?.cornerRadius = ThemeConstants.CornerRadius.round(dotSize)
        dotView.layer?.backgroundColor = color.cgColor

        let image = icon.flatMap { Self.image(for: $0, size: iconSize) }
        imageView.image = image
        imageView.contentTintColor = image?.isTemplate == true
            ? ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.high)
            : nil
        imageView.isHidden = image == nil
        dotView.isHidden = image != nil
    }

    /// The image for a custom icon at `size` points, or nil if it can't be drawn
    /// (unknown symbol, missing favicon file).
    static func image(for icon: CustomIcon, size: CGFloat) -> NSImage? {
        switch icon {
        case .emoji(let emoji):
            return NodeListViewController.imageFromEmoji(emoji, size: size)
        case .sfSymbol(let name):
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = true
            return image
        case .cachedFavicon(let path):
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return NSImage(contentsOfFile: path)
        }
    }
}
