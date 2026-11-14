import Foundation
import Testing
@testable import SidebArcCore

/// Profile CRUD in `AppModel`.
@Suite struct ProfileTests {
    private let model: AppModel

    init() {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DataStore(baseDirectory: temp)
        store.save(DataStore.defaultState())
        model = AppModel(store: store)
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
        let id = model.createProfile(name: "Work")
        #expect(model.profiles.map(\.name) == ["Default", "Work"])

        model.renameProfile(id: id, newName: "  Job  ")
        #expect(model.profile(id: id)?.name == "Job")
        model.renameProfile(id: id, newName: "   ")
        #expect(model.profile(id: id)?.name == "Job")

        model.setProfileBrowser(id: id, bundleId: "org.mozilla.firefox")
        #expect(model.profile(id: id)?.browserBundleId == "org.mozilla.firefox")
        model.setProfileBrowser(id: id, bundleId: nil)
        #expect(model.profile(id: id)?.browserBundleId == nil)
    }

    @Test func assignWorkspaceSwitchesItsFavorites() {
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
        let only = model.currentProfile.id
        #expect(model.profileDeletionTarget(for: only) == nil)
        model.deleteProfile(id: only)
        #expect(model.profiles.map(\.id) == [only])
    }

    @Test func deletingAProfileMovesSpacesAndMergesFavoritesIntoFirstRemaining() {
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
        let listLink = model.addLink(urlString: "https://list.com", title: "List", parentId: nil)
        let favorite = pinNewLink("https://fav.com")

        model.setLinkBrowserOverride(id: listLink, bundleId: "com.apple.Safari")
        model.setLinkBrowserOverride(id: favorite, bundleId: "org.mozilla.firefox")

        guard case .link(let updated) = model.nodeById(listLink) else {
            Issue.record("Expected list link")
            return
        }
        #expect(updated.browserBundleId == "com.apple.Safari")
        #expect(model.pinnedLinkById(favorite)?.browserBundleId == "org.mozilla.firefox")

        model.setLinkBrowserOverride(id: favorite, bundleId: nil)
        #expect(model.pinnedLinkById(favorite)?.browserBundleId == nil)
    }
}
