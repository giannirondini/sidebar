import AppKit

/// Settings section listing profiles: name, space count, browser and browser
/// profile, with rename/delete and an "Add Profile" button.
///
/// Renders from `update(...)` and reports every user action through a closure;
/// the owning view controller performs the `AppModel` call (and any prompt).
final class ProfileSettingsView: NSView {
    struct Row {
        let profile: Profile
        let spaceCount: Int
        /// Browser the profile's links open in (its own, or the global default).
        let resolvedBrowser: String?
        let supportsBrowserProfiles: Bool
        /// Browser profiles detected for `resolvedBrowser`.
        let detectedBrowserProfiles: [BrowserProfile]
        /// The profile names a browser that isn't installed on this Mac.
        let browserIsMissing: Bool
    }

    var onAdd: (() -> Void)?
    var onRename: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    /// (profile, browser bundle id or nil to inherit the global default)
    var onSetBrowser: ((UUID, String?) -> Void)?
    /// (profile, browser bundle id, browser profile dir or nil for none)
    var onSetBrowserProfile: ((UUID, String, String?) -> Void)?
    /// (profile, browser bundle id): the user picked "Other…" to type a dir.
    var onEnterBrowserProfile: ((UUID, String) -> Void)?

    private let stack = NSStackView()
    private let addButton = SettingsActionButton(title: "Add Profile")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ThemeConstants.Spacing.extraLarge
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),

            addButton.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: ThemeConstants.Spacing.large),
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            addButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func update(rows: [Row], browsers: [BrowserInfo], globalDefaultName: String?, canDelete: Bool) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for row in rows {
            let rowView = ProfileRowView(row: row, browsers: browsers, globalDefaultName: globalDefaultName, canDelete: canDelete)
            rowView.onRename = { [weak self] in self?.onRename?(row.profile.id) }
            rowView.onDelete = { [weak self] in self?.onDelete?(row.profile.id) }
            rowView.onSetBrowser = { [weak self] bundleId in self?.onSetBrowser?(row.profile.id, bundleId) }
            rowView.onSetBrowserProfile = { [weak self] bundleId, dir in self?.onSetBrowserProfile?(row.profile.id, bundleId, dir) }
            rowView.onEnterBrowserProfile = { [weak self] bundleId in self?.onEnterBrowserProfile?(row.profile.id, bundleId) }
            stack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    @objc private func addTapped() {
        onAdd?()
    }
}

// MARK: - Row

private final class ProfileRowView: NSView {
    /// Popup choice for the browser-profile menu.
    private enum DirChoice {
        case none
        case dir(String)
        case other
    }

    private final class DirChoiceBox: NSObject {
        let choice: DirChoice
        init(_ choice: DirChoice) { self.choice = choice }
    }

    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSetBrowser: ((String?) -> Void)?
    var onSetBrowserProfile: ((String, String?) -> Void)?
    var onEnterBrowserProfile: ((String) -> Void)?

    private let row: Row
    private let browserPopup = NSPopUpButton()
    private let dirPopup = NSPopUpButton()
    private let canDelete: Bool

    typealias Row = ProfileSettingsView.Row

