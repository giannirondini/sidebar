import Foundation
import Testing
@testable import SidebArcCore

@Suite struct SchemaMigrationTests {
    private let scratch = TempDir()
    private let testDefaults = TestDefaults()
    // MARK: - Fixtures

    private func makeTempDirectory() -> URL {
        scratch.url.appendingPathComponent(UUID().uuidString)
    }

    private func link(_ url: String, _ title: String? = nil) -> Link {
        Link(id: UUID(), title: title ?? url, url: url, faviconPath: nil)
    }

    private func v1Workspace(
        _ name: String,
        items: [Node] = [],
        pinned: [Link] = [],
        browserProfiles: [String: String] = [:]
    ) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "name": name,
            "colorId": "ember",
            "items": items.map(jsonObject),
            "pinnedLinks": pinned.map { jsonObject($0) },
            "browserProfiles": browserProfiles
        ]
    }

    private func jsonObject<T: Encodable>(_ value: T) -> Any {
        let data = try! JSONEncoder().encode(value)
        return try! JSONSerialization.jsonObject(with: data)
    }

    private func v1Data(_ workspaces: [[String: Any]], selected: Int? = 0) -> Data {
        var root: [String: Any] = ["schemaVersion": 1, "workspaces": workspaces, "isSettingsSelected": false]
        if let selected { root["selectedWorkspaceId"] = workspaces[selected]["id"] }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func decodeV1(_ data: Data) throws -> SchemaV1.AppState {
        try JSONDecoder().decode(SchemaV1.AppState.self, from: data)
    }

    private func allLinkIds(in nodes: [Node]) -> [UUID] {
        nodes.flatMap { node -> [UUID] in
            switch node {
            case .link(let link): return [link.id]
            case .folder(let folder): return allLinkIds(in: folder.children)
            case .note: return []
            }
        }
    }

    // MARK: - V1 decoding

    @Test func v1DecodesWithoutPinnedLinksOrBrowserProfiles() throws {
        let json = """
        {
            "schemaVersion": 1,
            "workspaces": [{
                "id": "00000000-0000-0000-0000-000000000001",
                "name": "Old Workspace",
                "colorId": "ember",
                "items": []
            }],
            "selectedWorkspaceId": "00000000-0000-0000-0000-000000000001",
            "isSettingsSelected": false
        }
        """
        let decoded = try decodeV1(Data(json.utf8))
        #expect(decoded.workspaces[safe: 0]?.pinnedLinks.isEmpty == true)
        #expect(decoded.workspaces[safe: 0]?.browserProfiles.isEmpty == true)
        #expect(decoded.workspaces[safe: 0]?.name == "Old Workspace")
    }

    @Test func v1DecodesSingleProfileLegacyFormat() throws {
        let json = """
        {
            "schemaVersion": 1,
            "workspaces": [{
                "id": "00000000-0000-0000-0000-000000000003",
                "name": "Migrated Workspace",
                "colorId": "ocean",
                "items": [],
                "pinnedLinks": [],
                "browserProfile": "Profile 1",
                "browserProfileBundleId": "com.google.chrome"
            }],
            "isSettingsSelected": false
        }
        """
        let decoded = try decodeV1(Data(json.utf8))
        #expect(decoded.workspaces[safe: 0]?.browserProfiles == ["com.google.chrome": "Profile 1"])
    }

    @Test func v2DecoderRejectsV1Workspaces() {
        // v1 workspaces have no profileId: they must go through SchemaV1, never AppState.
        let data = v1Data([v1Workspace("A")])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(AppState.self, from: data) }
    }

    // MARK: - Grouping

    @Test func spacesWithIdenticalBrowserProfilesShareAProfile() throws {
        let chrome = ["com.google.chrome": "Profile 1"]
        let data = v1Data([
            v1Workspace("A", browserProfiles: chrome),
            v1Workspace("B"),
            v1Workspace("C", browserProfiles: chrome),
            v1Workspace("D", browserProfiles: ["com.google.chrome": "Profile 1", "org.mozilla.firefox": "x"])
        ])
        let old = try decodeV1(data)
        let state = SchemaMigration.v1ToV2(old)

        #expect(state.schemaVersion == 2)
        #expect(state.profiles.map(\.name) == ["Default", "Profile 2", "Profile 3"])
        #expect(state.profiles.map(\.browserProfiles) == [chrome, [:], ["com.google.chrome": "Profile 1", "org.mozilla.firefox": "x"]])
        #expect(state.profiles.allSatisfy { $0.browserBundleId == nil })

        let ids = state.profiles.map(\.id)
        #expect(state.workspaces.map(\.profileId) == [ids[0], ids[1], ids[0], ids[2]])
        #expect(state.workspaces.map(\.id) == old.workspaces.map(\.id))
        #expect(state.workspaces.map(\.name) == ["A", "B", "C", "D"])
        #expect(state.selectedWorkspaceId == old.workspaces[safe: 0]?.id)
    }

    @Test func migrationPreservesWhereEachSpaceOpensLinks() throws {
        // For any global browser X, profile.browserProfiles[X] must equal the v1 workspace's value.
        let data = v1Data([
            v1Workspace("A", browserProfiles: ["com.google.chrome": "Profile 1"]),
            v1Workspace("B", browserProfiles: ["org.mozilla.firefox": "work"]),
            v1Workspace("C")
        ])
        let old = try decodeV1(data)
        let state = SchemaMigration.v1ToV2(old)
        for (oldSpace, newSpace) in zip(old.workspaces, state.workspaces) {
            let profile = try #require(state.profiles.first(where: { $0.id == newSpace.profileId }))
            for browser in ["com.google.chrome", "org.mozilla.firefox", "com.apple.Safari"] {
                #expect(profile.browserProfiles[browser] == oldSpace.browserProfiles[browser])
            }
            #expect(profile.browserBundleId == nil)
        }
    }

    @Test func emptyV1StateGetsADefaultProfile() throws {
        let root: [String: Any] = ["schemaVersion": 1, "workspaces": [], "isSettingsSelected": true]
        let state = SchemaMigration.v1ToV2(try decodeV1(JSONSerialization.data(withJSONObject: root)))
        #expect(state.profiles.map(\.name) == ["Default"])
        #expect(state.workspaces.isEmpty)
    }

    // MARK: - Favorites: dedupe and overflow

    @Test func favoritesAreUnionedInSpaceOrderAndDuplicatesGoToSourceSpaceFolder() throws {
        let x = link("https://x.com")
        let y = link("https://y.com")
        let xAgain = link("HTTPS://X.COM/", "X again")
        let z = link("https://z.com")
        let existing = link("https://existing.com")
        let data = v1Data([
            v1Workspace("A", pinned: [x, y]),
            v1Workspace("C", items: [.link(existing)], pinned: [xAgain, z])
        ])
        let state = SchemaMigration.v1ToV2(try decodeV1(data))

        #expect(state.profiles.count == 1)
        #expect(state.profiles[safe: 0]?.favorites.map(\.id) == [x.id, y.id, z.id])
        #expect(state.workspaces[safe: 0]?.items.isEmpty == true)

        guard case .folder(let folder) = state.workspaces[safe: 1]?.items.first else {
            Issue.record("Expected the migrated-favorites folder at the top of C")
            return
        }
        #expect(folder.name == SchemaMigration.migratedFavoritesFolderName)
        #expect(folder.isExpanded)
        #expect(allLinkIds(in: folder.children) == [xAgain.id])
        #expect(state.workspaces[safe: 1]?.items.dropFirst().map(\.id) == [existing.id])
    }

    @Test func overflowBeyondCapGoesToFolderInItsOwnSourceSpace() throws {
        let cap = Profile.maxFavorites
        let first = (0..<(cap - 2)).map { link("https://a\($0).com") }
        let second = (0..<5).map { link("https://b\($0).com") }
        let data = v1Data([v1Workspace("A", pinned: first), v1Workspace("B", pinned: second)])
        let state = SchemaMigration.v1ToV2(try decodeV1(data))

        #expect(state.profiles[safe: 0]?.favorites.count == cap)
        #expect(state.profiles[safe: 0]?.favorites.map(\.id) == first.map(\.id) + second.prefix(2).map(\.id))
        // A fitted entirely: no folder there.
        #expect(state.workspaces[safe: 0]?.items.isEmpty == true)
        guard case .folder(let folder) = state.workspaces[safe: 1]?.items.first else {
            Issue.record("Expected overflow folder in B")
            return
        }
        #expect(allLinkIds(in: folder.children) == second.suffix(3).map(\.id))
    }

    @Test func separateProfilesHaveSeparateCapsAndNoCrossProfileDedupe() throws {
        let shared = "https://same.com"
        let data = v1Data([
            v1Workspace("A", pinned: [link(shared)]),
            v1Workspace("B", pinned: [link(shared)], browserProfiles: ["com.google.chrome": "Work"])
        ])
        let state = SchemaMigration.v1ToV2(try decodeV1(data))
        #expect(state.profiles.map { $0.favorites.count } == [1, 1])
        #expect(state.workspaces.allSatisfy { $0.items.isEmpty })
    }

    @Test func migrationNeverLosesALink() throws {
        let cap = Profile.maxFavorites
        let nestedFolder = Folder(id: UUID(), name: "F", children: [.link(link("https://nested.com"))], isExpanded: false)
        let workspaces = [
            v1Workspace("A", items: [.folder(nestedFolder), .link(link("https://tree.com"))],
                        pinned: (0..<(cap + 3)).map { link("https://a\($0).com") }),
            v1Workspace("B", pinned: [link("https://a0.com"), link("https://a1.com/#frag"), link("https://new.com")]),
            v1Workspace("C", pinned: [link("https://a0.com")], browserProfiles: ["x": "y"])
        ]
        let old = try decodeV1(v1Data(workspaces))
        let before = old.workspaces.flatMap { allLinkIds(in: $0.items) + $0.pinnedLinks.map(\.id) }

        let state = SchemaMigration.v1ToV2(old)
        let after = state.workspaces.flatMap { allLinkIds(in: $0.items) } + state.profiles.flatMap { $0.favorites.map(\.id) }

        #expect(before.count == after.count)
        #expect(Set(before) == Set(after))
    }

    // MARK: - Profile.appendFavorites

    @Test func appendFavoritesSkipsExistingAndStopsAtCap() {
        var profile = Profile(name: "P", favorites: [link("https://a.com")])
        let leftovers = profile.appendFavorites([link("https://A.com/"), link("https://b.com")])
        #expect(profile.favorites.map(\.url) == ["https://a.com", "https://b.com"])
        #expect(leftovers.map(\.url) == ["https://A.com/"])

        var full = Profile(name: "Full", favorites: (0..<Profile.maxFavorites).map { link("https://f\($0).com") })
        let spill = full.appendFavorites([link("https://late.com")])
        #expect(full.favorites.count == Profile.maxFavorites)
        #expect(spill.map(\.url) == ["https://late.com"])
    }

    // MARK: - URL normalisation

    @Test(arguments: [
        ("https://Example.COM/", "https://example.com"),
        ("HTTPS://example.com/path/", "https://example.com/path"),
        ("https://example.com:443/a", "https://example.com/a"),
        ("http://example.com:80/a", "http://example.com/a"),
        ("https://example.com/a#section", "https://example.com/a"),
        ("  https://example.com  ", "https://example.com"),
    ])
    func normalisationMergesEquivalentURLs(input: String, expected: String) {
        #expect(URLNormalization.key(for: input) == URLNormalization.key(for: expected))
    }

    @Test(arguments: [
        ("https://example.com/a?q=1", "https://example.com/a?q=2"),
        ("https://www.example.com", "https://example.com"),
        ("https://example.com:8443", "https://example.com"),
        ("http://example.com", "https://example.com"),
        ("https://example.com/Path", "https://example.com/path"),
    ])
    func normalisationKeepsDistinctURLsApart(lhs: String, rhs: String) {
        #expect(URLNormalization.key(for: lhs) != URLNormalization.key(for: rhs))
    }

    // MARK: - DataStore integration

    @Test func dataStoreMigratesV1FileAndKeepsAPreMigrationCopy() throws {
        let directory = makeTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = v1Data([v1Workspace("A", pinned: [link("https://a.com")])])
        try original.write(to: directory.appendingPathComponent("data.json"))

        let state = DataStore(baseDirectory: directory).load()
        #expect(state.schemaVersion == 2)
        #expect(state.profiles[safe: 0]?.favorites.count == 1)

        // Persisted immediately as v2.
        let onDisk = try Data(contentsOf: directory.appendingPathComponent("data.json"))
        let probe = try JSONDecoder().decode(SchemaVersionProbe.self, from: onDisk)
        #expect(probe.schemaVersion == 2)

        // Non-rotating copy of the exact v1 bytes.
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil
        )
        let copies = backups.filter { $0.lastPathComponent.hasPrefix("pre-v2-migration-") }
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: try #require(copies.first)) == original)

        // Second launch reads v2 with the same profile ids, and doesn't migrate again.
        let reloaded = DataStore(baseDirectory: directory).load()
        #expect(deeplyEqual(reloaded, state))
        let backupsAfter = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil
        )
        #expect(backupsAfter.filter { $0.lastPathComponent.hasPrefix("pre-v2-migration-") }.count == 1)
    }

    /// Without the pre-migration copy, the v1 file must stay as it is: no save may
    /// replace it (the rotating backups live in the same unwritable folder).
    @Test(.disabled(if: getuid() == 0, "root writes into read-only folders"))
    func v1FileIsNeverOverwrittenWhenThePreMigrationCopyFails() throws {
        let fileManager = FileManager.default
        let directory = makeTempDirectory()
        let backups = directory.appendingPathComponent("Backups")
        let dataURL = directory.appendingPathComponent("data.json")
        try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let original = v1Data([v1Workspace("A", items: [.link(link("https://b.com"))], pinned: [link("https://a.com")])])
        try original.write(to: dataURL)

        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: backups.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backups.path) }
        // Not vacuous: the folder really refuses writes.
        try #require(throws: (any Error).self) {
            try Data("probe".utf8).write(to: backups.appendingPathComponent("probe"))
        }

        let model = AppModel(store: DataStore(baseDirectory: directory), defaults: testDefaults.suite)
        var copyFailureReported = false
        if case .migrationCopyFailed = model.dataLoadIssue { copyFailureReported = true }
        #expect(copyFailureReported, "load issue: \(String(describing: model.dataLoadIssue))")
        model.renameWorkspace(id: model.currentWorkspace.id, newName: "Changed")
        #expect(try Data(contentsOf: dataURL) == original)
        #expect(throws: (any Error).self) { try model.startEmptyLibrary() }
        #expect(try Data(contentsOf: dataURL) == original)

        // Once Backups/ is writable again, the next launch migrates and keeps the copy.
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: backups.path)
        let store = DataStore(baseDirectory: directory)
        let relaunched = AppModel(store: store, defaults: testDefaults.suite)
        #expect(relaunched.dataLoadIssue == nil)
        #expect(relaunched.state.profiles[safe: 0]?.favorites.map(\.url) == ["https://a.com"])
        let copies = try fileManager.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pre-v2-migration-") }
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: try #require(copies.first)) == original)
        let saved = try DataStore.decodeState(from: Data(contentsOf: dataURL))
        #expect(saved.schemaVersion == AppState.currentSchemaVersion)
        expectPersisted(relaunched, in: store)
    }

    @Test func dataStoreRepairsV2FileMissingProfiles() throws {
        let directory = makeTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        {
            "schemaVersion": 2,
            "workspaces": [{
                "id": "00000000-0000-0000-0000-000000000001",
                "name": "A",
                "colorId": "ember",
                "items": [],
                "profileId": "00000000-0000-0000-0000-0000000000FF"
            }],
            "isSettingsSelected": false
        }
        """
        try Data(json.utf8).write(to: directory.appendingPathComponent("data.json"))

        let state = DataStore(baseDirectory: directory).load()
        #expect(state.profiles.count == 1)
        #expect(state.workspaces[safe: 0]?.profileId == state.profiles[safe: 0]?.id)
        #expect(state.workspaces[safe: 0]?.name == "A")
    }

    // MARK: - Opt-in acceptance check against a real v1 data.json

    /// Set SIDEBARC_V1_FIXTURE to a **copy** of a real v1 data.json to run this.
    /// The copy is migrated in a temp directory; the source file is only read.
    /// Prints only counts, never titles or URLs.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEBARC_V1_FIXTURE"] != nil))
    func realV1FileMigratesWithZeroLostLinks() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SIDEBARC_V1_FIXTURE"])
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let old = try decodeV1(original)
        let before = old.workspaces.flatMap { allLinkIds(in: $0.items) + $0.pinnedLinks.map(\.id) }

        let directory = makeTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try original.write(to: directory.appendingPathComponent("data.json"))

        let state = DataStore(baseDirectory: directory).load()
        let after = state.workspaces.flatMap { allLinkIds(in: $0.items) } + state.profiles.flatMap { $0.favorites.map(\.id) }
        let folders = state.workspaces.flatMap(\.items).compactMap { node -> Int? in
            if case .folder(let folder) = node, folder.name == SchemaMigration.migratedFavoritesFolderName { return folder.children.count }
            return nil
        }
        print("v1 fixture: \(old.workspaces.count) spaces, \(old.workspaces.reduce(0) { $0 + $1.pinnedLinks.count }) pinned links, \(before.count) links total")
        print("v2 result: \(state.profiles.count) profile(s), favorites \(state.profiles.map { $0.favorites.count }), \(folders.count) migrated folder(s) holding \(folders.reduce(0, +)) links, \(after.count) links total")

        #expect(state.schemaVersion == 2)
        #expect(before.count == after.count)
        #expect(Set(before) == Set(after))
        #expect(state.workspaces.map(\.id) == old.workspaces.map(\.id))
        // Re-reading gives the same state (persisted once, no second migration).
        #expect(deeplyEqual(DataStore(baseDirectory: directory).load(), state))
    }
}
