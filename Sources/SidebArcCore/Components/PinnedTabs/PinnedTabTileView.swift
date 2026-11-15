import AppKit

@MainActor
final class PinnedTabTileView: BaseControl {

    private let faviconView = NSImageView()
    /// App icon of the favorite's browser override, at the tile's top-trailing corner.
    private let browserBadgeView = NSImageView()
    private(set) var linkId: UUID?
    private var linkURL: String?
    private var tooltipShowTask: DispatchWorkItem?
    private static let sharedTooltip = CustomTooltipView()

    var onTileClicked: ((UUID) -> Void)?
    var onTileRightClicked: ((UUID, NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        layer?.cornerRadius = ThemeConstants.CornerRadius.large
        layer?.backgroundColor = ThemeConstants.Colors.darkGray
            .withAlphaComponent(ThemeConstants.Opacity.extraSubtle).cgColor

        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(faviconView)

        browserBadgeView.translatesAutoresizingMaskIntoConstraints = false
        browserBadgeView.imageScaling = .scaleProportionallyUpOrDown
        browserBadgeView.isHidden = true
        addSubview(browserBadgeView)

        let iconSize = ThemeConstants.Sizing.iconLarge
        let badgeSize = ThemeConstants.Sizing.iconSmall
        NSLayoutConstraint.activate([
            // Clear of the rounded corner.
            browserBadgeView.topAnchor.constraint(equalTo: topAnchor, constant: ThemeConstants.Spacing.small),
            browserBadgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ThemeConstants.Spacing.small),
            browserBadgeView.widthAnchor.constraint(equalToConstant: badgeSize),
            browserBadgeView.heightAnchor.constraint(equalToConstant: badgeSize),

            faviconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            faviconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: iconSize),
            faviconView.heightAnchor.constraint(equalToConstant: iconSize),
        ])
    }

    func configure(link: Link) {
        tooltipShowTask?.cancel()
        tooltipShowTask = nil
        let badge = BrowserManager.overrideBadge(for: link.browserBundleId)
        browserBadgeView.image = badge
        browserBadgeView.isHidden = badge == nil
        linkId = link.id
        linkURL = link.url

        let size = ThemeConstants.Sizing.iconLarge
        func showGlobe() {
            faviconView.image = IconImages.symbol("globe", pointSize: size)
            faviconView.contentTintColor = ThemeConstants.Colors.darkGray
                .withAlphaComponent(ThemeConstants.Opacity.low)
        }
        if let customIcon = link.customIcon {
            let image = customIcon.image(emojiSize: size, symbolPointSize: size)
            switch customIcon {
            case .emoji:
                faviconView.image = image
                faviconView.contentTintColor = nil
            case .sfSymbol:
                faviconView.image = image
                faviconView.contentTintColor = ThemeConstants.Colors.darkGray
                    .withAlphaComponent(ThemeConstants.Opacity.high)
            case .cachedFavicon:
                if let image {
                    faviconView.image = image
                    faviconView.contentTintColor = nil
                } else {
                    showGlobe()
                }
            }
        } else if let path = link.faviconPath, let image = IconImages.favicon(atPath: path) {
            faviconView.image = image
            faviconView.contentTintColor = nil
        } else {
            showGlobe()
        }
    }

    // MARK: - State Overrides

    override func handleHoverStateChanged() {
        updateBackground()

        tooltipShowTask?.cancel()
        tooltipShowTask = nil

        if isHovered,
           let url = linkURL, !url.isEmpty,
           UserDefaults.standard.bool(forKey: UserDefaultsKeys.tooltipsEnabled) {
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.isHovered, let parentWindow = self.window else { return }
                PinnedTabTileView.sharedTooltip.show(text: url, cursorPosition: NSEvent.mouseLocation, parentWindow: parentWindow)
            }
            tooltipShowTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + TooltipConstants.showDelay, execute: task)
        } else {
            PinnedTabTileView.sharedTooltip.hide()
        }
    }

    override func handlePressedStateChanged() {
        updateBackground()
    }

    private func updateBackground() {
        let opacity: CGFloat
        if isPressed {
            opacity = ThemeConstants.Opacity.low
        } else if isHovered {
            opacity = ThemeConstants.Opacity.subtle
        } else {
            opacity = ThemeConstants.Opacity.extraSubtle
        }
        layer?.backgroundColor = ThemeConstants.Colors.darkGray
            .withAlphaComponent(opacity).cgColor
    }

    override func performAction() {
        guard let linkId else { return }
        onTileClicked?(linkId)
    }

    override func rightMouseDown(with event: NSEvent) {
        tooltipShowTask?.cancel()
        tooltipShowTask = nil
        PinnedTabTileView.sharedTooltip.hide()

        guard let linkId else { return }
        onTileRightClicked?(linkId, event)
    }
}