    private static let textColor = ThemeConstants.Colors.darkGray
    private static let secondaryTextColor = ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.medium)
    private static let popupFont = NSFont.systemFont(ofSize: 13)
    private static let popupHeight: CGFloat = 36
    private static let popupInset: CGFloat = 12

    init(row: Row, browsers: [BrowserInfo], globalDefaultName: String?, canDelete: Bool) {
        self.row = row
        self.canDelete = canDelete
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(browsers: browsers, globalDefaultName: globalDefaultName)
    }

    required init?(coder: NSCoder) {
        fatalError("ProfileRowView is built in code")
    }

    private func build(browsers: [BrowserInfo], globalDefaultName: String?) {
        // Header: name, space count, actions menu
        let nameLabel = NSTextField(labelWithString: row.profile.name)
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = Self.textColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let countText = row.spaceCount == 1 ? "1 space" : "\(row.spaceCount) spaces"
        let countLabel = NSTextField(labelWithString: countText)
        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = Self.secondaryTextColor

        let actionsButton = NSButton()
        actionsButton.isBordered = false
        actionsButton.bezelStyle = .regularSquare
        actionsButton.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Profile actions")
        actionsButton.contentTintColor = Self.secondaryTextColor
        actionsButton.target = self
        actionsButton.action = #selector(showActions(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [nameLabel, countLabel, spacer, actionsButton])
        header.orientation = .horizontal
        header.spacing = ThemeConstants.Spacing.small
        header.translatesAutoresizingMaskIntoConstraints = false

        // Browser popup: inherit, then installed browsers (+ a missing one, if configured)
        configure(popup: browserPopup)
        let inheritTitle = globalDefaultName.map { "Default Browser (\($0))" } ?? "Default Browser"
        browserPopup.addItem(withTitle: inheritTitle)
        browserPopup.lastItem?.representedObject = nil
        browserPopup.menu?.addItem(.separator())
        for browser in browsers {
            browserPopup.addItem(withTitle: browser.name)
            browserPopup.lastItem?.representedObject = browser.bundleId
            if let icon = browser.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                browserPopup.lastItem?.image = icon
            }
        }
        if let configured = row.profile.browserBundleId {
            if row.browserIsMissing {
                browserPopup.addItem(withTitle: "\(configured) (not installed)")
                browserPopup.lastItem?.representedObject = configured
                browserPopup.select(browserPopup.lastItem)
            } else if let index = browserPopup.itemArray.firstIndex(where: {
                ($0.representedObject as? String)?.caseInsensitiveCompare(configured) == .orderedSame
            }) {
                browserPopup.selectItem(at: index)
            }
        } else {
            browserPopup.selectItem(at: 0)
        }
        browserPopup.action = #selector(browserChanged)
        styleTitle(of: browserPopup)

        var arranged: [NSView] = [header, container(for: browserPopup)]

        if row.browserIsMissing {
            let warning = NSTextField(labelWithString: "Not installed on this Mac: links open in the default browser.")
            warning.font = NSFont.systemFont(ofSize: 11)
            warning.textColor = .systemRed
            warning.lineBreakMode = .byWordWrapping
            warning.maximumNumberOfLines = 0
            arranged.append(warning)
        }

        // Browser-profile popup, only for browsers that support profiles
        if row.supportsBrowserProfiles, row.resolvedBrowser != nil {
            configure(popup: dirPopup)
            let current = row.resolvedBrowser.flatMap { row.profile.browserProfiles[$0] }
            dirPopup.addItem(withTitle: "No Browser Profile")
            dirPopup.lastItem?.representedObject = DirChoiceBox(.none)
            for detected in row.detectedBrowserProfiles {
                dirPopup.addItem(withTitle: detected.displayName)
                dirPopup.lastItem?.representedObject = DirChoiceBox(.dir(detected.id))
                if detected.id == current { dirPopup.select(dirPopup.lastItem) }
            }
            if let current, !row.detectedBrowserProfiles.contains(where: { $0.id == current }) {
                dirPopup.addItem(withTitle: current)
                dirPopup.lastItem?.representedObject = DirChoiceBox(.dir(current))
                dirPopup.select(dirPopup.lastItem)
            }
            dirPopup.menu?.addItem(.separator())
            dirPopup.addItem(withTitle: "Other…")
            dirPopup.lastItem?.representedObject = DirChoiceBox(.other)
            if current == nil { dirPopup.selectItem(at: 0) }
            dirPopup.action = #selector(dirChanged)
            styleTitle(of: dirPopup)
            arranged.append(container(for: dirPopup))
        }

        let column = NSStackView(views: arranged)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = ThemeConstants.Spacing.medium
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in arranged {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    private func configure(popup: NSPopUpButton) {
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = self
        popup.font = Self.popupFont
        popup.isBordered = false
        popup.focusRingType = .none
        if #available(macOS 14.0, *) {
            popup.contentTintColor = ThemeConstants.Colors.darkGray.withAlphaComponent(ThemeConstants.Opacity.high)
        }
    }

    /// Same look as the global browser picker in Settings.
    private func container(for popup: NSPopUpButton) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = ThemeConstants.Colors.darkGray
            .withAlphaComponent(ThemeConstants.Opacity.minimal).cgColor
        container.layer?.cornerRadius = ThemeConstants.CornerRadius.medium
        container.addSubview(popup)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: Self.popupHeight),
            popup.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.popupInset),
            popup.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.popupInset),
            popup.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func styleTitle(of popup: NSPopUpButton) {
        guard let title = popup.titleOfSelectedItem else { return }
        popup.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: Self.textColor,
            .font: Self.popupFont,
        ])
    }

    @objc private func showActions(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Rename…") { [weak self] in self?.onRename?() })
        let delete = ClosureMenuItem(title: "Delete…") { [weak self] in self?.onDelete?() }
        delete.isEnabled = canDelete
        menu.autoenablesItems = false
        menu.addItem(delete)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func browserChanged() {
        styleTitle(of: browserPopup)
        onSetBrowser?(browserPopup.selectedItem?.representedObject as? String)
    }

    @objc private func dirChanged() {
        styleTitle(of: dirPopup)
        guard let browser = row.resolvedBrowser,
              let box = dirPopup.selectedItem?.representedObject as? DirChoiceBox else { return }
        switch box.choice {
        case .none: onSetBrowserProfile?(browser, nil)
        case .dir(let dir): onSetBrowserProfile?(browser, dir)
        case .other: onEnterBrowserProfile?(browser)
        }
    }
}
