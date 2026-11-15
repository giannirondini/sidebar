import Foundation
import os

final class AppModel {
    private let store: DataStore
    let noteStorage: NoteStorage
    private(set) var state: AppState
    var onChange: (() -> Void)?
    var onSaveFailure: (() -> Void)?
    /// Whether the Settings page is shown instead of the current space. Runtime
    /// state only: not saved, so the app always starts on a space. The selected
    /// space is kept while Settings is shown, and closing Settings returns to it.
    private(set) var isSettingsShown = false
    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "model")

    /// Where the last selected space is remembered. Tests pass their own suite.
    private let defaults: UserDefaults

    init(store: DataStore = DataStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        self.noteStorage = NoteStorage(store: store)
        self.state = store.load()

        if let savedId = defaults.string(forKey: UserDefaultsKeys.lastSelectedWorkspaceId),
           let uuid = UUID(uuidString: savedId),
           state.workspaces.contains(where: { $0.id == uuid }) {
            state.selectedWorkspaceId = uuid
        }
        if state.selectedWorkspaceId == nil {
            state.selectedWorkspaceId = state.workspaces.first?.id
        }
    }

    var dataLoadIssue: DataStore.LoadIssue? { store.loadIssue }
    var dataFileURL: URL { store.dataFileURL }

    /// Deletes favicon files with the old `<host>.ico` names that nothing in the
    /// library uses any more (re-fetched favicons are saved under hashed names).
    /// Never while a library may need its icons back: not when this load failed
    /// (the state is a stand-in, every file would look unused), and not while a
    /// library preserved by "Start Empty Library" (`data.unreadable-*.json`) is
    /// still beside data.json, on any later launch. Returns how many were removed.
    @discardableResult
    func removeUnusedLegacyFavicons() -> Int {
        guard store.loadIssue == nil else { return 0 }
        let fileManager = FileManager.default
        let baseDirectory = store.dataFileURL.deletingLastPathComponent()
        let siblings = (try? fileManager.contentsOfDirectory(atPath: baseDirectory.path)) ?? []
        guard !siblings.contains(where: { $0.hasPrefix("data.unreadable-") }) else { return 0 }
        let referenced = DataTransfer.referencedIconFileNames(in: state)
        let icons = store.iconsDirectory()
        let names = (try? fileManager.contentsOfDirectory(atPath: icons.path)) ?? []
        var removed = 0
        for name in names where FaviconService.isLegacyCacheFileName(name) && !referenced.contains(name) {
            do {
                try fileManager.removeItem(at: icons.appendingPathComponent(name))
                removed += 1
            } catch {
                logger.error("Could not remove an unused favicon: \(error.localizedDescription, privacy: .public)")
            }
        }
        if removed > 0 {
            logger.info("Removed \(removed) unused legacy favicon files")
        }
        return removed
    }

    func startEmptyLibrary() throws -> URL {
        let empty = DataStore.defaultState()
        let preserved = try store.startEmptyLibrary(with: empty)
        state = empty
        return preserved
    }

    var workspaces: [Workspace] {
        state.workspaces
    }

    var currentWorkspace: Workspace {
        if let selected = state.selectedWorkspaceId,
           let workspace = state.workspaces.first(where: { $0.id == selected }) {
            return workspace
        }
        if let first = state.workspaces.first {
            return first
        }
        state = state.repaired()
        let fallback = Workspace(id: UUID(), name: "Inbox", colorId: .defaultColor(), items: [], profileId: state.profiles[0].id)
        state.workspaces = [fallback]
        state.selectedWorkspaceId = fallback.id
        persist()
        return fallback
    }

    // MARK: - Profiles

    var profiles: [Profile] {
        state.profiles
    }

    /// The profile of the current workspace (its browser setup and Favorites).
    var currentProfile: Profile {
        profile(for: currentWorkspace)
    }

    /// `state` is repaired on load, so a workspace's profile always exists; the
    /// first-profile fallback only covers states built in memory without `repaired()`.
    func profile(for workspace: Workspace) -> Profile {
        state.profiles.first(where: { $0.id == workspace.profileId })
            ?? state.profiles.first
            ?? Profile.makeDefault()
    }

    func profile(id: UUID) -> Profile? {
        state.profiles.first(where: { $0.id == id })
    }

    func workspaces(inProfile id: UUID) -> [Workspace] {
        state.workspaces.filter { $0.profileId == id }
    }

    @discardableResult
    func createProfile(name: String) -> UUID {
        let profile = Profile(name: name)
        state.profiles.append(profile)
        persist()
        return profile.id
    }

    func renameProfile(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateProfile(id: id) { $0.name = trimmed }
    }

    /// Sets the browser for every space in the profile; `nil` inherits the global default.
    func setProfileBrowser(id: UUID, bundleId: String?) {
        updateProfile(id: id) { $0.browserBundleId = bundleId }
    }

    /// Turns tab focusing on or off for the profile; `nil` restores the automatic
    /// default (see `Profile.focusesOpenTabs`).
    func setProfileFocusesOpenTabs(id: UUID, enabled: Bool?) {
        updateProfile(id: id) { $0.focusesOpenTabs = enabled }
    }

    func assignWorkspace(_ workspaceId: UUID, toProfile profileId: UUID) {
        guard state.profiles.contains(where: { $0.id == profileId }) else { return }
        updateWorkspace(id: workspaceId) { $0.profileId = profileId }
    }

    /// The profile that receives the spaces and favorites of `id` when it is
    /// deleted: the first remaining profile. `nil` when `id` is the last one.
    func profileDeletionTarget(for id: UUID) -> Profile? {
        guard state.profiles.contains(where: { $0.id == id }) else { return nil }
        return state.profiles.first(where: { $0.id != id })
    }

    /// Deletes a profile. Its spaces move to `profileDeletionTarget(for:)` and its
    /// favorites are merged into that profile's (deduplicated, capped). Favorites
    /// that don't fit go into a "Favorites (from <name>)" folder at the top of the
    /// first moved space (or the target's first space), so nothing is lost.
    /// The last profile can't be deleted.
    func deleteProfile(id: UUID) {
        guard let target = profileDeletionTarget(for: id),
              let deletedIndex = state.profiles.firstIndex(where: { $0.id == id }),
              let targetIndex = state.profiles.firstIndex(where: { $0.id == target.id }) else { return }

        var next = state
        let deleted = next.profiles[deletedIndex]
        let movedSpaceIndices = next.workspaces.indices.filter { next.workspaces[$0].profileId == id }
        for index in movedSpaceIndices {
            next.workspaces[index].profileId = target.id
        }

        let leftovers = next.profiles[targetIndex].appendFavorites(deleted.favorites)
        if !leftovers.isEmpty {
            // No space to hold them (no workspaces at all): refuse rather than drop links.
            guard let spaceIndex = movedSpaceIndices.first
                    ?? next.workspaces.firstIndex(where: { $0.profileId == target.id })
                    ?? next.workspaces.indices.first else { return }
            let folder = Folder(
                id: UUID(),
                name: "Favorites (from \(deleted.name))",
                children: leftovers.map { .link($0) },
                isExpanded: true
            )
            next.workspaces[spaceIndex].items.insert(.folder(folder), at: 0)
        }

        next.profiles.remove(at: deletedIndex)
        state = next
        persist()
    }

    static let arcFavoritesFolderName = "Favorites (from Arc)"

    /// Adds the spaces and favorites of an Arc import, in one mutation.
    ///
    /// Each Arc profile maps to the fork profile with the same name (Arc's default
    /// profile → "Default"), or to a new profile with that name. Spaces without an
    /// Arc profile join the current space's profile. Favorites are merged into the
    /// mapped profile (deduplicated, capped); those that don't fit go into a
    /// "Favorites (from Arc)" folder at the top of that profile's first imported
    /// space (or its first space), so nothing is dropped. Selection is unchanged.
    func applyArcImport(_ result: ArcImportResult) {
        var next = state.repaired()
        let fallbackProfileId = profile(for: currentWorkspace).id
        var profileIdByArcKey: [String: UUID] = [:]
        var firstImportedSpaceByProfile: [UUID: UUID] = [:]

        func profileId(for arcProfile: ArcProfileKey?) -> UUID {
            guard let arcProfile else { return fallbackProfileId }
            if let known = profileIdByArcKey[arcProfile.key] { return known }
            let id: UUID
            if let existing = next.profiles.first(where: { $0.name.caseInsensitiveCompare(arcProfile.name) == .orderedSame }) {
                id = existing.id
            } else {
                let created = Profile(name: arcProfile.name)
                next.profiles.append(created)
                id = created.id
            }
            profileIdByArcKey[arcProfile.key] = id
            return id
        }

        for imported in result.workspaces {
            let pid = profileId(for: imported.arcProfile)
            let workspace = Workspace(id: UUID(), name: imported.name, colorId: imported.colorId, items: imported.nodes, profileId: pid)
            next.workspaces.append(workspace)
            if firstImportedSpaceByProfile[pid] == nil {
                firstImportedSpaceByProfile[pid] = workspace.id
            }
        }

        for imported in result.profiles where !imported.favorites.isEmpty {
            let pid = profileId(for: imported.arcProfile)
            guard let profileIndex = next.profiles.firstIndex(where: { $0.id == pid }) else { continue }
            let leftovers = next.profiles[profileIndex].appendFavorites(imported.favorites)
            guard !leftovers.isEmpty else { continue }
            let targetSpaceId = firstImportedSpaceByProfile[pid]
                ?? next.workspaces.first(where: { $0.profileId == pid })?.id
                ?? next.workspaces.first?.id
            guard let spaceIndex = next.workspaces.firstIndex(where: { $0.id == targetSpaceId }) else {
                // No space at all to hold them: keep the state unchanged rather than drop links.
                return
            }
            let folder = Folder(id: UUID(), name: Self.arcFavoritesFolderName, children: leftovers.map { .link($0) }, isExpanded: true)
            next.workspaces[spaceIndex].items.insert(.folder(folder), at: 0)
        }

        state = next
        persist()
    }

    func applyChromeImport(_ workspace: ImportWorkspace) {
        let imported = Workspace(id: UUID(), name: workspace.name, colorId: workspace.colorId,
                                 items: workspace.nodes, profileId: currentProfile.id)
        state.workspaces.append(imported)
        state.selectedWorkspaceId = imported.id
        defaults.set(imported.id.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        persist()
    }

    // MARK: - Data export and import

    /// Writes an export folder of the saved data inside `parent` (`DataTransfer.export`).
    /// Every mutation is saved right away, so `data.json` is the current state.
    func exportData(to parent: URL, appVersion: String?) throws -> URL {
        try DataTransfer.export(store: store, to: parent, appVersion: appVersion)
    }


    /// Replaces all data with a validated export (`DataTransfer.readPackage`), in one
    /// mutation. Order: back up the raw current data in `Backups/pre-import-<ts>/`
    /// (nothing changes if that fails), stage and copy the export's notes and icons,
    /// point icon paths at this Mac's `Icons/`, then replace the state. A later
    /// copy or save failure reports the backup because some files may have changed.
    /// Selects the export's selected space
    /// (or the first). Returns the backup.
    @discardableResult
    func applyDataImport(_ package: DataTransfer.Package) throws -> URL {
        guard store.loadIssue == nil else {
            throw DataTransfer.TransferError.fileOperationFailed("The current library could not be opened and must be preserved before importing.")
        }
        let destination = store.preImportBackupDestination()
        let backup: URL
        do {
            backup = try DataTransfer.backupForImport(store: store, to: destination.parent, baseName: destination.name)
        } catch {
            throw DataTransfer.TransferError.fileOperationFailed("Backing up the current data failed: \(error.localizedDescription)")
        }
        do {
            try DataTransfer.copyFiles(from: package, into: store)
        } catch {
            throw DataTransfer.TransferError.fileOperationFailed("Import could not copy all files. Some notes or icons may have changed. The previous data is in \(backup.path). \(error.localizedDescription)")
        }
        var next = DataTransfer.remapIconPaths(in: package.state, iconsDirectory: store.iconsDirectory()).repaired()
        if next.workspaces.isEmpty {
            next.workspaces = [Workspace(id: UUID(), name: "Inbox", colorId: .defaultColor(), items: [], profileId: next.profiles[0].id)]
        }
        if !next.workspaces.contains(where: { $0.id == next.selectedWorkspaceId }) {
            next.selectedWorkspaceId = next.workspaces[0].id
        }
        guard store.save(next) else {
            throw DataTransfer.TransferError.fileOperationFailed("Import could not save the new library. Some notes or icons may have changed. The previous data is in \(backup.path).")
        }
        if let selected = next.selectedWorkspaceId {
            defaults.set(selected.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        }
        state = next
        onChange?()
        logger.info("Imported data from an export; previous data backed up to \(backup.lastPathComponent, privacy: .public)")
        return backup
    }

    /// Sets or clears (nil) the per-link browser override, for a link in any
    /// space's list or in any profile's favorites.
    func setLinkBrowserOverride(id: UUID, bundleId: String?) {
        if favoriteLocation(id: id) != nil {
            updateFavorite(id: id) { $0.browserBundleId = bundleId }
            return
        }
        updateNode(id: id) { node in
            if case .link(var link) = node {
                link.browserBundleId = bundleId
                node = .link(link)
            }
        }
    }

    /// Sets "Match Exact URL" for a link in any space's list or any profile's
    /// favorites. `false` is stored as nil, the default.
    func setLinkExactTabMatch(id: UUID, exact: Bool) {
        let value: Bool? = exact ? true : nil
        if favoriteLocation(id: id) != nil {
            updateFavorite(id: id) { $0.exactTabMatch = value }
            return
        }
        updateNode(id: id) { node in
            if case .link(var link) = node {
                link.exactTabMatch = value
                node = .link(link)
            }
        }
    }

    func selectWorkspace(id: UUID) {
        guard state.workspaces.contains(where: { $0.id == id }) else { return }
        state.selectedWorkspaceId = id
        isSettingsShown = false
        defaults.set(id.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        persist()
    }

    /// Shows Settings in place of the current space (nothing is saved).
    func showSettings() {
        guard !isSettingsShown else { return }
        isSettingsShown = true
        onChange?()
    }

    /// Leaves Settings and returns to the space that was selected.
    func closeSettings() {
        guard isSettingsShown else { return }
        isSettingsShown = false
        onChange?()
    }

    @discardableResult
    func createWorkspace(name: String, colorId: WorkspaceColorId) -> UUID {
        // A new space joins the current space's profile.
        let workspace = Workspace(id: UUID(), name: name, colorId: colorId, items: [], profileId: currentProfile.id)
        state.workspaces.append(workspace)
        state.selectedWorkspaceId = workspace.id
        defaults.set(workspace.id.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
        persist()
        return workspace.id
    }

    func renameWorkspace(id: UUID, newName: String) {
        updateWorkspace(id: id) { workspace in
            workspace.name = newName
        }
    }

    /// Sets a preset colour; clears a custom colour.
    func updateWorkspaceColor(id: UUID, colorId: WorkspaceColorId) {
        updateWorkspace(id: id) { workspace in
            workspace.colorId = colorId
            workspace.customColor = nil
        }
    }

    /// Sets (or clears, nil) the space's custom colour; `colorId` stays as the fallback.
    func setWorkspaceCustomColor(id: UUID, color: SpaceColor?) {
        guard let workspace = state.workspaces.first(where: { $0.id == id }),
              workspace.customColor != color else { return }
        updateWorkspace(id: id) { $0.customColor = color }
    }

    /// Sets the space's icon; `nil` goes back to the colour dot.
    func setWorkspaceIcon(id: UUID, icon: CustomIcon?) {
        updateWorkspace(id: id) { workspace in
            workspace.icon = icon
        }
    }

    /// Sets (or clears, for nil/blank) the browser profile directory that `profileId`
    /// uses for `bundleId`. Affects every space in that profile.
    func updateBrowserProfile(profileId: UUID, bundleId: String, profile: String?) {
        let trimmed = profile?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        updateProfile(id: profileId) { profile in
            if let value {
                profile.browserProfiles[bundleId] = value
            } else {
                profile.browserProfiles.removeValue(forKey: bundleId)
            }
        }
    }

    func deleteWorkspace(id: UUID) {
        guard state.workspaces.count > 1,
              let index = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        let previous = state
        let removed = state.workspaces.remove(at: index)
        if state.selectedWorkspaceId == id {
            state.selectedWorkspaceId = state.workspaces.first?.id
        }
        if persist(notify: false) {
            if let newId = state.selectedWorkspaceId {
                defaults.set(newId.uuidString, forKey: UserDefaultsKeys.lastSelectedWorkspaceId)
            }
            removed.items.forEach { cleanupFiles(for: $0) }
        } else {
            state = previous
        }
        onChange?()
    }

    func moveWorkspace(id: UUID, direction: WorkspaceMoveDirection) {
        guard let currentIndex = state.workspaces.firstIndex(where: { $0.id == id }) else { return }

        let newIndex: Int
        switch direction {
        case .left:
            guard currentIndex > 0 else { return }
            newIndex = currentIndex - 1
        case .right:
            guard currentIndex < state.workspaces.count - 1 else { return }
            newIndex = currentIndex + 1
        }

        let workspace = state.workspaces.remove(at: currentIndex)
        state.workspaces.insert(workspace, at: newIndex)
        persist()
    }

    func reorderWorkspace(id: UUID, toIndex: Int) {
        guard let currentIndex = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        guard toIndex >= 0 && toIndex < state.workspaces.count else { return }
        guard currentIndex != toIndex else { return }

        let workspace = state.workspaces.remove(at: currentIndex)
        state.workspaces.insert(workspace, at: toIndex)
        persist()
    }

    @discardableResult
    func addFolder(name: String, parentId: UUID?, isExpanded: Bool = true) -> UUID {
        guard let id = addFolder(name: name, workspaceId: currentWorkspace.id, parentId: parentId, isExpanded: isExpanded) else {
            preconditionFailure("currentWorkspace is missing from state.workspaces")
        }
        return id
    }

    @discardableResult
    func addFolder(name: String, workspaceId: UUID, parentId: UUID?, isExpanded: Bool = true) -> UUID? {
        guard state.workspaces.contains(where: { $0.id == workspaceId }) else { return nil }
        let folder = Folder(id: UUID(), name: name, children: [], isExpanded: isExpanded)
        updateWorkspace(id: workspaceId) { workspace in
            insertNode(.folder(folder), parentId: parentId, index: nil, nodes: &workspace.items)
        }
        return folder.id
    }

    @discardableResult
    /// Adds to the current space. The caller validates the URL first
    /// (`BrowserManager.validatedLinkURL`); an invalid one is a programming error.
    func addLink(urlString: String, title: String, parentId: UUID?) -> UUID {
        guard let id = addLink(urlString: urlString, title: title, workspaceId: currentWorkspace.id, parentId: parentId) else {
            preconditionFailure("addLink: invalid URL, or currentWorkspace is missing from state.workspaces")
        }
        return id
    }

    @discardableResult
    func addLink(urlString: String, title: String, workspaceId: UUID, parentId: UUID?) -> UUID? {
        guard state.workspaces.contains(where: { $0.id == workspaceId }),
              BrowserManager.validatedLinkURL(from: urlString) != nil else { return nil }
        let link = Link(id: UUID(), title: title, url: urlString, faviconPath: nil)
        updateWorkspace(id: workspaceId) { workspace in
            insertNode(.link(link), parentId: parentId, index: nil, nodes: &workspace.items)
        }
        logger.debug("Added link \(title, privacy: .public) -> \(urlString, privacy: .public)")
        return link.id
    }

    @discardableResult
    func addNote(title: String, parentId: UUID?, content: String = "") -> UUID {
        guard let id = addNote(title: title, workspaceId: currentWorkspace.id, parentId: parentId, content: content) else {
            preconditionFailure("currentWorkspace is missing from state.workspaces")
        }
        return id
    }

    @discardableResult
    func addNote(title: String, workspaceId: UUID, parentId: UUID?, content: String = "") -> UUID? {
        guard state.workspaces.contains(where: { $0.id == workspaceId }) else { return nil }
        let note = Note(id: UUID(), title: title, customIcon: nil)
        try? noteStorage.write(id: note.id, content: content)
        updateWorkspace(id: workspaceId) { workspace in
            insertNode(.note(note), parentId: parentId, index: nil, nodes: &workspace.items)
        }
        return note.id
    }

    func renameNode(id: UUID, newName: String) {
        updateNode(id: id) { node in
            switch node {
            case .folder(var folder):
                folder.name = newName
                node = .folder(folder)
            case .link(var link):
                link.title = newName
                node = .link(link)
            case .note(var note):
                note.title = newName
                node = .note(note)
            }
        }
    }

    @discardableResult
    func deleteNode(id: UUID) -> Bool {
        guard let wsId = workspaceIdContaining(nodeId: id) else { return false }
        let previous = state
        guard let index = state.workspaces.firstIndex(where: { $0.id == wsId }),
              let node = removeNode(id: id, nodes: &state.workspaces[index].items) else { return false }
        let saved = persist(notify: false)
        if saved {
            cleanupFiles(for: node)
        } else {
            state = previous
        }
        onChange?()
        return saved
    }

    private func cleanupFiles(for node: Node) {
        switch node {
        case .note(let note):
            noteStorage.delete(id: note.id)
        case .link:
            // Favicons are cached per host and shared across every link to
            // that host, so deleting one link must not remove the file.
            break
        case .folder(let folder):
            for child in folder.children {
                cleanupFiles(for: child)
            }
        }
    }

    @discardableResult
    func moveNode(id: UUID, toParentId: UUID?, index: Int) -> Bool {
        guard let sourceWsId = workspaceIdContaining(nodeId: id),
              let sourceWs = state.workspaces.first(where: { $0.id == sourceWsId }),
              let location = findNodeLocation(id: id, nodes: sourceWs.items) else { return false }
        if let toParentId {
            guard case .folder? = findNode(id: toParentId, in: sourceWs.items),
                  !isDescendant(nodeId: toParentId, ofAncestor: id, in: sourceWs.items) else { return false }
        }

        updateWorkspace(id: sourceWsId) { workspace in
            guard let removedNode = removeNode(id: id, nodes: &workspace.items) else { return }

            var targetIndex = max(0, index)
            if location.parentId == toParentId, location.index < targetIndex {
                targetIndex -= 1
            }
            insertNode(removedNode, parentId: toParentId, index: targetIndex, nodes: &workspace.items)
        }
        return true
    }

    func moveNodeToWorkspace(id: UUID, workspaceId: UUID) {
        moveNodeToWorkspace(id: id, workspaceId: workspaceId, parentId: nil, index: nil)
    }

    func moveNodeToWorkspace(id: UUID, workspaceId: UUID, parentId: UUID?, index: Int?) {
        guard state.workspaces.contains(where: { $0.id == workspaceId }) else { return }
        guard let sourceWsId = workspaceIdContaining(nodeId: id) else { return }
        guard sourceWsId != workspaceId else {
            // Same-workspace move — delegate to moveNode if a target was provided.
            if let index {
                moveNode(id: id, toParentId: parentId, index: index)
            }
            return
        }
        if let parentId {
            guard let destWs = state.workspaces.first(where: { $0.id == workspaceId }),
                  case .folder? = findNode(id: parentId, in: destWs.items) else { return }
        }

        guard let sourceIndex = state.workspaces.firstIndex(where: { $0.id == sourceWsId }),
              let destIndex = state.workspaces.firstIndex(where: { $0.id == workspaceId }),
              let node = removeNode(id: id, nodes: &state.workspaces[sourceIndex].items) else { return }
        insertNode(node, parentId: parentId, index: index, nodes: &state.workspaces[destIndex].items)
        persist()
    }

    func setFolderExpanded(id: UUID, isExpanded: Bool) {
        updateNode(id: id) { node in
            switch node {
            case .folder(var folder):
                folder.isExpanded = isExpanded
                node = .folder(folder)
            case .link, .note:
                break
            }
        }
    }

    func updateLinkFaviconPath(id: UUID, path: String?) {
        if let node = nodeById(id), case .link(let link) = node, link.faviconPath == path {
            return
        }
        updateNode(id: id) { node in
            switch node {
            case .link(var link):
                link.faviconPath = path
                node = .link(link)
            case .folder, .note:
                break
            }
        }
    }

    func scheduleLink(id: UUID, at date: Date) {
        updateNode(id: id) { node in
            if case .link(var link) = node {
                link.scheduledOpenAt = date
                node = .link(link)
            }
        }
    }

    func cancelSchedule(id: UUID) {
        updateNode(id: id) { node in
            if case .link(var link) = node {
                link.scheduledOpenAt = nil
                node = .link(link)
            }
        }
    }

    func allScheduledLinks() -> [ScheduledLinkRef] {
        var result: [ScheduledLinkRef] = []
        for workspace in state.workspaces {
            collectScheduled(in: workspace.items, workspaceId: workspace.id, into: &result)
        }
        return result
    }

    func scheduledLinks(in workspaceId: UUID) -> [ScheduledLinkEntry] {
        guard let workspace = state.workspaces.first(where: { $0.id == workspaceId }) else { return [] }
        var result: [ScheduledLinkEntry] = []
        collectScheduledEntries(in: workspace.items, into: &result)
        return result
    }

    private func collectScheduledEntries(in nodes: [Node], into result: inout [ScheduledLinkEntry]) {
        for node in nodes {
            switch node {
            case .link(let link):
                if let fireAt = link.scheduledOpenAt {
                    result.append(ScheduledLinkEntry(link: link, fireAt: fireAt))
                }
            case .folder(let folder):
                collectScheduledEntries(in: folder.children, into: &result)
            case .note:
                break
            }
        }
    }

    private func collectScheduled(in nodes: [Node], workspaceId: UUID, into result: inout [ScheduledLinkRef]) {
        for node in nodes {
            switch node {
            case .link(let link):
                if let fireAt = link.scheduledOpenAt {
                    result.append(ScheduledLinkRef(workspaceId: workspaceId, linkId: link.id, url: link.url, fireAt: fireAt))
                }
            case .folder(let folder):
                collectScheduled(in: folder.children, workspaceId: workspaceId, into: &result)
            case .note:
                break
            }
        }
    }

    @discardableResult
    func updateLinkUrl(id: UUID, newUrl: String) -> Bool {
        let trimmed = newUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BrowserManager.validatedLinkURL(from: trimmed) != nil,
              let node = nodeAcrossWorkspaces(id: id),
              case .link = node else { return false }
        updateNode(id: id) { node in
            switch node {
            case .link(var link):
                link.url = trimmed
                link.faviconPath = nil
                node = .link(link)
            case .folder, .note:
                break
            }
        }
        return true
    }

    func updateLinkTitleIfDefault(id: UUID, newTitle: String) -> Bool {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let node = nodeById(id), case .link(let link) = node else { return false }
        let defaultTitle = URL(string: link.url)?.host ?? link.url
        guard link.title == defaultTitle else { return false }
        guard link.title != trimmed else { return false }

        updateNode(id: id) { node in
            switch node {
            case .link(var link):
                link.title = trimmed
                node = .link(link)
            case .folder, .note:
                break
            }
        }
        logger.debug("Updated title for \(link.url, privacy: .public) -> \(trimmed, privacy: .public)")
        return true
    }

    // MARK: - Favorites (pinned links, shared per profile)

    var canPinMore: Bool {
        currentProfile.favorites.count < Profile.maxFavorites
    }

    func pinnedLinkById(_ id: UUID) -> Link? {
        currentProfile.favorites.first(where: { $0.id == id })
    }

    /// Moves a link from the current space's list into its profile's Favorites.
    /// Its scheduled reminder is cancelled: the scheduler only watches space lists,
    /// so it would never fire as a favorite and would fire at once, overdue, if
    /// the link were unpinned later.
    func pinLink(id: UUID) {
        guard canPinMore else { return }
        guard let node = nodeById(id), case .link(var link) = node else { return }
        link.scheduledOpenAt = nil
        let profileId = currentProfile.id
        guard let profileIndex = state.profiles.firstIndex(where: { $0.id == profileId }),
              let workspaceIndex = state.workspaces.firstIndex(where: { $0.id == currentWorkspace.id }),
              !state.profiles[profileIndex].favorites.contains(where: { $0.id == id }) else { return }

        _ = removeNode(id: id, nodes: &state.workspaces[workspaceIndex].items)
        state.profiles[profileIndex].favorites.append(link)
        persist()
    }

    /// Moves a favorite into the **current** space's list (as in Arc), whichever
    /// space it was pinned from.
    func unpinLink(id: UUID) {
        guard currentProfile.favorites.contains(where: { $0.id == id }) else { return }
        unpinFavorite(id: id, toWorkspaceId: currentWorkspace.id)
    }

    /// Moves the favorite `id` (from any profile) to the root of `workspaceId`'s list.
    @discardableResult
    func unpinFavorite(id: UUID, toWorkspaceId workspaceId: UUID) -> Bool {
        guard let (profileIndex, favoriteIndex) = favoriteLocation(id: id),
              let workspaceIndex = state.workspaces.firstIndex(where: { $0.id == workspaceId }) else { return false }
        var link = state.profiles[profileIndex].favorites.remove(at: favoriteIndex)
        // A favorite has no reminder; one left over from before it was pinned is stale.
        link.scheduledOpenAt = nil
        state.workspaces[workspaceIndex].items.append(.link(link))
        persist()
        return true
    }

    enum AddFavoriteError: Error, Equatable {
        case profileNotFound
        case invalidURL
        case full
        /// A favorite with the same normalised URL exists in that profile.
        case duplicate(existingId: UUID)
    }

    /// Adds a new link straight to a profile's Favorites.
    func addFavorite(profileId: UUID, urlString: String, title: String) -> Result<UUID, AddFavoriteError> {
        guard BrowserManager.validatedLinkURL(from: urlString) != nil else {
            return .failure(.invalidURL)
        }
        guard let profileIndex = state.profiles.firstIndex(where: { $0.id == profileId }) else {
            return .failure(.profileNotFound)
        }
        let key = URLNormalization.key(for: urlString)
        if let existing = state.profiles[profileIndex].favorites.first(where: { URLNormalization.key(for: $0.url) == key }) {
            return .failure(.duplicate(existingId: existing.id))
        }
        guard state.profiles[profileIndex].favorites.count < Profile.maxFavorites else {
            return .failure(.full)
        }
        let link = Link(id: UUID(), title: title, url: urlString, faviconPath: nil)
        state.profiles[profileIndex].favorites.append(link)
        persist()
        return .success(link.id)
    }

    @discardableResult
    func deleteFavorite(id: UUID) -> Bool {
        guard let (profileIndex, favoriteIndex) = favoriteLocation(id: id) else { return false }
        state.profiles[profileIndex].favorites.remove(at: favoriteIndex)
        persist()
        return true
    }

    /// Moves a favorite within its profile's grid; `index` is clamped.
    @discardableResult
    func moveFavorite(id: UUID, toIndex index: Int) -> Bool {
        guard let (profileIndex, favoriteIndex) = favoriteLocation(id: id) else { return false }
        let link = state.profiles[profileIndex].favorites.remove(at: favoriteIndex)
        let target = max(0, min(index, state.profiles[profileIndex].favorites.count))
        state.profiles[profileIndex].favorites.insert(link, at: target)
        persist()
        return true
    }

    /// Profile containing the favorite `id`, if any.
    func profileId(forFavoriteId id: UUID) -> UUID? {
        favoriteLocation(id: id).map { state.profiles[$0.0].id }
    }

    private func favoriteLocation(id: UUID) -> (Int, Int)? {
        for (profileIndex, profile) in state.profiles.enumerated() {
            if let favoriteIndex = profile.favorites.firstIndex(where: { $0.id == id }) {
                return (profileIndex, favoriteIndex)
            }
        }
        return nil
    }

    func updatePinnedLinkFaviconPath(id: UUID, path: String?) {
        updateFavorite(id: id) { $0.faviconPath = path }
    }

    func setLinkCustomIcon(id: UUID, icon: CustomIcon?) {
        updateNode(id: id) { node in
            switch node {
            case .link(var link):
                link.customIcon = icon
                node = .link(link)
            case .folder, .note:
                break
            }
        }
    }

    func setNoteCustomIcon(id: UUID, icon: CustomIcon?) {
        updateNode(id: id) { node in
            switch node {
            case .note(var note):
                note.customIcon = icon
                node = .note(note)
            case .folder, .link:
                break
            }
        }
    }

    func setPinnedLinkCustomIcon(id: UUID, icon: CustomIcon?) {
        updateFavorite(id: id) { $0.customIcon = icon }
    }

    func location(of nodeId: UUID) -> NodeLocation? {
        findNodeLocation(id: nodeId, nodes: currentWorkspace.items)
    }

    func location(of nodeId: UUID, in workspaceId: UUID) -> NodeLocation? {
        guard let workspace = state.workspaces.first(where: { $0.id == workspaceId }) else { return nil }
        return findNodeLocation(id: nodeId, nodes: workspace.items)
    }

    func nodeById(_ id: UUID) -> Node? {
        nodeById(id, nodes: currentWorkspace.items)
    }

    func nodeAcrossWorkspaces(id: UUID) -> Node? {
        for workspace in state.workspaces {
            if let node = nodeById(id, nodes: workspace.items) {
                return node
            }
        }
        return nil
    }

    func workspaceId(forNodeId id: UUID) -> UUID? {
        workspaceIdContaining(nodeId: id)
    }

    func findNode(id: UUID, in nodes: [Node]) -> Node? {
        for node in nodes {
            if node.id == id {
                return node
            }
            if case .folder(let folder) = node,
               let found = findNode(id: id, in: folder.children) {
                return found
            }
        }
        return nil
    }

    // MARK: - Bulk selection

    /// The selected nodes of the current space, in list order (a selection is a
    /// `Set`; its order must never matter). With `includingDescendantsOfSelected`
    /// false, a node whose ancestor is also selected is left out: it travels with
    /// that ancestor. Ids that aren't in the space are ignored. Every bulk action
    /// (move, group, delete, open, copy) goes through here.
    func selectedNodes(_ ids: some Collection<UUID>, includingDescendantsOfSelected: Bool = false) -> [Node] {
        let selected = Set(ids)
        var result: [Node] = []
        func walk(_ nodes: [Node]) {
            for node in nodes {
                let isSelected = selected.contains(node.id)
                if isSelected {
                    result.append(node)
                }
                if case .folder(let folder) = node, !isSelected || includingDescendantsOfSelected {
                    walk(folder.children)
                }
            }
        }
        if !selected.isEmpty {
            walk(currentWorkspace.items)
        }
        return result
    }

    /// What "Open N Links" and a folder's "Open All Links" open, in list order:
    /// each selected link and the links directly inside each selected folder (not
    /// deeper; a folder selected inside a selected folder adds its own). A link
    /// reached twice (selected, and inside a selected folder) opens once.
    func linksToOpen(forSelection ids: some Collection<UUID>) -> [Link] {
        var seen: Set<UUID> = []
        var links: [Link] = []
        func add(_ link: Link) {
            if seen.insert(link.id).inserted { links.append(link) }
        }
        for node in selectedNodes(ids, includingDescendantsOfSelected: true) {
            switch node {
            case .link(let link):
                add(link)
            case .folder(let folder):
                for case .link(let link) in folder.children {
                    add(link)
                }
            case .note:
                break
            }
        }
        return links
    }

    /// What "Copy N Links" copies: the selected links themselves, in list order.
    func linksToCopy(forSelection ids: some Collection<UUID>) -> [Link] {
        selectedNodes(ids, includingDescendantsOfSelected: true).compactMap { node in
            if case .link(let link) = node { return link }
            return nil
        }
    }

    /// Deletes the selection; a node inside a selected folder goes with the folder.
    func deleteNodes(ids: some Collection<UUID>) {
        for node in selectedNodes(ids) {
            deleteNode(id: node.id)
        }
    }

    func moveNodesToWorkspace(nodeIds: [UUID], toWorkspaceId: UUID) {
        guard toWorkspaceId != currentWorkspace.id else { return }
        let nodeIds = selectedNodes(nodeIds).map(\.id)
        guard !nodeIds.isEmpty else { return }
        guard state.workspaces.contains(where: { $0.id == toWorkspaceId }) else { return }

        guard let sourceIndex = state.workspaces.firstIndex(where: { $0.id == currentWorkspace.id }),
              let destIndex = state.workspaces.firstIndex(where: { $0.id == toWorkspaceId }) else { return }
        var nodesToMove: [Node] = []
        for nodeId in nodeIds {
            if let removed = removeNode(id: nodeId, nodes: &state.workspaces[sourceIndex].items) {
                nodesToMove.append(removed)
            }
        }
        guard !nodesToMove.isEmpty else { return }
        state.workspaces[destIndex].items.append(contentsOf: nodesToMove)
        persist()
    }

    @discardableResult
    func groupNodesInNewFolder(nodeIds: [UUID], folderName: String) -> UUID? {
        let nodeIds = selectedNodes(nodeIds).map(\.id)
        guard !nodeIds.isEmpty else { return nil }

        // Find locations BEFORE removal to determine correct insertion point
        let locations = nodeIds.compactMap { findNodeLocation(id: $0, nodes: currentWorkspace.items) }

        // Determine common parent — if all selected nodes share the same parent, use it
        let parentIds = Set(locations.map { $0.parentId })
        let commonParentId: UUID? = parentIds.count == 1 ? parentIds.first! : nil

        // Insertion index: earliest position among selected nodes in the common parent
        let insertionIndex: Int? = parentIds.count == 1 ? locations.map { $0.index }.min() : nil

        var nodesToGroup: [Node] = []

        updateWorkspace(id: currentWorkspace.id, notify: false) { workspace in
            for nodeId in nodeIds {
                if let removed = removeNode(id: nodeId, nodes: &workspace.items) {
                    nodesToGroup.append(removed)
                }
            }
        }

        guard !nodesToGroup.isEmpty else { return nil }

        let folder = Folder(id: UUID(), name: folderName, children: nodesToGroup, isExpanded: true)

        updateWorkspace(id: currentWorkspace.id) { workspace in
            insertNode(.folder(folder), parentId: commonParentId, index: insertionIndex, nodes: &workspace.items)
        }

        return folder.id
    }

    private func insertNode(_ node: Node, parentId: UUID?) {
        updateWorkspace(id: currentWorkspace.id) { workspace in
            insertNode(node, parentId: parentId, index: nil, nodes: &workspace.items)
        }
    }

    private func updateWorkspace(id: UUID, notify: Bool = true, _ mutate: (inout Workspace) -> Void) {
        guard let index = state.workspaces.firstIndex(where: { $0.id == id }) else { return }
        mutate(&state.workspaces[index])
        persist(notify: notify)
    }

    private func updateProfile(id: UUID, notify: Bool = true, _ mutate: (inout Profile) -> Void) {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        mutate(&state.profiles[index])
        persist(notify: notify)
    }

    /// Mutates the favorite `id` in whichever profile holds it. Not limited to the
    /// current profile: async callers (favicon fetches) may finish after a space switch.
    private func updateFavorite(id: UUID, _ mutate: (inout Link) -> Void) {
        guard let (profileIndex, index) = favoriteLocation(id: id) else { return }
        mutate(&state.profiles[profileIndex].favorites[index])
        persist()
    }

    private func updateNode(id: UUID, notify: Bool = true, _ mutate: (inout Node) -> Void) {
        guard let wsId = workspaceIdContaining(nodeId: id) else { return }
        updateWorkspace(id: wsId, notify: notify) { workspace in
            _ = updateNode(id: id, nodes: &workspace.items, mutate)
        }
    }

    @discardableResult
    private func persist(notify: Bool = true) -> Bool {
        let saved = store.save(state)
        if !saved { onSaveFailure?() }
        if notify {
            onChange?()
        }
        return saved
    }

    private func insertNode(_ node: Node, parentId: UUID?, index: Int?, nodes: inout [Node]) {
        if let parentId {
            for i in nodes.indices {
                switch nodes[i] {
                case .folder(var folder):
                    if folder.id == parentId {
                        if let index {
                            let idx = max(0, min(index, folder.children.count))
                            folder.children.insert(node, at: idx)
                        } else {
                            folder.children.append(node)
                        }
                        nodes[i] = .folder(folder)
                        return
                    }
                    insertNode(node, parentId: parentId, index: index, nodes: &folder.children)
                    nodes[i] = .folder(folder)
                case .link, .note:
                    continue
                }
            }
        } else {
            if let index {
                let idx = max(0, min(index, nodes.count))
                nodes.insert(node, at: idx)
            } else {
                nodes.append(node)
            }
        }
    }

    private func updateNode(id: UUID, nodes: inout [Node], _ mutate: (inout Node) -> Void) -> Bool {
        for index in nodes.indices {
            switch nodes[index] {
            case .link(let link):
                if link.id == id {
                    var node = nodes[index]
                    mutate(&node)
                    nodes[index] = node
                    return true
                }
            case .note(let note):
                if note.id == id {
                    var node = nodes[index]
                    mutate(&node)
                    nodes[index] = node
                    return true
                }
            case .folder(var folder):
                if folder.id == id {
                    var node = nodes[index]
                    mutate(&node)
                    nodes[index] = node
                    return true
                }
                if updateNode(id: id, nodes: &folder.children, mutate) {
                    nodes[index] = .folder(folder)
                    return true
                }
            }
        }
        return false
    }

    private func removeNode(id: UUID, nodes: inout [Node]) -> Node? {
        for index in nodes.indices {
            switch nodes[index] {
            case .link(let link):
                if link.id == id {
                    return nodes.remove(at: index)
                }
            case .note(let note):
                if note.id == id {
                    return nodes.remove(at: index)
                }
            case .folder(var folder):
                if folder.id == id {
                    return nodes.remove(at: index)
                }
                if let removed = removeNode(id: id, nodes: &folder.children) {
                    nodes[index] = .folder(folder)
                    return removed
                }
            }
        }
        return nil
    }

    private func findNodeLocation(id: UUID, nodes: [Node], parentId: UUID? = nil) -> NodeLocation? {
        for (index, node) in nodes.enumerated() {
            switch node {
            case .link(let link):
                if link.id == id {
                    return NodeLocation(parentId: parentId, index: index)
                }
            case .note(let note):
                if note.id == id {
                    return NodeLocation(parentId: parentId, index: index)
                }
            case .folder(let folder):
                if folder.id == id {
                    return NodeLocation(parentId: parentId, index: index)
                }
                if let location = findNodeLocation(id: id, nodes: folder.children, parentId: folder.id) {
                    return location
                }
            }
        }
        return nil
    }

    private func isDescendant(nodeId: UUID, in potentialAncestorId: UUID) -> Bool {
        guard let ancestor = nodeById(potentialAncestorId, nodes: currentWorkspace.items) else { return false }
        return containsNode(nodeId, within: ancestor)
    }

    private func isDescendant(nodeId: UUID, ofAncestor ancestorId: UUID, in nodes: [Node]) -> Bool {
        guard let ancestor = nodeById(ancestorId, nodes: nodes) else { return false }
        return containsNode(nodeId, within: ancestor)
    }

    private func workspaceIdContaining(nodeId: UUID) -> UUID? {
        for workspace in state.workspaces {
            if findNodeLocation(id: nodeId, nodes: workspace.items) != nil {
                return workspace.id
            }
        }
        return nil
    }

    private func nodeById(_ id: UUID, nodes: [Node]) -> Node? {
        for node in nodes {
            switch node {
            case .link(let link):
                if link.id == id { return node }
            case .note(let note):
                if note.id == id { return node }
            case .folder(let folder):
                if folder.id == id { return node }
                if let found = nodeById(id, nodes: folder.children) {
                    return found
                }
            }
        }
        return nil
    }

    private func containsNode(_ id: UUID, within node: Node) -> Bool {
        switch node {
        case .link(let link):
            return link.id == id
        case .note(let note):
            return note.id == id
        case .folder(let folder):
            if folder.id == id { return true }
            return folder.children.contains(where: { containsNode(id, within: $0) })
        }
    }
}
