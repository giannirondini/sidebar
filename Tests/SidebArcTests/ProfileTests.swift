import Foundation
import Testing
@testable import SidebArcCore

/// Profile CRUD in `AppModel`.
@Suite struct ProfileTests {
    private let scratch = TempDir()
    private let testDefaults = TestDefaults()
    private let model: AppModel
    private let store: DataStore

    init() {
        let temp = scratch.url.appendingPathComponent(UUID().uuidString)
        store = DataStore(baseDirectory: temp)
        store.save(DataStore.defaultState())
        model = AppModel(store: store, defaults: testDefaults.suite)
    }

    private func pinNewLink(_ url: String) -> UUID {
        let id = model.addLink(urlString: url, title: url, parentId: nil)
        model.pinLink(id: id)
        return id
    }

    private func linkIds(in nodes: [Node]) -> [UUID] {
        nodes.flatMap { node -> [UUID] in
            switch node {
            case .link(let link): return [link.id]
            case .folder(let folder): return linkIds(in: folder.children)
            case .note: return []
            }
        }
    }

    @Test func createRenameAndSetBrowser() {
        defer { expectPersisted(model, in: store) }
        let id = model.createProfile(name: "Work")
        #expect(model.profiles.map(\.name) == ["Default", "Work"])
        expectPersisted(model, in: store)

        model.renameProfile(id: id, newName: "  Job  ")
        #expect(model.profile(id: id)?.name == "Job")
        expectPersisted(model, in: store)
        model.renameProfile(id: id, newName: "   ")
        #expect(model.profile(id: id)?.name == "Job")

        model.setProfileBrowser(id: id, bundleId: "org.mozilla.firefox")
        #expect(model.profile(id: id)?.browserBundleId == "org.mozilla.firefox")
        expectPersisted(model, in: store)
        model.setProfileBrowser(id: id, bundleId: nil)
        #expect(model.profile(id: id)?.browserBundleId == nil)
    }

    @Test func assignWorkspaceSwitchesItsFavorites() {
        defer { expectPersisted(model, in: store) }
        let defaultId = model.currentProfile.id
        _ = pinNewLink("https://personal.com")
        let work = model.createProfile(name: "Work")

        model.assignWorkspace(model.currentWorkspace.id, toProfile: work)
        #expect(model.currentProfile.id == work)
        #expect(model.currentProfile.favorites.isEmpty)
        // Favorites belong to the profile, not the space.
        #expect(model.profile(id: defaultId)?.favorites.count == 1)

        // Unknown profile ids are ignored.
        model.assignWorkspace(model.currentWorkspace.id, toProfile: UUID())
        #expect(model.currentProfile.id == work)
    }

    @Test func lastProfileCannotBeDeleted() {
        defer { expectPersisted(model, in: store) }
        let only = model.currentProfile.id
        #expect(model.profileDeletionTarget(for: only) == nil)
        model.deleteProfile(id: only)
        #expect(model.profiles.map(\.id) == [only])
    }

    @Test func deletingAProfileMovesSpacesAndMergesFavoritesIntoFirstRemaining() {
        defer { expectPersisted(model, in: store) }
        let defaultId = model.currentProfile.id
        let shared = pinNewLink("https://shared.com")

        let work = model.createProfile(name: "Work")
        let workSpace = model.createWorkspace(name: "Work space", colorId: .defaultColor())
        model.assignWorkspace(workSpace, toProfile: work)
        model.selectWorkspace(id: workSpace)
        let duplicate = pinNewLink("https://SHARED.com/")
        let unique = pinNewLink("https://work-only.com")

        #expect(model.profileDeletionTarget(for: work)?.id == defaultId)
        model.deleteProfile(id: work)

        #expect(model.profiles.map(\.id) == [defaultId])
        #expect(model.workspaces.allSatisfy { $0.profileId == defaultId })
        #expect(model.currentProfile.favorites.map(\.id) == [shared, unique])

        // The duplicate isn't dropped: it lands in a folder at the top of the moved space.
        let moved = model.workspaces.first(where: { $0.id == workSpace })!
        guard case .folder(let folder) = moved.items.first else {
            Issue.record("Expected a folder for the leftover favorite")
            return
        }
        #expect(folder.name == "Favorites (from Work)")
        #expect(linkIds(in: folder.children) == [duplicate])
    }

    @Test func deletingAProfileWithoutSpacesKeepsItsOverflowInTheTargetsFirstSpace() {
        defer { expectPersisted(model, in: store) }
        let target = model.currentProfile.id
        for i in 0..<Profile.maxFavorites { _ = pinNewLink("https://t\(i).com") }

        // A profile with favorites but no spaces (its only space was reassigned).
        let orphan = model.createProfile(name: "Orphan")
        let tmpSpace = model.createWorkspace(name: "tmp", colorId: .defaultColor())
        model.assignWorkspace(tmpSpace, toProfile: orphan)
        model.selectWorkspace(id: tmpSpace)
        let orphanFavorite = pinNewLink("https://orphan.com")
        model.assignWorkspace(tmpSpace, toProfile: target)
        #expect(model.workspaces(inProfile: orphan).isEmpty)

        model.deleteProfile(id: orphan)
        #expect(model.profile(id: target)?.favorites.count == Profile.maxFavorites)
        let firstSpace = model.workspaces.first(where: { $0.profileId == target })!
        #expect(linkIds(in: firstSpace.items).contains(orphanFavorite))
    }

