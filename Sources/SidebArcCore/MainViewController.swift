import AppKit

@MainActor
final class MainViewController: NSViewController {
    let model: AppModel
    /// Called after every model reload (e.g. to refresh which browsers the sidebar
    /// attaches to when a profile's browser changes).
    var onModelReload: (() -> Void)?
    var noteServer: NoteServer?

    // Coordinators and child view controllers
    let searchCoordinator = SearchCoordinator()
    let nodeListViewController = NodeListViewController()
    private let settingsViewController = SettingsContentViewController()

    // UI Components
    let spaceBar = SpaceBarView()
    private let searchField = SearchBarView(style: .defaultSearch)
    let pinnedTabsView = PinnedTabsView()
    let spaceHeader = SpaceHeaderView()
    let scheduledLinksAccordion = ScheduledLinksAccordionView()
    /// "+ Add from Clipboard": the last row under the pinned list (Arc's "New Tab" row).
    private let pasteButton = IconTitleButton(
        title: "Add from Clipboard",
        symbolName: "plus",
        style: .listRow
    )

    // Swipe animation views
    var swipeClipContainer: NSView!         // Clips to bounds, contains content + preview
    var workspaceContentStack: NSStackView! // The animated workspace content

    // State
    private var isReloadScheduled = false
    private var hasLoaded = false
    private var lastWorkspaceId: UUID?
    private var pendingWorkspaceRenameId: UUID?
    var suppressNodeAnimations = false          // Suppresses collection view animations during swipe transitions
    /// The space switch in progress (MainViewController+SpaceTransition).
    var spaceTransition: SpaceTransition?
    /// A model change arrived during a space transition; reload once it finishes.
    /// Reloading mid-transition would reset the colour, snap the bar's pill and
    /// swap the list under the moving page.
    var reloadHeldByTransition = false
    /// Draws the pages while a space transition runs (over the live page, which is hidden).
    let pageStage = SpacePageStage()

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func loadView() {
        let view = NSView()
        view.wantsLayer = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupChildViewControllers()
        setupUI()
        setupSearchCoordinator()
        setupNodeListCallbacks()
        bindModel()
        reloadData()
        installTransitionInputMonitor()

        // Listen for favicon updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFaviconUpdate),
            name: .init("UpdateLinkFavicon"),
            object: nil
        )
    }

    // MARK: - Setup

    private func setupChildViewControllers() {
        addChild(nodeListViewController)
        addChild(settingsViewController)
    }

    private func setupUI() {
        // Space bar (bottom): gear, one icon per space, +
        spaceBar.onSpaceSelected = { [weak self] workspaceId in
            self?.requestSpaceSwitch(to: workspaceId)
        }
        spaceBar.onSpaceContextMenu = { [weak self] workspaceId, event in
            guard let self else { return }
            let anchor = self.spaceBar.buttonView(for: workspaceId) ?? self.spaceBar
            self.showWorkspaceContextMenu(for: workspaceId, at: event.locationInWindow, iconAnchor: anchor)
        }
        spaceBar.onAddSpace = { [weak self] in
            self?.promptCreateWorkspace()
        }
        spaceBar.onSettings = { [weak self] in
            self?.toggleSettings()
        }

        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "Search in space"
        searchField.onTextChange = { [weak self] text in
            self?.nodeListViewController.clearSelections()
            self?.searchCoordinator.updateQuery(text)
        }

        // Pinned tabs
        pinnedTabsView.onLinkClicked = { [weak self] linkId in
            guard let self, let link = self.model.pinnedLinkById(linkId) else { return }
            self.openClickedLink(link, source: .favorite)
        }
        pinnedTabsView.onLinkRightClicked = { [weak self] linkId, event in
            self?.showPinnedTabContextMenu(for: linkId, at: event)
        }

        // Space header (icon and name of the current space)
        spaceHeader.onRename = { [weak self] newName in
            guard let self else { return }
            self.model.renameWorkspace(id: self.model.currentWorkspace.id, newName: newName)
        }
        spaceHeader.onIconClicked = { [weak self] anchor in
            guard let self else { return }
            let workspace = self.model.currentWorkspace
            self.showIconPicker(for: workspace.id, relativeTo: anchor, hasCustomIcon: workspace.icon != nil, kind: .space)
        }
        spaceHeader.onContextMenu = { [weak self] event in
            guard let self else { return }
            self.showWorkspaceContextMenu(for: self.model.currentWorkspace.id, at: event.locationInWindow,
                                          iconAnchor: self.spaceHeader.iconAnchorView)
        }

        // Paste button
        pasteButton.translatesAutoresizingMaskIntoConstraints = false
        pasteButton.target = self
        pasteButton.action = #selector(pasteLink)

        // Node list view
        nodeListViewController.view.translatesAutoresizingMaskIntoConstraints = false

        // Settings view
        settingsViewController.appModel = model
        settingsViewController.view.translatesAutoresizingMaskIntoConstraints = false
        settingsViewController.view.isHidden = true

        // Layout
        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(pasteButton)

        // Scheduled links accordion (docked above paste button)
        scheduledLinksAccordion.onRowSelected = { [weak self] linkId in
            guard let self, let link = self.linkById(linkId) else { return }
            self.openLink(link)
        }
        scheduledLinksAccordion.onRowContextMenu = { [weak self] linkId, event in
            self?.showScheduledRowMenu(linkId: linkId, event: event)
        }

        // Workspace content stack (animated during swipe)
        let contentStack = NSStackView(views: [spaceHeader, scheduledLinksAccordion, nodeListViewController.view, bottomBar])
        contentStack.orientation = .vertical
        contentStack.spacing = 10
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.alignment = .centerX
        contentStack.wantsLayer = true
        // The header reads as the first row of the list below it.
        contentStack.setCustomSpacing(0, after: spaceHeader)
        workspaceContentStack = contentStack

        // Clipping container for swipe animation
        let clipContainer = NSView()
        clipContainer.translatesAutoresizingMaskIntoConstraints = false
        clipContainer.wantsLayer = true
        clipContainer.layer?.masksToBounds = true
        swipeClipContainer = clipContainer
        clipContainer.addSubview(contentStack)
        pageStage.translatesAutoresizingMaskIntoConstraints = false
        clipContainer.addSubview(pageStage, positioned: .above, relativeTo: contentStack)

        // Outer stack: search field, Favorites, the swipe clip container, then the space bar.
        // Favorites sit outside the clip: they belong to the profile, not the space, so a
        // switch between spaces of the same profile leaves them still.
        pinnedTabsView.wantsLayer = true
        let stack = NSStackView(views: [searchField, pinnedTabsView, clipContainer, spaceBar])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.alignment = .centerX

        view.addSubview(stack)
        view.addSubview(settingsViewController.view)

        NSLayoutConstraint.activate([
            pasteButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            pasteButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            pasteButton.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            pasteButton.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),

            // Content stack fills the clip container
            contentStack.leadingAnchor.constraint(equalTo: clipContainer.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: clipContainer.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: clipContainer.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: clipContainer.bottomAnchor),
            pageStage.leadingAnchor.constraint(equalTo: clipContainer.leadingAnchor),
            pageStage.trailingAnchor.constraint(equalTo: clipContainer.trailingAnchor),
            pageStage.topAnchor.constraint(equalTo: clipContainer.topAnchor),
            pageStage.bottomAnchor.constraint(equalTo: clipContainer.bottomAnchor),

            // Clip container fills width of outer stack
            clipContainer.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            clipContainer.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            spaceBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            spaceBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),

            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: LayoutConstants.windowPadding),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -LayoutConstants.windowPadding),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: LayoutConstants.windowPadding),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -LayoutConstants.windowPadding),

            bottomBar.heightAnchor.constraint(equalToConstant: pasteButton.style.height)
        ])

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 2),
            searchField.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -2),
            pinnedTabsView.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 2),
            pinnedTabsView.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -2),
            spaceHeader.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor),
            spaceHeader.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor),
            scheduledLinksAccordion.leadingAnchor.constraint(equalTo: contentStack.leadingAnchor, constant: 2),
            scheduledLinksAccordion.trailingAnchor.constraint(equalTo: contentStack.trailingAnchor, constant: -2),
        ])

        // Settings view constraints
        NSLayoutConstraint.activate([
            settingsViewController.view.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            settingsViewController.view.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            // Settings takes the place of search and the space content; the space bar
            // (and its gear, the way back) stays visible below it.
            settingsViewController.view.topAnchor.constraint(equalTo: stack.topAnchor),
            settingsViewController.view.bottomAnchor.constraint(equalTo: spaceBar.topAnchor, constant: -stack.spacing)
        ])
    }

    private func setupSearchCoordinator() {
        searchCoordinator.onQueryChanged = { [weak self] _ in
            self?.reloadData()
        }
    }

    private func setupNodeListCallbacks() {
        nodeListViewController.nodeProvider = { [weak self] in
            guard let self else { return [] }
            let visible = ScheduledLinkFiltering.hideScheduled(self.model.currentWorkspace.items)
            return self.searchCoordinator.filter(nodes: visible)
        }

        nodeListViewController.workspacesProvider = { [weak self] in
            self?.model.workspaces ?? []
        }

        nodeListViewController.currentWorkspaceIdProvider = { [weak self] in
            self?.model.currentWorkspace.id
        }

        nodeListViewController.findNodeById = { [weak self] id in
            self?.model.nodeById(id)
        }

        nodeListViewController.findNodeLocation = { [weak self] id in
            self?.model.location(of: id)
        }

        nodeListViewController.findNodeInNodes = { [weak self] id, nodes in
            self?.model.findNode(id: id, in: nodes)
        }

        nodeListViewController.onNodeSelected = { [weak self] nodeId in
            guard let self, let node = self.model.nodeById(nodeId) else { return }
            switch node {
            case .link(let link):
                self.openClickedLink(link, source: .list)
            case .note(let note):
                self.openNote(note)
            case .folder:
                break
            }
        }

        nodeListViewController.onFolderToggled = { [weak self] folderId, _ in
            guard let self else { return }
            if self.searchCoordinator.isSearchActive { return }
            if let node = self.model.nodeById(folderId), case .folder(let folder) = node {
                self.model.setFolderExpanded(id: folder.id, isExpanded: !folder.isExpanded)
            }
        }

        nodeListViewController.onNodeMoved = { [weak self] nodeId, targetParentId, targetIndex in
            self?.model.moveNode(id: nodeId, toParentId: targetParentId, index: targetIndex)
        }

        nodeListViewController.onNodeDeleted = { [weak self] nodeId in
            self?.model.deleteNode(id: nodeId)
        }

        nodeListViewController.onNodeRenamed = { [weak self] nodeId, newName in
            self?.model.renameNode(id: nodeId, newName: newName)
        }

        nodeListViewController.onNodeMovedToWorkspace = { [weak self] nodeId, workspaceId in
            self?.model.moveNodeToWorkspace(id: nodeId, workspaceId: workspaceId)
        }

        nodeListViewController.onBulkNodesMovedToWorkspace = { [weak self] nodeIds, workspaceId in
            self?.model.moveNodesToWorkspace(nodeIds: nodeIds, toWorkspaceId: workspaceId)
        }

        nodeListViewController.onBulkNodesGrouped = { [weak self] nodeIds, folderName in
            self?.model.groupNodesInNewFolder(nodeIds: nodeIds, folderName: folderName)
        }

        nodeListViewController.onBulkNodesCopied = { [weak self] nodeIds in
            self?.handleBulkCopyLinks(nodeIds)
        }

        nodeListViewController.onBulkNodesDeleted = { [weak self] nodeIds in
            guard let self else { return }
            for nodeId in nodeIds {
                self.model.deleteNode(id: nodeId)
            }
        }

        nodeListViewController.onNewFolderRequested = { [weak self] parentId in
            self?.createFolderAndBeginRename(parentId: parentId)
        }

        nodeListViewController.onNewNoteRequested = { [weak self] parentId in
            self?.createNoteAndBeginRename(parentId: parentId)
        }

        nodeListViewController.onLinkUrlEdited = { [weak self] nodeId, newUrl in
            self?.model.updateLinkUrl(id: nodeId, newUrl: newUrl)
        }

        nodeListViewController.onOpenFolderLinks = { [weak self] folderId in
            guard let self, let node = self.model.nodeById(folderId),
                  case .folder(let folder) = node else { return }
            for child in folder.children {
                if case .link(let link) = child {
                    self.openLink(link)
                }
            }
        }

        nodeListViewController.onBulkOpenLinks = { [weak self] nodeIds in
            guard let self else { return }
            for nodeId in nodeIds {
                guard let node = self.model.nodeById(nodeId) else { continue }
                switch node {
                case .link(let link):
                    self.openLink(link)
                case .note:
                    break
                case .folder(let folder):
                    for child in folder.children {
                        if case .link(let link) = child {
                            self.openLink(link)
                        }
                    }
                }
            }
        }

        nodeListViewController.onPinLink = { [weak self] nodeId in
            self?.model.pinLink(id: nodeId)
        }

        nodeListViewController.canPinLink = { [weak self] in
            self?.model.canPinMore ?? false
        }

        nodeListViewController.linkBrowserMenuItems = { [weak self] link in
            self?.browserMenuItems(for: link) ?? []
        }

        nodeListViewController.onLinkScheduled = { [weak self] id, date in
            self?.model.scheduleLink(id: id, at: date)
        }

        nodeListViewController.onLinkScheduleCleared = { [weak self] id in
            self?.model.cancelSchedule(id: id)
        }

        nodeListViewController.onChangeIconRequested = { [weak self] nodeId, anchorView in
            guard let self, let node = self.model.nodeById(nodeId) else { return }
            switch node {
            case .link(let link):
                self.showIconPicker(for: nodeId, relativeTo: anchorView, hasCustomIcon: link.customIcon != nil, kind: .link)
            case .note(let note):
                self.showIconPicker(for: nodeId, relativeTo: anchorView, hasCustomIcon: note.customIcon != nil, kind: .note)
            case .folder:
                break
            }
        }
    }

    private func bindModel() {
        model.onChange = { [weak self] in
            guard let self else { return }
            if self.spaceTransition != nil {
                self.reloadHeldByTransition = true
                return
            }
            if self.isReloadScheduled { return }
            self.isReloadScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReloadScheduled = false
                if self.spaceTransition != nil {
                    self.reloadHeldByTransition = true
                    return
                }
                self.reloadData()
            }
        }
    }

    // MARK: - Data Reload

    func reloadData() {
        defer { onModelReload?() }
        // Cancel any in-progress inline rename if node is deleted
        if let renameId = nodeListViewController.inlineRenameNodeId,
           model.nodeById(renameId) == nil {
            nodeListViewController.cancelInlineRename()
        }

        reloadWorkspaceMenu()

        // Notify settings view that workspaces may have changed
        settingsViewController.notifyWorkspacesChanged()

        // Clear selections when workspace changes
        let currentWorkspaceId = model.currentWorkspace.id
        if hasLoaded && currentWorkspaceId != lastWorkspaceId {
            nodeListViewController.clearSelections()
            // A rename in progress belongs to the space we just left.
            spaceHeader.cancelInlineRename()
            lastWorkspaceId = currentWorkspaceId
        }

        // Check if settings is selected
        if model.isSettingsShown {
            nodeListViewController.clearSelections()
            showSettingsContent()
        } else {
            showWorkspaceContent()
            applyWorkspaceStyling()
            pinnedTabsView.update(pinnedLinks: model.currentProfile.favorites)
            configureSpaceHeader(for: model.currentWorkspace)
            if searchCoordinator.isSearchActive {
                scheduledLinksAccordion.isHidden = true
            } else {
                scheduledLinksAccordion.update(entries: model.scheduledLinks(in: model.currentWorkspace.id))
            }
            let workspaceItems = model.currentWorkspace.items
            let visibleItems = searchCoordinator.isSearchActive
                ? workspaceItems
                : ScheduledLinkFiltering.hideScheduled(workspaceItems)
            let filteredNodes = searchCoordinator.filter(nodes: visibleItems)
            let forceExpand = searchCoordinator.isSearchActive
            nodeListViewController.isSearchActive = searchCoordinator.isSearchActive
            let animated = !suppressNodeAnimations
            nodeListViewController.reloadData(with: filteredNodes, forceExpand: forceExpand, animated: animated)
        }
        hasLoaded = true
    }

    private func reloadWorkspaceMenu() {
        spaceBar.update(
            items: model.workspaces.map {
                SpaceBarView.Item(id: $0.id, name: $0.name, icon: $0.icon, color: $0.color)
            },
            selectedId: model.currentWorkspace.id,
            isSettingsShown: model.isSettingsShown
        )

        handlePendingWorkspaceRename()
    }

    func configureSpaceHeader(for workspace: Workspace) {
        spaceHeader.configure(name: workspace.name, icon: workspace.icon, color: workspace.color)
    }

    private func applyWorkspaceStyling() {
        let newColor = model.currentWorkspace.backgroundColor
        nodeListViewController.workspaceBackgroundColor = newColor

        // A space transition animates the colour itself and lands on this value.
        view.layer?.backgroundColor = newColor.cgColor
    }

    private func showSettingsContent() {
        // Hide workspace content
        searchField.isHidden = true
        pinnedTabsView.isHidden = true
        spaceHeader.isHidden = true
        scheduledLinksAccordion.isHidden = true
        pasteButton.isHidden = true
        nodeListViewController.view.isHidden = true

        // Show settings content
        settingsViewController.view.isHidden = false

        let settingsColor = ThemeConstants.Colors.settingsBackground
        view.layer?.backgroundColor = settingsColor.cgColor
    }

    private func showWorkspaceContent() {
        // Show workspace content
        searchField.isHidden = false
        pinnedTabsView.isHidden = model.currentProfile.favorites.isEmpty
        spaceHeader.isHidden = false
        pasteButton.isHidden = false
        nodeListViewController.view.isHidden = false

        // Hide settings content
        settingsViewController.view.isHidden = true
    }

    // MARK: - Workspace Management

    /// The space menu for `workspaceId`. It acts on that space and never switches to it.
    /// - Parameter iconAnchor: what "Change Icon…" anchors its popover to (the clicked icon).
    private func showWorkspaceContextMenu(for workspaceId: UUID, at point: NSPoint, iconAnchor: NSView) {
        guard let index = model.workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        let workspace = model.workspaces[index]
        let count = model.workspaces.count
        let actions = SpaceMenu.Actions(
            rename: { [weak self] in
                self?.beginSpaceRename(workspaceId)
            },
            changeIcon: { [weak self] in
                self?.showIconPicker(for: workspaceId, relativeTo: iconAnchor,
                                     hasCustomIcon: workspace.icon != nil, kind: .space)
            },
            setColor: { [weak self] colorId in
                self?.model.updateWorkspaceColor(id: workspaceId, colorId: colorId)
            },
            customColor: { [weak self] in
                SpaceColorPanel.shared.edit(workspace) { [weak self] id, color in
                    self?.model.setWorkspaceCustomColor(id: id, color: color)
                }
            },
            moveLeft: index > 0 ? { [weak self] in
                self?.model.moveWorkspace(id: workspaceId, direction: .left)
            } : nil,
            moveRight: index < count - 1 ? { [weak self] in
                self?.model.moveWorkspace(id: workspaceId, direction: .right)
            } : nil,
            delete: { [weak self] in
                self?.confirmDeleteWorkspace(id: workspaceId)
            }
        )
        let menu = SpaceMenu.build(
            workspace: workspace,
            canDelete: count > 1,
            profileItem: profileMenuItem(for: workspace),
            actions: actions
        )
        if view.window != nil {
            let pointInView = view.convert(point, from: nil)
            menu.popUp(positioning: nil, at: pointInView, in: view)
        }
    }

    private func confirmDeleteWorkspace(id: UUID) {
        let alert = NSAlert()
        alert.messageText = "Delete Space"
        alert.informativeText = "This will delete the space and everything inside it."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            model.deleteWorkspace(id: id)
        }
    }

    /// The space bar, exposed for swipe gesture exclusion.
    var spaceBarView: NSView { spaceBar }

    /// The gear: opens Settings, or closes it when it is already shown.
    func toggleSettings() {
        if model.isSettingsShown {
            model.closeSettings()
        } else {
            model.showSettings()
        }
    }

    /// Esc closes Settings (field editors keep Esc for themselves while editing);
    /// otherwise it goes on up the responder chain.
    override func cancelOperation(_ sender: Any?) {
        if model.isSettingsShown {
            model.closeSettings()
        } else {
            nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
        }
    }

    /// ⌘⌥←: the previous space, with the space transition. Stops at the first
    /// space; does nothing in Settings.
    func navigateToPreviousWorkspace() {
        guard let id = adjacentSpaceId(step: -1) else { return }
        requestSpaceSwitch(to: id)
    }

    /// ⌘⌥→: the next space, with the space transition. Stops at the last space;
    /// does nothing in Settings.
    func navigateToNextWorkspace() {
        guard let id = adjacentSpaceId(step: 1) else { return }
        requestSpaceSwitch(to: id)
    }

    /// The space `step` places from the current one (-1 = previous), if any;
    /// nil in Settings.
    func adjacentSpaceId(step: Int) -> UUID? {
        guard !model.isSettingsShown else { return nil }
        let workspaces = model.workspaces
        guard let index = workspaces.firstIndex(where: { $0.id == model.currentWorkspace.id }),
              workspaces.indices.contains(index + step) else { return nil }
        return workspaces[index + step].id
    }

    func promptCreateWorkspace() {
        // The rename happens in the space header, which Settings hides.
        model.closeSettings()
        let workspaceId = model.createWorkspace(name: "Untitled Space", colorId: .randomColor())
        scheduleWorkspaceInlineRename(for: workspaceId)
    }

    private func scheduleWorkspaceInlineRename(for workspaceId: UUID) {
        pendingWorkspaceRenameId = workspaceId
    }

    /// Renames happen in the space header, so a space that isn't current is
    /// selected first and the rename starts after the reload.
    private func beginSpaceRename(_ workspaceId: UUID) {
        if workspaceId == model.currentWorkspace.id && !model.isSettingsShown {
            spaceHeader.beginInlineRename()
        } else {
            scheduleWorkspaceInlineRename(for: workspaceId)
            model.selectWorkspace(id: workspaceId)
        }
    }

    private func handlePendingWorkspaceRename() {
        guard let workspaceId = pendingWorkspaceRenameId else { return }
        pendingWorkspaceRenameId = nil

        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.currentWorkspace.id == workspaceId, !self.model.isSettingsShown else { return }
            self.spaceHeader.beginInlineRename()
        }
    }

    // MARK: - Node Management

    func createFolderAndBeginRename(parentId: UUID?) {
        if let parentId {
            model.setFolderExpanded(id: parentId, isExpanded: true)
        }
        let newId = model.addFolder(name: "Untitled", parentId: parentId)
        nodeListViewController.scheduleInlineRename(for: newId)
    }

    func createNoteAndBeginRename(parentId: UUID?) {
        if let parentId {
            model.setFolderExpanded(id: parentId, isExpanded: true)
        }
        let newId = model.addNote(title: "Untitled", parentId: parentId)
        nodeListViewController.scheduleInlineRename(for: newId)
    }

    private func openNote(_ note: Note) {
        guard let url = noteServer?.editorURL(noteId: note.id) else { return }
        // Notes open like the space's links: its profile's browser and browser profile.
        BrowserManager.open(url: url, target: BrowserManager.resolveTarget(link: nil, profile: model.currentProfile))
    }

    @objc func paste(_ sender: Any?) {
        pasteLink()
    }

    @objc private func pasteLink() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        pasteText(pasted)
    }

    func pasteText(_ pasted: String) {
        let urls = extractUrls(from: pasted)
        if !urls.isEmpty {
            for url in urls {
                let linkId = model.addLink(urlString: url.absoluteString, title: titleForUrl(url), parentId: nil)
                fetchTitleForNewLink(id: linkId, url: url)
            }
            return
        }
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.addNote(title: "Untitled", parentId: nil, content: trimmed)
    }

    private func linkById(_ id: UUID) -> Link? {
        guard let node = model.nodeById(id), case .link(let link) = node else { return nil }
        return link
    }

    private func showScheduledRowMenu(linkId: UUID, event: NSEvent) {
        let menu = NSMenu()

        let openItem = NSMenuItem(title: "Open Link", action: #selector(scheduledRowOpen(_:)), keyEquivalent: "")
        openItem.target = self
        openItem.representedObject = linkId
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let rescheduleItem = NSMenuItem(title: "Reschedule", action: nil, keyEquivalent: "")
        let rescheduleSubmenu = NSMenu()
        for preset in SchedulePresets.all {
            let item = NSMenuItem(title: preset.label, action: #selector(scheduledRowReschedule(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ScheduleMenuPayload(linkId: linkId, component: preset.component, value: preset.value)
            rescheduleSubmenu.addItem(item)
        }
        rescheduleItem.submenu = rescheduleSubmenu
        menu.addItem(rescheduleItem)

        menu.addItem(NSMenuItem.separator())

        let clearItem = NSMenuItem(title: "Clear Schedule", action: #selector(scheduledRowClear(_:)), keyEquivalent: "")
        clearItem.target = self
        clearItem.representedObject = linkId
        menu.addItem(clearItem)

        NSMenu.popUpContextMenu(menu, with: event, for: scheduledLinksAccordion)
    }

    @objc private func scheduledRowOpen(_ sender: NSMenuItem) {
        guard let linkId = sender.representedObject as? UUID,
              let link = linkById(linkId) else { return }
        openLink(link)
    }

    @objc private func scheduledRowReschedule(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ScheduleMenuPayload,
              let date = SchedulePresets.date(component: payload.component, value: payload.value) else { return }
        model.scheduleLink(id: payload.linkId, at: date)
    }

    @objc private func scheduledRowClear(_ sender: NSMenuItem) {
        guard let linkId = sender.representedObject as? UUID else { return }
        model.cancelSchedule(id: linkId)
    }

    /// Opens a new tab. Used by Open All Links, scheduled rows and menus.
    private func openLink(_ link: Link) {
        BrowserManager.open(link: link, in: model.currentProfile)
    }

    /// A click on a favorite or a list link: may focus an already open matching tab
    /// instead (favorites by default, list links with ⌥; see `TabFocus`).
    private func openClickedLink(_ link: Link, source: LinkClickSource) {
        TabFocusService.shared.open(
            link: link,
            in: model.currentProfile,
            allProfiles: model.profiles,
            source: source,
            invert: NSEvent.modifierFlags.contains(.option)
        )
    }

    // MARK: - URL Utilities

    private func normalizedUrl(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return BrowserManager.validatedLinkURL(from: trimmed)
        }

        if lower.hasPrefix("localhost") {
            return BrowserManager.validatedLinkURL(from: "http://\(trimmed)")
        }

        return nil
    }

    private func extractUrls(from text: String) -> [URL] {
        let pattern = #"(?i)\b(?:https?://[^\s<>"',;]+|localhost(?::\d+)?(?:/[^\s<>"',;]*)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var urls: [URL] = []

        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range,
                  let stringRange = Range(matchRange, in: text) else { return }
            let candidate = stripTrailingPunctuation(from: String(text[stringRange]))
            if let url = normalizedUrl(from: candidate) {
                urls.append(url)
            }
        }

        return urls
    }

    private func stripTrailingPunctuation(from value: String) -> String {
        var trimmed = value
        while let last = trimmed.last, ".,;:)]}?!".contains(last) {
            trimmed.removeLast()
        }
        return trimmed
    }

    private func titleForUrl(_ url: URL) -> String {
        if let host = url.host {
            return host
        }
        return url.absoluteString
    }

    private func fetchTitleForNewLink(id: UUID, url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        LinkTitleService.shared.fetchTitle(for: url, linkId: id) { [weak self] title in
            guard let self, let title else { return }
            _ = self.model.updateLinkTitleIfDefault(id: id, newTitle: title)
        }
    }

    @objc private func handleFaviconUpdate(_ notification: Notification) {
        guard let linkId = notification.userInfo?["linkId"] as? UUID,
              let path = notification.userInfo?["path"] as? String else { return }
        if model.pinnedLinkById(linkId) != nil {
            model.updatePinnedLinkFaviconPath(id: linkId, path: path)
        } else {
            model.updateLinkFaviconPath(id: linkId, path: path)
        }
    }

    // MARK: - Pinned Tabs

    private func showPinnedTabContextMenu(for linkId: UUID, at event: NSEvent) {
        let menu = NSMenu()
        let unpinItem = NSMenuItem(title: "Unpin", action: #selector(unpinTab(_:)), keyEquivalent: "")
        unpinItem.target = self
        unpinItem.representedObject = linkId
        menu.addItem(unpinItem)

        if let link = model.pinnedLinkById(linkId) {
            browserMenuItems(for: link).forEach { menu.addItem($0) }
        }

        menu.addItem(NSMenuItem.separator())

        let changeIcon = NSMenuItem(title: "Change Icon…", action: #selector(changePinnedTabIcon(_:)), keyEquivalent: "")
        changeIcon.target = self
        changeIcon.representedObject = linkId
        menu.addItem(changeIcon)

        NSMenu.popUpContextMenu(menu, with: event, for: pinnedTabsView)
    }

    // MARK: - Browser and profile menus

    /// "Open in ▸", "Always open in ▸" and, when the link's browser can report its
    /// tabs, "Match Exact URL", for a link or favorite of the current space.
    private func browserMenuItems(for link: Link) -> [NSMenuItem] {
        let browsers = BrowserManager.installedBrowsers()
        let profileBrowser = BrowserManager.resolveTarget(link: nil, profile: model.currentProfile).bundleId
        let openIn = BrowserMenus.openInItem(browsers: browsers) { [weak self] bundleId in
            guard let self else { return }
            var oneOff = link
            oneOff.browserBundleId = bundleId
            BrowserManager.open(link: oneOff, in: self.model.currentProfile)
        }
        let alwaysOpenIn = BrowserMenus.alwaysOpenInItem(
            browsers: browsers,
            current: link.browserBundleId,
            profileBrowserName: profileBrowser.flatMap { BrowserManager.appName(bundleId: $0) }
        ) { [weak self] bundleId in
            self?.model.setLinkBrowserOverride(id: link.id, bundleId: bundleId)
        }
        let target = BrowserManager.resolveTarget(link: link, profile: model.currentProfile)
        guard let browser = target.bundleId, TabLocators.isSupported(bundleId: browser) else {
            return [openIn, alwaysOpenIn]
        }
        let exactMatch = BrowserMenus.exactMatchItem(isOn: link.exactTabMatch ?? false) { [weak self] exact in
            self?.model.setLinkExactTabMatch(id: link.id, exact: exact)
        }
        return [openIn, alwaysOpenIn, exactMatch]
    }

    /// "Profile ▸" for a space: move it to another profile, or to a new one.
    private func profileMenuItem(for workspace: Workspace) -> NSMenuItem {
        BrowserMenus.profileItem(
            profiles: model.profiles,
            currentProfileId: workspace.profileId,
            assign: { [weak self] profileId in
                self?.model.assignWorkspace(workspace.id, toProfile: profileId)
            },
            newProfile: { [weak self] in
                guard let self,
                      let name = TextPrompt.run(
                        message: "New Profile",
                        informative: "“\(workspace.name)” will move to the new profile.",
                        initial: "Profile \(self.model.profiles.count + 1)",
                        confirmTitle: "Create"
                      ) else { return }
                let profileId = self.model.createProfile(name: name)
                self.model.assignWorkspace(workspace.id, toProfile: profileId)
            }
        )
    }

    @objc private func unpinTab(_ sender: NSMenuItem) {
        guard let linkId = sender.representedObject as? UUID else { return }
        model.unpinLink(id: linkId)
    }

    @objc private func changePinnedTabIcon(_ sender: NSMenuItem) {
        guard let linkId = sender.representedObject as? UUID,
              let link = model.pinnedLinkById(linkId) else { return }
        // Find the tile view for this pinned link
        let anchorView = pinnedTabsView.tileView(for: linkId) ?? pinnedTabsView
        showIconPicker(for: linkId, relativeTo: anchorView, hasCustomIcon: link.customIcon != nil, kind: .pinnedLink)
    }

    enum IconPickerKind {
        case link
        case pinnedLink
        case note
        /// A space's icon: emoji or SF Symbol only; "Remove Icon" goes back to the colour dot.
        case space
    }

    private func showIconPicker(for nodeId: UUID, relativeTo anchorView: NSView, hasCustomIcon: Bool, kind: IconPickerKind) {
        let popover = NSPopover()
        let pickerController = IconPickerPopoverController()
        pickerController.showRestoreButton = hasCustomIcon
        if kind == .space {
            pickerController.allowsFavicons = false
            pickerController.restoreButtonTitle = "Remove Icon"
        }

        let applyIcon: (CustomIcon?) -> Void = { [weak self] icon in
            guard let self else { return }
            switch kind {
            case .link:
                self.model.setLinkCustomIcon(id: nodeId, icon: icon)
            case .pinnedLink:
                self.model.setPinnedLinkCustomIcon(id: nodeId, icon: icon)
            case .note:
                self.model.setNoteCustomIcon(id: nodeId, icon: icon)
            case .space:
                self.model.setWorkspaceIcon(id: nodeId, icon: icon)
            }
        }

        pickerController.onIconSelected = { [weak popover] icon in
            applyIcon(icon)
            popover?.close()
        }

        pickerController.onRestoreFavicon = { [weak popover] in
            applyIcon(nil)
            popover?.close()
        }

        pickerController.onFaviconPathSelected = { [weak popover] path in
            applyIcon(.cachedFavicon(path))
            popover?.close()
        }

        popover.contentViewController = pickerController
        popover.contentSize = NSSize(width: 280, height: 320)
        popover.behavior = .transient
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
    }

    // MARK: - Bulk Operations

    private func handleBulkCopyLinks(_ nodeIds: [UUID]) {
        let nodes = nodeIds.compactMap { id in
            model.findNode(id: id, in: model.currentWorkspace.items)
        }
        let urls = nodes.compactMap { node -> String? in
            if case .link(let link) = node {
                return link.url
            }
            return nil
        }

        guard !urls.isEmpty else { return }

        let joined = urls.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
    }
}
