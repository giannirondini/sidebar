import Foundation
import Testing
@testable import SidebArcCore

@Suite struct ModelTests {
    private func makeStore() -> DataStore {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DataStore(baseDirectory: temp)
    }

    /// One profile holding every given workspace.
    private func makeState(_ workspaces: (UUID) -> [Workspace], favorites: [Link] = []) -> AppState {
        let profile = Profile(name: "Default", favorites: favorites)
        let list = workspaces(profile.id)
        return AppState(profiles: [profile], workspaces: list, selectedWorkspaceId: list.first?.id, isSettingsSelected: false)
    }

    @Test func testJSONRoundTrip() throws {
        let link = Link(id: UUID(), title: "Example", url: "https://example.com", faviconPath: nil)
        let folder = Folder(id: UUID(), name: "Folder", children: [.link(link)], isExpanded: true)
        let state = makeState { [Workspace(id: UUID(), name: "Inbox", colorId: .ember, items: [.folder(folder)], profileId: $0)] }

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        #expect(state == decoded)
    }

    @Test func testMoveNodeReorderAndNest() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        model.addFolder(name: "Folder", parentId: nil)
        model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        model.addLink(urlString: "https://b.com", title: "B", parentId: nil)

        guard
            let folderId = model.currentWorkspace.items.compactMap({
                if case .folder(let folder) = $0 { return folder.id }
                return nil
            }).first,
            let linkAId = model.currentWorkspace.items.compactMap({
                if case .link(let link) = $0, link.title == "A" { return link.id }
                return nil
            }).first
        else {
            Issue.record("Expected nodes to exist")
            return
        }

        model.moveNode(id: linkAId, toParentId: folderId, index: 0)
        let location = model.location(of: linkAId)
        #expect(location?.parentId == folderId)

        if let folderNode = model.nodeById(folderId), case .folder(let folder) = folderNode {
            #expect(folder.children.count == 1)
        } else {
            Issue.record("Expected folder to contain moved link")
        }

