import Foundation
import Testing
@testable import SidebArcCore

/// Export and import (Phase 3b.3). Two temporary data folders stand in for two Macs
/// with different home folders; nothing touches the real data directory.
@Suite struct DataTransferTests {
    private let root: URL
    private let macA: URL
    private let macB: URL
    private let exports: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DataTransferTests-\(UUID().uuidString)")
        macA = root.appendingPathComponent("A/Application Support/sidebarc", isDirectory: true)
        macB = root.appendingPathComponent("B/Application Support/sidebarc", isDirectory: true)
        exports = root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
    }

    // MARK: - Fixtures

    private struct Source {
        let model: AppModel
        let store: DataStore
        let linkId: UUID
        let nestedLinkId: UUID
        let noteId: UUID
        let favoriteId: UUID
    }

    /// Mac A: a link with a favicon and a custom favicon icon, a nested link, a note
    /// with a body and an icon, a space icon, a favorite with a favicon.
    private func makeSource() throws -> Source {
        let store = DataStore(baseDirectory: macA)
        let model = AppModel(store: store)
        let icons = store.iconsDirectory()
        for name in ["example.com.ico", "custom.ico", "note.ico", "space.ico", "favorite.ico"] {
            try Data([1, 2, 3]).write(to: icons.appendingPathComponent(name))
        }

        let linkId = model.addLink(urlString: "https://example.com", title: "Example", parentId: nil)
        model.updateLinkFaviconPath(id: linkId, path: icons.appendingPathComponent("example.com.ico").path)
        model.setLinkCustomIcon(id: linkId, icon: .cachedFavicon(icons.appendingPathComponent("custom.ico").path))

        let folderId = model.addFolder(name: "Folder", parentId: nil)
        let nestedLinkId = model.addLink(urlString: "https://nested.example", title: "Nested", parentId: folderId)
        model.updateLinkFaviconPath(id: nestedLinkId, path: icons.appendingPathComponent("example.com.ico").path)

        let noteId = model.addNote(title: "Note", parentId: nil, content: "# Body")
        model.setNoteCustomIcon(id: noteId, icon: .cachedFavicon(icons.appendingPathComponent("note.ico").path))

        model.setWorkspaceIcon(id: model.currentWorkspace.id, icon: .cachedFavicon(icons.appendingPathComponent("space.ico").path))

        let favoriteId = model.addLink(urlString: "https://favorite.example", title: "Favorite", parentId: nil)
        model.pinLink(id: favoriteId)
        model.updatePinnedLinkFaviconPath(id: favoriteId, path: icons.appendingPathComponent("favorite.ico").path)

        return Source(model: model, store: store, linkId: linkId, nestedLinkId: nestedLinkId, noteId: noteId, favoriteId: favoriteId)
    }

    private func link(_ id: UUID, in state: AppState) -> Link? {
        func find(_ nodes: [Node]) -> Link? {
            for node in nodes {
                switch node {
                case .link(let link) where link.id == id: return link
                case .folder(let folder): if let found = find(folder.children) { return found }
                default: continue
                }
            }
            return nil
        }
        return state.workspaces.lazy.compactMap { find($0.items) }.first
    }

    private func note(_ id: UUID, in state: AppState) -> Note? {
        for workspace in state.workspaces {
            for case .note(let note) in workspace.items where note.id == id { return note }
        }
        return nil
    }

    /// Writes an export-shaped folder by hand, for the refusal cases.
    private func makeFolder(manifest: [String: Any]?, data: Data?) throws -> URL {
        let folder = exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let manifest {
            try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent(DataTransfer.manifestFileName))
        }
        if let data {
            try data.write(to: folder.appendingPathComponent(DataTransfer.dataFileName))
        }
        return folder
    }

    private func validManifest(schemaVersion: Int = AppState.currentSchemaVersion, formatVersion: Int = DataTransfer.formatVersion) -> [String: Any] {
        [
            "format": DataTransfer.format,
            "formatVersion": formatVersion,
            "schemaVersion": schemaVersion,
            "exportedAt": "2026-11-15T10:00:00Z"
        ]
    }

    private func currentData() throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(DataStore.defaultState())
    }

    // MARK: - Export

    @Test func exportWritesManifestDataNotesAndIconsOnly() throws {
        let source = try makeSource()
        // Files that must stay out of an export.
        try Data("token".utf8).write(to: source.store.agentEndpointFileURL())
        source.store.save(source.model.state)   // creates Backups/ (once per session)

        let now = Date(timeIntervalSince1970: 1_763_200_000)
        let folder = try DataTransfer.export(store: source.store, to: exports, now: now, appVersion: "1.0.0")

        #expect(folder.lastPathComponent.hasPrefix("SidebArc Export "))
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == ["export.json", "data.json", "Notes", "Icons"])
        #expect(try Data(contentsOf: folder.appendingPathComponent("data.json")) == Data(contentsOf: source.store.dataFileURL))
        #expect(try String(contentsOf: folder.appendingPathComponent("Notes/\(source.noteId.uuidString).md"), encoding: .utf8) == "# Body")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Icons/custom.ico").path))

        let package = try DataTransfer.readPackage(at: folder)
        #expect(package.manifest.format == DataTransfer.format)
        #expect(package.manifest.formatVersion == DataTransfer.formatVersion)
        #expect(package.manifest.schemaVersion == AppState.currentSchemaVersion)
        #expect(package.manifest.exportedAt == now)
        #expect(package.manifest.appVersion == "1.0.0")
    }

    @Test func exportNeverOverwritesAnExistingFolder() throws {
        let source = try makeSource()
        let now = Date()
        let first = try DataTransfer.export(store: source.store, to: exports, now: now)
        let second = try DataTransfer.export(store: source.store, to: exports, now: now)
        #expect(first != second)
        #expect(second.lastPathComponent == first.lastPathComponent + " 2")
    }

    // MARK: - Import

    @Test func importOnAnotherMacRestoresEverythingWithLocalIconPaths() throws {
        let source = try makeSource()
        let folder = try DataTransfer.export(store: source.store, to: exports)
        let package = try DataTransfer.readPackage(at: folder)

        let storeB = DataStore(baseDirectory: macB)
        let modelB = AppModel(store: storeB)
        var changes = 0
        modelB.onChange = { changes += 1 }
        try modelB.applyDataImport(package)

        #expect(changes == 1)
        let iconsB = storeB.iconsDirectory()
        let state = modelB.state
        #expect(state.workspaces.map(\.name) == source.model.state.workspaces.map(\.name))
        #expect(state.profiles.map(\.id) == source.model.state.profiles.map(\.id))
        #expect(state.selectedWorkspaceId == source.model.state.selectedWorkspaceId)

        let linkB = try #require(link(source.linkId, in: state))
        #expect(linkB.faviconPath == iconsB.appendingPathComponent("example.com.ico").path)
        #expect(linkB.customIcon == .cachedFavicon(iconsB.appendingPathComponent("custom.ico").path))
        #expect(link(source.nestedLinkId, in: state)?.faviconPath == iconsB.appendingPathComponent("example.com.ico").path)
        #expect(note(source.noteId, in: state)?.customIcon == .cachedFavicon(iconsB.appendingPathComponent("note.ico").path))
        #expect(state.workspaces[0].icon == .cachedFavicon(iconsB.appendingPathComponent("space.ico").path))
        let favorite = try #require(state.profiles.flatMap(\.favorites).first { $0.id == source.favoriteId })
        #expect(favorite.faviconPath == iconsB.appendingPathComponent("favorite.ico").path)

        for name in ["example.com.ico", "custom.ico", "note.ico", "space.ico", "favorite.ico"] {
            #expect(FileManager.default.fileExists(atPath: iconsB.appendingPathComponent(name).path))
        }
        #expect(modelB.noteStorage.read(id: source.noteId) == "# Body")

        // Persisted: a fresh load on Mac B sees the imported state.
        #expect(deeplyEqual(DataStore(baseDirectory: macB).load(), state))
    }

    @Test func importBacksUpThePreviousDataAndNotes() throws {
        let source = try makeSource()
        let package = try DataTransfer.readPackage(at: try DataTransfer.export(store: source.store, to: exports))

        let storeB = DataStore(baseDirectory: macB)
        let modelB = AppModel(store: storeB)
        let localNote = modelB.addNote(title: "Local", parentId: nil, content: "local body")
        let previousData = try Data(contentsOf: storeB.dataFileURL)

        let backup = try modelB.applyDataImport(package)

        #expect(backup.deletingLastPathComponent().lastPathComponent == "Backups")
        #expect(backup.lastPathComponent.hasPrefix("pre-import-"))
        #expect(try Data(contentsOf: backup.appendingPathComponent("data.json")) == previousData)
        #expect(try String(contentsOf: backup.appendingPathComponent("Notes/\(localNote.uuidString).md"), encoding: .utf8) == "local body")
        // Local notes the export doesn't have are left alone.
        #expect(modelB.noteStorage.read(id: localNote) == "local body")
    }

    @Test(arguments: [false, true])
    func importBacksUpUndecodableLiveBytes(hasSchemaVersion: Bool) throws {
        let source = try makeSource()
        let package = try DataTransfer.readPackage(at: try DataTransfer.export(store: source.store, to: exports))
        let store = DataStore(baseDirectory: macB)
        let model = AppModel(store: store)
        let localNote = model.addNote(title: "Local", parentId: nil, content: "keep body")
        let original: Data
        if hasSchemaVersion {
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.dataFileURL)) as? [String: Any])
            var workspaces = try #require(object["workspaces"] as? [[String: Any]])
            workspaces[0]["items"] = [["type": "future-node"]]
            object["workspaces"] = workspaces
            original = try JSONSerialization.data(withJSONObject: object)
        } else {
            original = Data("invalid json".utf8)
        }
        try original.write(to: store.dataFileURL)

        let backup = try model.applyDataImport(package)

        #expect(try Data(contentsOf: backup.appendingPathComponent("data.json")) == original)
        #expect(try String(contentsOf: backup.appendingPathComponent("Notes/\(localNote.uuidString).md"), encoding: .utf8) == "keep body")
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("export.json").path) == hasSchemaVersion)
        #expect(DataStore(baseDirectory: macB).load().workspaces.map(\.id) == source.model.state.workspaces.map(\.id))
    }

    @Test func importDoesNotReplaceAStartupBlockedLibrary() throws {
        let source = try makeSource()
        let package = try DataTransfer.readPackage(at: try DataTransfer.export(store: source.store, to: exports))
        try FileManager.default.createDirectory(at: macB, withIntermediateDirectories: true)
        let original = Data("invalid json".utf8)
        let store = DataStore(baseDirectory: macB)
        try original.write(to: store.dataFileURL)
        let model = AppModel(store: store)
        #expect(throws: (any Error).self) { try model.applyDataImport(package) }
        #expect(try Data(contentsOf: store.dataFileURL) == original)
    }

    @Test func importingThePreImportBackupUndoesTheImport() throws {
        let source = try makeSource()
        let package = try DataTransfer.readPackage(at: try DataTransfer.export(store: source.store, to: exports))

        let storeB = DataStore(baseDirectory: macB)
        let modelB = AppModel(store: storeB)
        let folder = modelB.addFolder(name: "Local folder", parentId: nil)
        _ = modelB.addLink(urlString: "https://local.example", title: "Local", parentId: folder)
        let before = modelB.state

        let backup = try modelB.applyDataImport(package)
        #expect(!deeplyEqual(modelB.state, before))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: backup.path)) == ["export.json", "data.json", "Notes", "Icons"])

        try modelB.applyDataImport(try DataTransfer.readPackage(at: backup))
        #expect(deeplyEqual(modelB.state, before))
        expectPersisted(modelB, in: storeB)
    }

    @Test func importOnTheSameMacKeepsPaths() throws {
        let source = try makeSource()
        let before = source.model.state
        let package = try DataTransfer.readPackage(at: try DataTransfer.export(store: source.store, to: exports))
        try source.model.applyDataImport(package)
        #expect(deeplyEqual(source.model.state, before))
        expectPersisted(source.model, in: source.store)
    }

    @Test func importMigratesAV1Export() throws {
        let workspaceId = UUID()
        let v1: [String: Any] = [
            "schemaVersion": 1,
            "workspaces": [[
                "id": workspaceId.uuidString, "name": "Old", "colorId": "ember", "items": [],
                "pinnedLinks": [["id": UUID().uuidString, "title": "Pinned", "url": "https://pinned.example"]],
                "browserProfiles": [String: String]()
            ]],
            "selectedWorkspaceId": workspaceId.uuidString
        ]
        let folder = try makeFolder(manifest: validManifest(schemaVersion: 1), data: try JSONSerialization.data(withJSONObject: v1))

        let package = try DataTransfer.readPackage(at: folder)
        let modelB = AppModel(store: DataStore(baseDirectory: macB))
        try modelB.applyDataImport(package)

        #expect(modelB.state.schemaVersion == AppState.currentSchemaVersion)
        #expect(modelB.state.workspaces.map(\.name) == ["Old"])
        #expect(modelB.state.profiles.flatMap(\.favorites).map(\.title) == ["Pinned"])
    }

    @Test func refusalsLeaveTheDataUntouched() throws {
        let storeB = DataStore(baseDirectory: macB)
        let modelB = AppModel(store: storeB)
        _ = modelB.addLink(urlString: "https://keep.example", title: "Keep", parentId: nil)
        let before = try Data(contentsOf: storeB.dataFileURL)
        let valid = try currentData()

        var newer = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        newer["schemaVersion"] = AppState.currentSchemaVersion + 1
        var otherFormat = validManifest()
        otherFormat["format"] = "com.example.other"

        let cases: [(URL, DataTransfer.TransferError)] = [
            // The data folder itself and a bare data.json folder have no manifest.
            (macB, .notAnExport),
            (try makeFolder(manifest: nil, data: valid), .notAnExport),
            (try makeFolder(manifest: otherFormat, data: valid), .notAnExport),
            (try makeFolder(manifest: validManifest(formatVersion: DataTransfer.formatVersion + 1), data: valid), .unsupportedFormatVersion(DataTransfer.formatVersion + 1)),
            (try makeFolder(manifest: validManifest(), data: nil), .missingDataFile),
            (try makeFolder(manifest: validManifest(), data: try JSONSerialization.data(withJSONObject: newer)), .newerSchema(AppState.currentSchemaVersion + 1)),
        ]
        for (folder, expected) in cases {
            #expect(throws: expected) { try DataTransfer.readPackage(at: folder) }
        }

        let corrupt = try makeFolder(manifest: validManifest(), data: Data("{ not json".utf8))
        #expect {
            try DataTransfer.readPackage(at: corrupt)
        } throws: { error in
            if case .unreadableDataFile = error as? DataTransfer.TransferError { return true }
            return false
        }
        newer["workspaces"] = [["items": [["type": "future-node"]]]]
        let newerUnknown = try makeFolder(manifest: validManifest(), data: JSONSerialization.data(withJSONObject: newer))
        #expect(throws: DataTransfer.TransferError.newerSchema(AppState.currentSchemaVersion + 1)) {
            try DataTransfer.readPackage(at: newerUnknown)
        }

        #expect(try Data(contentsOf: storeB.dataFileURL) == before)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: macB.appendingPathComponent("Backups").path)) ?? []
        #expect(backups.allSatisfy { !$0.hasPrefix("pre-import-") })
    }

    @Test func backupWithLegacyLinkURLsCanBeRestored() throws {
        let source = try makeSource()
        let package = try DataTransfer.readPackage(at: try DataTransfer.export(store: source.store, to: exports))
        var state = DataStore.defaultState()
        let favorite = Link(id: UUID(), title: "Flag", url: "--renderer-cmd-prefix=/tmp/x", faviconPath: nil)
        let legacy = Link(id: UUID(), title: "File", url: "file:///tmp/run.command", faviconPath: nil)
        state.profiles[0].favorites = [favorite]
        state.workspaces[0].items = [.folder(Folder(id: UUID(), name: "Folder", children: [.link(legacy)], isExpanded: true))]
        let store = DataStore(baseDirectory: macB)
        store.save(state)
        let model = AppModel(store: store)

        let backup = try model.applyDataImport(package)
        try model.applyDataImport(DataTransfer.readPackage(at: backup))

        let restored = AppModel(store: store).state
        #expect(restored.profiles[0].favorites.first?.url == favorite.url)
        #expect(link(legacy.id, in: restored)?.url == legacy.url)
        #expect(BrowserManager.validatedLinkURL(from: favorite.url) == nil)
        #expect(BrowserManager.validatedLinkURL(from: legacy.url) == nil)
    }

    // MARK: - Pure parts

    @Test func remapDropsFaviconsOutsideIconsAndKeepsOtherCustomIcons() {
        let profile = Profile.makeDefault()
        let elsewhereFavicon = Link(id: UUID(), title: "A", url: "https://a.example", faviconPath: "/tmp/cache/a.ico")
        var elsewhereIcon = Link(id: UUID(), title: "B", url: "https://b.example", faviconPath: nil)
        elsewhereIcon.customIcon = .cachedFavicon("/Users/x/Pictures/b.png")
        var emoji = Link(id: UUID(), title: "C", url: "https://c.example", faviconPath: nil)
        emoji.customIcon = .emoji("🚀")
        let workspace = Workspace(
            id: UUID(), name: "S", colorId: .defaultColor(),
            items: [.link(elsewhereFavicon), .link(elsewhereIcon), .link(emoji)],
            profileId: profile.id
        )
        let state = AppState(profiles: [profile], workspaces: [workspace], selectedWorkspaceId: workspace.id)

        let remapped = DataTransfer.remapIconPaths(in: state, iconsDirectory: macB.appendingPathComponent("Icons"))

        #expect(link(elsewhereFavicon.id, in: remapped)?.faviconPath == nil)
        #expect(link(elsewhereIcon.id, in: remapped)?.customIcon == .cachedFavicon("/Users/x/Pictures/b.png"))
        #expect(link(emoji.id, in: remapped)?.customIcon == .emoji("🚀"))
    }

    @Test func summaryCountsSpacesLinksFavoritesAndNotes() throws {
        let source = try makeSource()
        let summary = DataTransfer.summary(of: source.model.state)
        #expect(summary == DataTransfer.Summary(profiles: 1, spaces: 1, links: 2, favorites: 1, notes: 1))
    }
}