    @Test func linkBrowserOverrideOnListLinksAndFavorites() {
        defer { expectPersisted(model, in: store) }
        let listLink = model.addLink(urlString: "https://list.com", title: "List", parentId: nil)
        let favorite = pinNewLink("https://fav.com")

        model.setLinkBrowserOverride(id: listLink, bundleId: "com.apple.Safari")
        model.setLinkBrowserOverride(id: favorite, bundleId: "org.mozilla.firefox")
        expectPersisted(model, in: store)

        guard case .link(let updated) = model.nodeById(listLink) else {
            Issue.record("Expected list link")
            return
        }
        #expect(updated.browserBundleId == "com.apple.Safari")
        #expect(model.pinnedLinkById(favorite)?.browserBundleId == "org.mozilla.firefox")

        model.setLinkBrowserOverride(id: favorite, bundleId: nil)
        #expect(model.pinnedLinkById(favorite)?.browserBundleId == nil)
    }

    @Test func focusesOpenTabsSetAndReset() {
        defer { expectPersisted(model, in: store) }
        let id = model.createProfile(name: "Work")
        #expect(model.profile(id: id)?.focusesOpenTabs == nil)
        model.setProfileFocusesOpenTabs(id: id, enabled: false)
        #expect(model.profile(id: id)?.focusesOpenTabs == false)
        expectPersisted(model, in: store)
        model.setProfileFocusesOpenTabs(id: id, enabled: true)
        #expect(model.profile(id: id)?.focusesOpenTabs == true)
        expectPersisted(model, in: store)
        model.setProfileFocusesOpenTabs(id: id, enabled: nil)
        #expect(model.profile(id: id)?.focusesOpenTabs == nil)
    }

    @Test func exactTabMatchOnListLinksAndFavorites() {
        defer { expectPersisted(model, in: store) }
        let listLink = model.addLink(urlString: "https://list.com", title: "List", parentId: nil)
        let favorite = pinNewLink("https://fav.com")

        model.setLinkExactTabMatch(id: listLink, exact: true)
        model.setLinkExactTabMatch(id: favorite, exact: true)
        expectPersisted(model, in: store)
        guard case .link(let updated) = model.nodeById(listLink) else {
            Issue.record("Expected list link")
            return
        }
        #expect(updated.exactTabMatch == true)
        #expect(model.pinnedLinkById(favorite)?.exactTabMatch == true)

        // Off is stored as nil (the default), so the key stays out of the JSON.
        model.setLinkExactTabMatch(id: favorite, exact: false)
        #expect(model.pinnedLinkById(favorite)?.exactTabMatch == nil)
    }

    // MARK: - Arc import mapping

    private func link(_ url: String) -> Link {
        Link(id: UUID(), title: url, url: url, faviconPath: nil)
    }

    @Test func arcImportMapsDefaultProfileToDefaultAndMergesFavorites() {
        defer { expectPersisted(model, in: store) }
        let defaultId = model.currentProfile.id
        let existing = pinNewLink("https://mail.com")
        let selectedBefore = model.state.selectedWorkspaceId

        let result = ArcImportResult(
            workspaces: [ImportWorkspace(name: "Home", colorId: .ember, nodes: [.link(link("https://list.com"))], arcProfile: .default)],
            profiles: [ImportProfile(arcProfile: .default, favorites: [link("https://MAIL.com/"), link("https://docs.com")])],
            workspacesCreated: 1, linksImported: 1, foldersImported: 0
        )
        model.applyArcImport(result)

        #expect(model.profiles.map(\.id) == [defaultId])
        let home = model.workspaces.first(where: { $0.name == "Home" })!
        #expect(home.profileId == defaultId)
        #expect(model.profile(id: defaultId)?.favorites.map(\.url) == ["https://mail.com", "https://docs.com"])
        #expect(model.profile(id: defaultId)?.favorites.first?.id == existing)
        // The duplicate lands in a folder at the top of the imported space.
        guard case .folder(let folder) = home.items.first else {
            Issue.record("Expected the Arc favorites folder")
            return
        }
        #expect(folder.name == AppModel.arcFavoritesFolderName)
        #expect(linkIds(in: folder.children).count == 1)
        #expect(model.state.selectedWorkspaceId == selectedBefore)
    }

    @Test func arcImportCreatesProfileForCustomArcProfileAndKeepsFavoritesOfSkippedSpaces() {
        defer { expectPersisted(model, in: store) }
        let custom = ArcProfileKey(.object(["custom": .object(["_0": .object(["directoryBasename": .string("Profile 1")])])]))
        let result = ArcImportResult(
            workspaces: [],  // every Work space was empty, so none was imported
            profiles: [ImportProfile(arcProfile: custom, favorites: [link("https://w.com")])],
            workspacesCreated: 0, linksImported: 0, foldersImported: 0
        )
        model.applyArcImport(result)
        expectPersisted(model, in: store)

        let created = model.profiles.first(where: { $0.name == "Arc Profile 1" })
        #expect(created?.favorites.map(\.url) == ["https://w.com"])
        #expect(model.profiles.count == 2)

        // A second import reuses the profile by name.
        model.applyArcImport(result)
        #expect(model.profiles.count == 2)
    }

    @Test func arcImportWithoutProfilesJoinsCurrentProfile() {
        defer { expectPersisted(model, in: store) }
        let current = model.currentProfile.id
        model.applyArcImport(ArcImportResult(
            workspaces: [ImportWorkspace(name: "Plain", colorId: .ocean, nodes: [])],
            workspacesCreated: 1, linksImported: 0, foldersImported: 0
        ))
        #expect(model.workspaces.first(where: { $0.name == "Plain" })?.profileId == current)
    }
}
