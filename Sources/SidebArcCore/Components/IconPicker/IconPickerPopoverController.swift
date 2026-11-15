import AppKit

@MainActor
final class IconPickerPopoverController: NSViewController, NSSearchFieldDelegate {

    private let segmentedControl = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let gridView = IconPickerGridView()
    private let restoreButton = NSButton()
    private var gridTopToSegmentConstraint: NSLayoutConstraint!
    private var gridTopToSearchConstraint: NSLayoutConstraint!

    var showRestoreButton: Bool = false
    /// Title of the restore button ("Restore" brings back a link's favicon).
    var restoreButtonTitle = "Restore"
    /// Whether the Favicon tab is offered. Spaces take only emoji and SF Symbols.
    var allowsFavicons = true
    var onIconSelected: ((CustomIcon) -> Void)?
    var onRestoreFavicon: (() -> Void)?
    var onFaviconPathSelected: ((String) -> Void)?

    private var cachedFavicons: [(path: String, hostname: String, image: NSImage)] = []
    /// The emoji the Emoji tab shows (all, or the search results).
    private var shownEmojis: [String] = IconPickerConstants.emojis
    private var filteredFavicons: [(path: String, hostname: String, image: NSImage)] = []

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 320))
        container.wantsLayer = true
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupSegmentedControl()
        setupSearchField()
        setupGridView()
        setupRestoreButton()
        if allowsFavicons {
            loadCachedFavicons()
        }
        showTab(0)
    }

    private func setupSegmentedControl() {
        segmentedControl.segmentCount = allowsFavicons ? 3 : 2
        segmentedControl.setLabel("Emoji", forSegment: 0)
        segmentedControl.setLabel("Icon", forSegment: 1)
        if allowsFavicons {
            segmentedControl.setLabel("Favicon", forSegment: 2)
        }
        segmentedControl.selectedSegment = 0
        segmentedControl.segmentStyle = .texturedRounded
        segmentedControl.target = self
        segmentedControl.action = #selector(segmentChanged(_:))
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(segmentedControl)

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: view.topAnchor, constant: ThemeConstants.Spacing.medium),
            segmentedControl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ThemeConstants.Spacing.medium),
            segmentedControl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ThemeConstants.Spacing.medium),
        ])
    }

    private func setupSearchField() {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.isHidden = true

        view.addSubview(searchField)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: ThemeConstants.Spacing.medium),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ThemeConstants.Spacing.medium),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ThemeConstants.Spacing.medium),
        ])
    }

    private func setupGridView() {
        gridView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(gridView)

        gridTopToSegmentConstraint = gridView.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: ThemeConstants.Spacing.medium)
        gridTopToSearchConstraint = gridView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: ThemeConstants.Spacing.medium)

        NSLayoutConstraint.activate([
            gridTopToSegmentConstraint,
            gridView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: ThemeConstants.Spacing.medium),
            gridView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -ThemeConstants.Spacing.medium),
        ])
    }

    private func setupRestoreButton() {
        restoreButton.title = restoreButtonTitle
        restoreButton.bezelStyle = .rounded
        restoreButton.target = self
        restoreButton.action = #selector(restoreTapped)
        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.isHidden = !showRestoreButton

        view.addSubview(restoreButton)

        NSLayoutConstraint.activate([
            restoreButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            restoreButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -ThemeConstants.Spacing.medium),
        ])

        updateGridBottomConstraint()
    }

    private func updateGridBottomConstraint() {
        restoreButton.isHidden = !showRestoreButton

        for constraint in view.constraints where constraint.firstItem === gridView && constraint.firstAttribute == .bottom {
            constraint.isActive = false
        }

        if showRestoreButton {
            gridView.bottomAnchor.constraint(equalTo: restoreButton.topAnchor, constant: -ThemeConstants.Spacing.medium).isActive = true
        } else {
            gridView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -ThemeConstants.Spacing.medium).isActive = true
        }
    }

    /// Shows the search field with `placeholder` (nil hides it); a tab change always
    /// starts with an empty search.
    private func setSearchField(placeholder: String?) {
        let visible = placeholder != nil
        searchField.stringValue = ""
        searchField.placeholderString = placeholder ?? ""
        searchField.isHidden = !visible
        // Deactivate first, so the two grid-top constraints never conflict.
        (visible ? gridTopToSegmentConstraint : gridTopToSearchConstraint).isActive = false
        (visible ? gridTopToSearchConstraint : gridTopToSegmentConstraint).isActive = true
    }

    private func loadCachedFavicons() {
        let iconsDir = DataStore().iconsDirectory()

        guard FileManager.default.fileExists(atPath: iconsDir.path) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(at: iconsDir, includingPropertiesForKeys: nil) else { return }

        for file in files {
            guard file.pathExtension == "ico" || file.pathExtension == "png" else { continue }
            if let image = NSImage(contentsOf: file) {
                let hostname = file.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_", with: ":")
                cachedFavicons.append((path: file.path, hostname: hostname, image: image))
            }
        }

        cachedFavicons.sort { $0.hostname.localizedCaseInsensitiveCompare($1.hostname) == .orderedAscending }
        filteredFavicons = cachedFavicons
    }

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        showTab(sender.selectedSegment)
    }

    private func showTab(_ index: Int) {
        switch index {
        case 0:
            setSearchField(placeholder: "Search emoji…")
            showEmojiTab()
        case 1:
            setSearchField(placeholder: nil)
            showSFSymbolTab()
        case 2:
            setSearchField(placeholder: "Search favicons…")
            filterAndShowFavicons()
        default:
            break
        }
    }

    private func showEmojiTab() {
        shownEmojis = IconPickerConstants.emojiSearch(searchField.stringValue)
        let items = shownEmojis.map { IconPickerItemView.Content.emoji($0) }
        gridView.setItems(items) { [weak self] index in
            guard let self, index < self.shownEmojis.count else { return }
            self.onIconSelected?(.emoji(self.shownEmojis[index]))
            self.dismissPopover()
        }
    }

    private func showSFSymbolTab() {
        let items = IconPickerConstants.sfSymbols.map { IconPickerItemView.Content.sfSymbol($0) }
        gridView.setItems(items) { [weak self] index in
            let symbol = IconPickerConstants.sfSymbols[index]
            self?.onIconSelected?(.sfSymbol(symbol))
            self?.dismissPopover()
        }
    }

    private func filterAndShowFavicons() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filteredFavicons = cachedFavicons
        } else {
            filteredFavicons = cachedFavicons.filter { $0.hostname.lowercased().contains(query) }
        }

        let items = filteredFavicons.map { IconPickerItemView.Content.favicon($0.image) }
        gridView.setItems(items) { [weak self] index in
            guard let self, index < self.filteredFavicons.count else { return }
            let path = self.filteredFavicons[index].path
            self.onFaviconPathSelected?(path)
            self.dismissPopover()
        }
    }

    // MARK: - NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        switch segmentedControl.selectedSegment {
        case 0: showEmojiTab()
        case 2: filterAndShowFavicons()
        default: break
        }
    }

    @objc private func restoreTapped() {
        onRestoreFavicon?()
        dismissPopover()
    }

    private func dismissPopover() {
        if let popover = view.window?.parent?.contentViewController?.presentedViewControllers?.first(where: { $0 === self }) {
            popover.dismiss(nil)
        } else {
            view.window?.close()
        }
    }
}