        if let linkBId = model.currentWorkspace.items.compactMap({
            if case .link(let link) = $0, link.title == "B" { return link.id }
            return nil
        }).first {
            model.moveNode(id: linkBId, toParentId: nil, index: 0)
            let locationB = model.location(of: linkBId)
            #expect(locationB?.parentId == nil)
            #expect(locationB?.index == 0)
        }
    }

    @Test func testWorkspaceScopedFiltering() {
        let link1 = Link(id: UUID(), title: "Docs", url: "https://docs.com", faviconPath: nil)
        let link2 = Link(id: UUID(), title: "Blog", url: "https://blog.com", faviconPath: nil)
        let folder = Folder(id: UUID(), name: "Reading", children: [.link(link2)], isExpanded: false)
        let nodes: [Node] = [.link(link1), .folder(folder)]

        let results = NodeFiltering.filter(nodes: nodes, query: "blog")
        #expect(results.count == 1)
        if case .folder(let filteredFolder) = results[0] {
            #expect(filteredFolder.children.count == 1)
        } else {
            Issue.record("Expected folder to remain for matching child")
        }
    }

    @Test func testWorkspaceReordering() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        // Create three workspaces
        let id1 = model.createWorkspace(name: "First", colorId: .ember)
        let id2 = model.createWorkspace(name: "Second", colorId: .ruby)
        let id3 = model.createWorkspace(name: "Third", colorId: .moss)

        // Initial order should be: Inbox (default), First, Second, Third
        #expect(model.workspaces.count == 4)
        #expect(model.workspaces[0].name == "Inbox")
        #expect(model.workspaces[1].name == "First")
        #expect(model.workspaces[2].name == "Second")
        #expect(model.workspaces[3].name == "Third")

        // Move "Second" to the right (swap with "Third")
        model.moveWorkspace(id: id2, direction: .right)
        #expect(model.workspaces[2].name == "Third")
        #expect(model.workspaces[3].name == "Second")

        // Move "Second" to the left (swap back with "Third")
        model.moveWorkspace(id: id2, direction: .left)
        #expect(model.workspaces[2].name == "Second")
        #expect(model.workspaces[3].name == "Third")

        // Move "First" to the left (swap with "Inbox")
        model.moveWorkspace(id: id1, direction: .left)
        #expect(model.workspaces[0].name == "First")
        #expect(model.workspaces[1].name == "Inbox")

        // Try to move "First" to the left again (should not move, already at start)
        model.moveWorkspace(id: id1, direction: .left)
        #expect(model.workspaces[0].name == "First")
        #expect(model.workspaces[1].name == "Inbox")

        // Try to move "Third" to the right (should not move, already at end)
        model.moveWorkspace(id: id3, direction: .right)
        #expect(model.workspaces[2].name == "Second")
        #expect(model.workspaces[3].name == "Third")
    }

    // MARK: - Favorites (pinned links, shared per profile)

    @Test func testPinLink() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        #expect(model.currentWorkspace.items.count == 1)
        #expect(model.currentProfile.favorites.count == 0)

        model.pinLink(id: linkId)
        #expect(model.currentWorkspace.items.count == 0)
        #expect(model.currentProfile.favorites.count == 1)
        #expect(model.currentProfile.favorites[0].id == linkId)
        #expect(model.currentProfile.favorites[0].title == "A")
    }

    @Test func testUnpinLink() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        model.pinLink(id: linkId)
        #expect(model.currentProfile.favorites.count == 1)
        #expect(model.currentWorkspace.items.count == 0)

        model.unpinLink(id: linkId)
        #expect(model.currentProfile.favorites.count == 0)
        #expect(model.currentWorkspace.items.count == 1)
        if case .link(let link) = model.currentWorkspace.items.last {
            #expect(link.id == linkId)
            #expect(link.title == "A")
        } else {
            Issue.record("Expected link at root level after unpin")
        }
    }

    @Test func testPinLinkMaximum() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let max = Profile.maxFavorites
        var linkIds: [UUID] = []
        for i in 0..<(max + 1) {
            let id = model.addLink(urlString: "https://\(i).com", title: "Link \(i)", parentId: nil)
            linkIds.append(id)
        }

        // Pin up to the maximum
        for i in 0..<max {
            model.pinLink(id: linkIds[i])
        }
        #expect(model.currentProfile.favorites.count == max)
        #expect(model.currentWorkspace.items.count == 1)
        #expect(!model.canPinMore)

        // Attempt to pin one more - should be rejected
        model.pinLink(id: linkIds[max])
        #expect(model.currentProfile.favorites.count == max)
        #expect(model.currentWorkspace.items.count == 1)
    }

    @Test func testPinLinkFromNestedFolder() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let folderId = model.addFolder(name: "Folder", parentId: nil)
        let linkId = model.addLink(urlString: "https://nested.com", title: "Nested", parentId: folderId)

        if let folderNode = model.nodeById(folderId), case .folder(let folder) = folderNode {
            #expect(folder.children.count == 1)
        }

        model.pinLink(id: linkId)
        #expect(model.currentProfile.favorites.count == 1)
        #expect(model.currentProfile.favorites[0].title == "Nested")

        // Verify link was removed from the folder
        if let folderNode = model.nodeById(folderId), case .folder(let folder) = folderNode {
            #expect(folder.children.count == 0)
        } else {
            Issue.record("Expected folder to still exist")
        }
    }

    @Test func testCannotPinFolder() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let folderId = model.addFolder(name: "Folder", parentId: nil)
        model.pinLink(id: folderId)
        #expect(model.currentProfile.favorites.count == 0)
        #expect(model.currentWorkspace.items.count == 1)
    }

    @Test func testNewWorkspaceJoinsCurrentProfile() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let firstProfileId = model.currentProfile.id
        let newId = model.createWorkspace(name: "B", colorId: .defaultColor())
        let created = model.workspaces.first(where: { $0.id == newId })
        #expect(created?.profileId == firstProfileId)
    }

    @Test func testFavoritesAreSharedBySpacesInTheSameProfile() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let spaceA = model.currentWorkspace.id
        let linkId = model.addLink(urlString: "https://shared.com", title: "Shared", parentId: nil)
        model.pinLink(id: linkId)

        let spaceB = model.createWorkspace(name: "B", colorId: .defaultColor())
        model.selectWorkspace(id: spaceB)
        #expect(model.currentProfile.favorites.map(\.id) == [linkId])

        // Unpinning from B lands the link in B's list, not in A's.
        model.unpinLink(id: linkId)
        #expect(model.currentProfile.favorites.isEmpty)
        #expect(model.currentWorkspace.items.map(\.id) == [linkId])
        #expect(model.workspaces.first(where: { $0.id == spaceA })?.items.isEmpty == true)
    }

    @Test func testFavoritesAreNotSharedAcrossProfiles() {
        let personal = Profile(name: "Personal")
        let work = Profile(name: "Work")
        let spaceA = Workspace(id: UUID(), name: "A", colorId: .ember, items: [], profileId: personal.id)
        let spaceB = Workspace(id: UUID(), name: "B", colorId: .ocean, items: [], profileId: work.id)
        let store = makeStore()
        store.save(AppState(profiles: [personal, work], workspaces: [spaceA, spaceB], selectedWorkspaceId: spaceA.id, isSettingsSelected: false))
        let model = AppModel(store: store)
        model.selectWorkspace(id: spaceA.id)

        let linkId = model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        model.pinLink(id: linkId)
        #expect(model.currentProfile.id == personal.id)
        #expect(model.currentProfile.favorites.count == 1)

        model.selectWorkspace(id: spaceB.id)
        #expect(model.currentProfile.id == work.id)
        #expect(model.currentProfile.favorites.isEmpty)
    }

    @Test func testFavoriteUpdateReachesProfileOfAnotherSpace() {
        // Favicon fetches complete asynchronously, possibly after a switch to another profile.
        let personal = Profile(name: "Personal")
        let work = Profile(name: "Work")
        let favorite = Link(id: UUID(), title: "Fav", url: "https://fav.com", faviconPath: nil)
        var workWithFavorite = work
        workWithFavorite.favorites = [favorite]
        let spaceA = Workspace(id: UUID(), name: "A", colorId: .ember, items: [], profileId: personal.id)
        let spaceB = Workspace(id: UUID(), name: "B", colorId: .ocean, items: [], profileId: work.id)
        let store = makeStore()
        store.save(AppState(profiles: [personal, workWithFavorite], workspaces: [spaceA, spaceB], selectedWorkspaceId: spaceA.id, isSettingsSelected: false))
        let model = AppModel(store: store)
        model.selectWorkspace(id: spaceA.id)

        model.updatePinnedLinkFaviconPath(id: favorite.id, path: "/tmp/icon.png")
        #expect(model.profile(id: work.id)?.favorites.first?.faviconPath == "/tmp/icon.png")
    }

    @Test func testJSONRoundTripWithProfilesAndFavorites() throws {
        var override = Link(id: UUID(), title: "Tree", url: "https://tree.com", faviconPath: nil)
        override.browserBundleId = "com.apple.Safari"
        let favorite = Link(id: UUID(), title: "Pinned", url: "https://pinned.com", faviconPath: nil)
        let profile = Profile(
            name: "Work",
            browserBundleId: "com.google.Chrome",
            browserProfiles: ["com.google.chrome": "Profile 1", "org.mozilla.firefox": "default"],
            favorites: [favorite]
        )
        let workspace = Workspace(id: UUID(), name: "Test", colorId: .ember, items: [.link(override)], profileId: profile.id)
        let state = AppState(profiles: [profile], workspaces: [workspace], selectedWorkspaceId: workspace.id, isSettingsSelected: false)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)

        #expect(decoded.schemaVersion == AppState.currentSchemaVersion)
        #expect(decoded.profiles[0].favorites.map(\.title) == ["Pinned"])
        #expect(decoded.profiles[0].browserProfiles["com.google.chrome"] == "Profile 1")
        #expect(state == decoded)
    }

    @Test func testLinkBrowserOverrideIsOptionalInJSON() throws {
        let json = #"{"id": "00000000-0000-0000-0000-000000000020", "title": "T", "url": "https://t.com"}"#
        let link = try JSONDecoder().decode(Link.self, from: Data(json.utf8))
        #expect(link.browserBundleId == nil)

        let encoded = try #require(String(data: JSONEncoder().encode(link), encoding: .utf8))
        #expect(!encoded.contains("browserBundleId"))
    }

    @Test func testRepairCreatesProfileAndFixesDanglingProfileIds() {
        let orphan = Workspace(id: UUID(), name: "Orphan", colorId: .ember, items: [], profileId: UUID())
        let repaired = AppState(profiles: [], workspaces: [orphan], selectedWorkspaceId: orphan.id, isSettingsSelected: false).repaired()
        #expect(repaired.profiles.count == 1)
        #expect(repaired.workspaces[0].profileId == repaired.profiles[0].id)

        let keep = Profile(name: "Keep")
        let second = Workspace(id: UUID(), name: "Dangling", colorId: .ember, items: [], profileId: UUID())
        let fixed = AppState(profiles: [keep], workspaces: [second], selectedWorkspaceId: nil, isSettingsSelected: false).repaired()
        #expect(fixed.profiles == [keep])
        #expect(fixed.workspaces[0].profileId == keep.id)
    }

    // MARK: - Browser Profile Tests

    @Test func testUpdateBrowserProfileAppliesToEverySpaceInProfile() throws {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let profileId = model.currentProfile.id
        let other = model.createWorkspace(name: "B", colorId: .defaultColor())
        #expect(model.currentProfile.browserProfiles.isEmpty)

        model.updateBrowserProfile(profileId: profileId, bundleId: "com.google.chrome", profile: "Profile 2")
        #expect(model.currentProfile.browserProfiles["com.google.chrome"] == "Profile 2")
        let otherSpace = try #require(model.workspaces.first(where: { $0.id == other }))
        #expect(model.profile(for: otherSpace).browserProfiles["com.google.chrome"] == "Profile 2")
    }

    @Test func testClearBrowserProfile() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let profileId = model.currentProfile.id

        model.updateBrowserProfile(profileId: profileId, bundleId: "com.google.chrome", profile: "Profile 1")
        #expect(model.currentProfile.browserProfiles["com.google.chrome"] == "Profile 1")

        model.updateBrowserProfile(profileId: profileId, bundleId: "com.google.chrome", profile: nil)
        #expect(model.currentProfile.browserProfiles["com.google.chrome"] == nil)
    }

    @Test func testUpdateBrowserProfileTrimsWhitespace() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let profileId = model.currentProfile.id

        // Empty string should result in no entry
        model.updateBrowserProfile(profileId: profileId, bundleId: "com.google.chrome", profile: "   ")
        #expect(model.currentProfile.browserProfiles["com.google.chrome"] == nil)

        // Whitespace-padded string should be trimmed
        model.updateBrowserProfile(profileId: profileId, bundleId: "com.google.chrome", profile: " Profile 1 ")
        #expect(model.currentProfile.browserProfiles["com.google.chrome"] == "Profile 1")
    }

    // MARK: - Open Folder Links Tests

    @Test func testFolderRootLinksWithOnlyLinks() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let folderId = model.addFolder(name: "Folder", parentId: nil)
        model.addLink(urlString: "https://a.com", title: "A", parentId: folderId)
        model.addLink(urlString: "https://b.com", title: "B", parentId: folderId)
        model.addLink(urlString: "https://c.com", title: "C", parentId: folderId)

        guard let node = model.nodeById(folderId), case .folder(let folder) = node else {
            Issue.record("Expected folder"); return
        }

        let rootLinks = folder.children.compactMap { child -> Link? in
            if case .link(let link) = child { return link }
            return nil
        }
        #expect(rootLinks.count == 3)
        #expect(rootLinks.map(\.title) == ["A", "B", "C"])
    }

    @Test func testFolderRootLinksWithMixedContent() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let folderId = model.addFolder(name: "Parent", parentId: nil)
        model.addLink(urlString: "https://root1.com", title: "Root Link 1", parentId: folderId)
        let nestedFolderId = model.addFolder(name: "Nested", parentId: folderId)
        model.addLink(urlString: "https://nested.com", title: "Nested Link", parentId: nestedFolderId)
        model.addLink(urlString: "https://root2.com", title: "Root Link 2", parentId: folderId)

        guard let node = model.nodeById(folderId), case .folder(let folder) = node else {
            Issue.record("Expected folder"); return
        }

        let rootLinks = folder.children.compactMap { child -> Link? in
            if case .link(let link) = child { return link }
            return nil
        }
        // Only root-level links, not the one inside the nested folder
        #expect(rootLinks.count == 2)
        #expect(rootLinks.map(\.title) == ["Root Link 1", "Root Link 2"])
    }

    @Test func testFolderRootLinksWithEmptyFolder() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let folderId = model.addFolder(name: "Empty", parentId: nil)

        guard let node = model.nodeById(folderId), case .folder(let folder) = node else {
            Issue.record("Expected folder"); return
        }

        let rootLinks = folder.children.compactMap { child -> Link? in
            if case .link(let link) = child { return link }
            return nil
        }
        #expect(rootLinks.count == 0)
    }

    @Test func testFolderRootLinksWithOnlyNestedFolders() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let folderId = model.addFolder(name: "Parent", parentId: nil)
        let childFolder1 = model.addFolder(name: "Child A", parentId: folderId)
        let childFolder2 = model.addFolder(name: "Child B", parentId: folderId)
        model.addLink(urlString: "https://deep1.com", title: "Deep 1", parentId: childFolder1)
        model.addLink(urlString: "https://deep2.com", title: "Deep 2", parentId: childFolder2)

        guard let node = model.nodeById(folderId), case .folder(let folder) = node else {
            Issue.record("Expected folder"); return
        }

        let rootLinks = folder.children.compactMap { child -> Link? in
            if case .link(let link) = child { return link }
            return nil
        }
        // No root-level links, even though nested folders contain links
        #expect(rootLinks.count == 0)
    }

    // MARK: - Bulk Open Links Tests

    @Test func testBulkOpenLinksWithOnlyLinks() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId1 = model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        let linkId2 = model.addLink(urlString: "https://b.com", title: "B", parentId: nil)
        let linkId3 = model.addLink(urlString: "https://c.com", title: "C", parentId: nil)

        let selectedIds: [UUID] = [linkId1, linkId2, linkId3]
        var collectedLinks: [Link] = []

        for nodeId in selectedIds {
            guard let node = model.nodeById(nodeId) else { continue }
            switch node {
            case .link(let link):
                collectedLinks.append(link)
            case .note:
                break
            case .folder(let folder):
                for child in folder.children {
                    if case .link(let link) = child {
                        collectedLinks.append(link)
                    }
                }
            }
        }

        #expect(collectedLinks.count == 3)
        #expect(Set(collectedLinks.map(\.url)) == Set(["https://a.com", "https://b.com", "https://c.com"]))
    }

    @Test func testBulkOpenLinksWithFolders() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let folderId = model.addFolder(name: "Folder", parentId: nil)
        model.addLink(urlString: "https://inside1.com", title: "Inside 1", parentId: folderId)
        model.addLink(urlString: "https://inside2.com", title: "Inside 2", parentId: folderId)

        let selectedIds: [UUID] = [folderId]
        var collectedLinks: [Link] = []

        for nodeId in selectedIds {
            guard let node = model.nodeById(nodeId) else { continue }
            switch node {
            case .link(let link):
                collectedLinks.append(link)
            case .note:
                break
            case .folder(let folder):
                for child in folder.children {
                    if case .link(let link) = child {
                        collectedLinks.append(link)
                    }
                }
            }
        }

        #expect(collectedLinks.count == 2)
        #expect(Set(collectedLinks.map(\.url)) == Set(["https://inside1.com", "https://inside2.com"]))
    }

    @Test func testBulkOpenLinksWithMixedSelection() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://direct.com", title: "Direct", parentId: nil)
        let folderId = model.addFolder(name: "Folder", parentId: nil)
        model.addLink(urlString: "https://inside.com", title: "Inside", parentId: folderId)
        let nestedFolderId = model.addFolder(name: "Nested", parentId: folderId)
        model.addLink(urlString: "https://deep.com", title: "Deep", parentId: nestedFolderId)

        let selectedIds: [UUID] = [linkId, folderId]
        var collectedLinks: [Link] = []

        for nodeId in selectedIds {
            guard let node = model.nodeById(nodeId) else { continue }
            switch node {
            case .link(let link):
                collectedLinks.append(link)
            case .note:
                break
            case .folder(let folder):
                for child in folder.children {
                    if case .link(let link) = child {
                        collectedLinks.append(link)
                    }
                }
            }
        }

        // Direct link + root-level link from folder, NOT the deeply nested link
        #expect(collectedLinks.count == 2)
        #expect(Set(collectedLinks.map(\.url)) == Set(["https://direct.com", "https://inside.com"]))
    }

    @Test func testBulkOpenLinksIgnoresNestedFolderLinks() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let parentFolderId = model.addFolder(name: "Parent", parentId: nil)
        let childFolderId = model.addFolder(name: "Child", parentId: parentFolderId)
        model.addLink(urlString: "https://nested.com", title: "Nested", parentId: childFolderId)

        // Only select the parent folder, not the child folder
        let selectedIds: [UUID] = [parentFolderId]
        var collectedLinks: [Link] = []

        for nodeId in selectedIds {
            guard let node = model.nodeById(nodeId) else { continue }
            switch node {
            case .link(let link):
                collectedLinks.append(link)
            case .note:
                break
            case .folder(let folder):
                for child in folder.children {
                    if case .link(let link) = child {
                        collectedLinks.append(link)
                    }
                }
            }
        }

        // Parent folder has no root-level links, only a nested folder
        #expect(collectedLinks.count == 0)
    }

    @Test func testBulkOpenLinksWithExplicitlySelectedNestedFolder() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let parentFolderId = model.addFolder(name: "Parent", parentId: nil)
        let childFolderId = model.addFolder(name: "Child", parentId: parentFolderId)
        model.addLink(urlString: "https://nested.com", title: "Nested", parentId: childFolderId)
        model.addLink(urlString: "https://root.com", title: "Root", parentId: parentFolderId)

        // Explicitly select both parent and child folders
        let selectedIds: [UUID] = [parentFolderId, childFolderId]
        var collectedLinks: [Link] = []

        for nodeId in selectedIds {
            guard let node = model.nodeById(nodeId) else { continue }
            switch node {
            case .link(let link):
                collectedLinks.append(link)
            case .note:
                break
            case .folder(let folder):
                for child in folder.children {
                    if case .link(let link) = child {
                        collectedLinks.append(link)
                    }
                }
            }
        }

        // Root link from parent + nested link from explicitly selected child folder
        #expect(collectedLinks.count == 2)
        #expect(Set(collectedLinks.map(\.url)) == Set(["https://root.com", "https://nested.com"]))
    }

    // MARK: - Custom Icon Tests

    @Test func testCustomIconJSONRoundTrip() throws {
        let link = Link(id: UUID(), title: "Test", url: "https://test.com", faviconPath: nil, customIcon: .emoji("🔥"))
        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(Link.self, from: data)
        #expect(decoded.customIcon == .emoji("🔥"))
    }

    @Test func testCustomIconSFSymbolRoundTrip() throws {
        let link = Link(id: UUID(), title: "Test", url: "https://test.com", faviconPath: nil, customIcon: .sfSymbol("star.fill"))
        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(Link.self, from: data)
        #expect(decoded.customIcon == .sfSymbol("star.fill"))
    }

    @Test func testCustomIconNilRoundTrip() throws {
        let link = Link(id: UUID(), title: "Test", url: "https://test.com", faviconPath: nil)
        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(Link.self, from: data)
        #expect(decoded.customIcon == nil)
    }

    @Test func testBackwardCompatibilityNoCustomIcon() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "Old Link",
            "url": "https://old.com"
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Link.self, from: data)
        #expect(decoded.title == "Old Link")
        #expect(decoded.customIcon == nil)
        #expect(decoded.faviconPath == nil)
    }

    @Test func testSetLinkCustomIcon() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://a.com", title: "A", parentId: nil)

        // Set emoji custom icon
        model.setLinkCustomIcon(id: linkId, icon: .emoji("🚀"))
        if let node = model.nodeById(linkId), case .link(let link) = node {
            #expect(link.customIcon == .emoji("🚀"))
        } else {
            Issue.record("Expected link")
        }

        // Restore (set to nil)
        model.setLinkCustomIcon(id: linkId, icon: nil)
        if let node = model.nodeById(linkId), case .link(let link) = node {
            #expect(link.customIcon == nil)
        } else {
            Issue.record("Expected link")
        }
    }

    @Test func testSetPinnedLinkCustomIcon() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        model.pinLink(id: linkId)

        model.setPinnedLinkCustomIcon(id: linkId, icon: .sfSymbol("heart.fill"))
        #expect(model.currentProfile.favorites[0].customIcon == .sfSymbol("heart.fill"))

        model.setPinnedLinkCustomIcon(id: linkId, icon: nil)
        #expect(model.currentProfile.favorites[0].customIcon == nil)
    }

    // MARK: - Note Tests

    @Test func testNoteJSONRoundTrip() throws {
        let note = Note(id: UUID(), title: "My Note", customIcon: .emoji("📝"))
        let folder = Folder(id: UUID(), name: "Folder", children: [.note(note)], isExpanded: true)
        let state = makeState {
            [Workspace(id: UUID(), name: "Inbox", colorId: .ember, items: [.folder(folder), .note(Note(id: UUID(), title: "Top-level", customIcon: nil))], profileId: $0)]
        }

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        #expect(state == decoded)

        guard case .folder(let decodedFolder) = decoded.workspaces[0].items[0],
              case .note(let decodedNote) = decodedFolder.children[0] else {
            Issue.record("Expected nested note inside folder")
            return
        }
        #expect(decodedNote.title == "My Note")
        #expect(decodedNote.customIcon == .emoji("📝"))
    }

    @Test func testBackwardCompatibilityNoNotes() throws {
        // Pre-Note schema (v1): items contain only folder/link entries. Decoding must succeed.
        let json = """
        {
            "schemaVersion": 1,
            "workspaces": [{
                "id": "00000000-0000-0000-0000-000000000010",
                "name": "Legacy",
                "colorId": "ember",
                "items": [
                    {"type": "link", "link": {"id": "00000000-0000-0000-0000-000000000011", "title": "Legacy Link", "url": "https://legacy.com"}}
                ],
                "pinnedLinks": []
            }],
            "selectedWorkspaceId": "00000000-0000-0000-0000-000000000010",
            "isSettingsSelected": false
        }
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SchemaV1.AppState.self, from: data)
        #expect(decoded.workspaces[0].items.count == 1)
        if case .link(let link) = decoded.workspaces[0].items[0] {
            #expect(link.title == "Legacy Link")
        } else {
            Issue.record("Expected link to decode")
        }
    }

    @Test func testAddNote() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let noteId = model.addNote(title: "Test Note", parentId: nil)
        #expect(model.currentWorkspace.items.count == 1)
        if case .note(let note) = model.currentWorkspace.items[0] {
            #expect(note.id == noteId)
            #expect(note.title == "Test Note")
        } else {
            Issue.record("Expected note at root")
        }

        // New notes start with empty content; the editor shows a placeholder instead.
        let content = model.noteStorage.read(id: noteId)
        #expect(content == "")
    }

    @Test func testRenameNote() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let noteId = model.addNote(title: "Old", parentId: nil)
        model.renameNode(id: noteId, newName: "New")

        if case .note(let note) = model.nodeById(noteId) {
            #expect(note.title == "New")
        } else {
            Issue.record("Expected note")
        }
    }

    @Test func testSetNoteCustomIcon() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let noteId = model.addNote(title: "Note", parentId: nil)
        model.setNoteCustomIcon(id: noteId, icon: .sfSymbol("note.text"))

        if case .note(let note) = model.nodeById(noteId) {
            #expect(note.customIcon == .sfSymbol("note.text"))
        } else {
            Issue.record("Expected note")
        }

        model.setNoteCustomIcon(id: noteId, icon: nil)
        if case .note(let note) = model.nodeById(noteId) {
            #expect(note.customIcon == nil)
        }
    }

    @Test func testDeleteNoteRemovesFile() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let noteId = model.addNote(title: "Doomed", parentId: nil)
        let fileURL = store.noteFileURL(for: noteId)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        model.deleteNode(id: noteId)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func testDeleteFolderCleansUpContainedNotes() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let folderId = model.addFolder(name: "Parent", parentId: nil)
        let noteAId = model.addNote(title: "A", parentId: folderId)
        let nestedFolderId = model.addFolder(name: "Nested", parentId: folderId)
        let noteBId = model.addNote(title: "B", parentId: nestedFolderId)

        let urlA = store.noteFileURL(for: noteAId)
        let urlB = store.noteFileURL(for: noteBId)
        #expect(FileManager.default.fileExists(atPath: urlA.path))
        #expect(FileManager.default.fileExists(atPath: urlB.path))

        model.deleteNode(id: folderId)

        #expect(!FileManager.default.fileExists(atPath: urlA.path))
        #expect(!FileManager.default.fileExists(atPath: urlB.path))
    }

    @Test func testNoteFilteringByTitle() {
        let note1 = Note(id: UUID(), title: "Project Plan", customIcon: nil)
        let note2 = Note(id: UUID(), title: "Recipes", customIcon: nil)
        let nodes: [Node] = [.note(note1), .note(note2)]

        let results = NodeFiltering.filter(nodes: nodes, query: "project")
        #expect(results.count == 1)
        if case .note(let filtered) = results[0] {
            #expect(filtered.title == "Project Plan")
        } else {
            Issue.record("Expected note in filter results")
        }
    }

    // MARK: - Scheduled Link Tests

    @Test func testLinkRoundTripWithSchedule() throws {
        let fireAt = Date(timeIntervalSince1970: 1_800_000_000)
        let link = Link(
            id: UUID(),
            title: "Scheduled",
            url: "https://example.com",
            faviconPath: nil,
            customIcon: nil,
            scheduledOpenAt: fireAt
        )
        let data = try JSONEncoder().encode(link)
        let decoded = try JSONDecoder().decode(Link.self, from: data)
        #expect(decoded.scheduledOpenAt == fireAt)
    }

    @Test func testLinkDecodesLegacyMissingScheduledOpenAt() throws {
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-0000000000aa",
            "title": "Legacy",
            "url": "https://legacy.example.com"
        }
        """.data(using: .utf8)!
        let link = try JSONDecoder().decode(Link.self, from: legacyJSON)
        #expect(link.scheduledOpenAt == nil)
    }

    @Test func testScheduleLinkSetsDate() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        let fireAt = Date(timeIntervalSinceNow: 60)
        model.scheduleLink(id: linkId, at: fireAt)

        guard let node = model.nodeById(linkId), case .link(let link) = node else {
            Issue.record("Expected link"); return
        }
        #expect(link.scheduledOpenAt == fireAt)
    }

    @Test func testCancelScheduleClearsDate() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        model.scheduleLink(id: linkId, at: Date(timeIntervalSinceNow: 60))
        model.cancelSchedule(id: linkId)

        guard let node = model.nodeById(linkId), case .link(let link) = node else {
            Issue.record("Expected link"); return
        }
        #expect(link.scheduledOpenAt == nil)
    }

    @Test func testDeleteNodeRemovesScheduledLinkFromState() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let linkId = model.addLink(urlString: "https://a.com", title: "A", parentId: nil)
        model.scheduleLink(id: linkId, at: Date(timeIntervalSinceNow: 60))
        #expect(model.allScheduledLinks().count == 1)

        model.deleteNode(id: linkId)
        #expect(model.allScheduledLinks().count == 0)
    }

    @Test func testAllScheduledLinksWalksFoldersAndWorkspaces() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        // Workspace A: nested folder containing a scheduled link
        let folderId = model.addFolder(name: "Folder", parentId: nil)
        let nestedFolderId = model.addFolder(name: "Nested", parentId: folderId)
        let nestedLinkId = model.addLink(urlString: "https://nested.com", title: "Nested", parentId: nestedFolderId)
        model.scheduleLink(id: nestedLinkId, at: Date(timeIntervalSince1970: 1_000_000))

        // Workspace B: top-level scheduled link
        let workspaceBId = model.createWorkspace(name: "B", colorId: .moss)
        let topLinkId = model.addLink(urlString: "https://top.com", title: "Top", parentId: nil)
        model.scheduleLink(id: topLinkId, at: Date(timeIntervalSince1970: 2_000_000))

        // Switch back so we exercise cross-workspace traversal
        model.selectWorkspace(id: workspaceBId)

        let scheduled = model.allScheduledLinks()
        #expect(scheduled.count == 2)
        let linkIds = Set(scheduled.map { $0.linkId })
        #expect(linkIds == Set([nestedLinkId, topLinkId]))
    }

    @Test func testMultipleBrowserProfiles() {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)

        let profileId = model.currentProfile.id

        model.updateBrowserProfile(profileId: profileId, bundleId: "com.google.chrome", profile: "Profile 1")
        model.updateBrowserProfile(profileId: profileId, bundleId: "org.mozilla.firefox", profile: "default")

        #expect(model.currentProfile.browserProfiles.count == 2)
        #expect(model.currentProfile.browserProfiles["com.google.chrome"] == "Profile 1")
        #expect(model.currentProfile.browserProfiles["org.mozilla.firefox"] == "default")

        // Clear Chrome profile, Firefox should remain
        model.updateBrowserProfile(profileId: profileId, bundleId: "com.google.chrome", profile: nil)
        #expect(model.currentProfile.browserProfiles.count == 1)
        #expect(model.currentProfile.browserProfiles["com.google.chrome"] == nil)
        #expect(model.currentProfile.browserProfiles["org.mozilla.firefox"] == "default")
    }
}
