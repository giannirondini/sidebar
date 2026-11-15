import Foundation
import Testing
@testable import SidebArcCore

@Suite struct DataStoreBackupTests {
    private let scratch = TempDir()
    private let testDefaults = TestDefaults()
    private func makeTempDirectory() -> URL {
        scratch.url.appendingPathComponent(UUID().uuidString)
    }

    private func makeState(name: String) -> AppState {
        let profile = Profile.makeDefault()
        let workspace = Workspace(id: UUID(), name: name, colorId: .defaultColor(), items: [], profileId: profile.id)
        return AppState(profiles: [profile], workspaces: [workspace], selectedWorkspaceId: workspace.id)
    }

    private func dataURL(in directory: URL) -> URL {
        directory.appendingPathComponent("data.json")
    }

    private func backupsDirectory(in directory: URL) -> URL {
        directory.appendingPathComponent("Backups")
    }

    private func backupURLs(in directory: URL) -> [URL] {
        let backups = backupsDirectory(in: directory)
        let contents = (try? FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("data-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func testLoadCreatesBackup() throws {
        let directory = makeTempDirectory()
        DataStore(baseDirectory: directory).save(makeState(name: "A"))

        _ = DataStore(baseDirectory: directory).load()

        let backups = backupURLs(in: directory)
        #expect(backups.count == 1)
        let backupData = try Data(contentsOf: #require(backups.first))
        let liveData = try Data(contentsOf: dataURL(in: directory))
        #expect(backupData == liveData)
    }

    @Test func testCorruptFileIsPreservedAndBackedUpNotOverwritten() throws {
        let directory = makeTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptBytes = Data("not json".utf8)
        try corruptBytes.write(to: dataURL(in: directory))

        let state = DataStore(baseDirectory: directory).load()

        #expect(state.workspaces.map(\.name) == ["Inbox"])
        #expect((try Data(contentsOf: dataURL(in: directory))) == corruptBytes)
        let backups = backupURLs(in: directory)
        #expect(backups.count == 1)
        #expect((try Data(contentsOf: #require(backups.first))) == corruptBytes)
    }

    @Test(arguments: ["future", "node", "icon", "invalid"])
    func incompatibleDataRequiresExplicitRecovery(kind: String) throws {
        let directory = makeTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(makeState(name: "Original"))) as? [String: Any])
        var workspaces = try #require(object["workspaces"] as? [[String: Any]])
        switch kind {
        case "future":
            object["schemaVersion"] = AppState.currentSchemaVersion + 1
            object["futureField"] = "keep me"
        case "node":
            workspaces[0]["items"] = [["type": "future-node"]]
            object["workspaces"] = workspaces
        case "icon":
            workspaces[0]["icon"] = ["type": "future-icon"]
            object["workspaces"] = workspaces
        default:
            break
        }
        let original = kind == "invalid" ? Data("not json".utf8) : try JSONSerialization.data(withJSONObject: object)
        try original.write(to: dataURL(in: directory))

        let store = DataStore(baseDirectory: directory)
        let model = AppModel(store: store, defaults: testDefaults.suite)
        if kind == "future" {
            guard case .newerSchema(let version) = model.dataLoadIssue else {
                Issue.record("Expected newer schema warning")
                return
            }
            #expect(version == AppState.currentSchemaVersion + 1)
        } else {
            guard case .unreadable = model.dataLoadIssue else {
                Issue.record("Expected unreadable data warning")
                return
            }
        }

        model.renameWorkspace(id: model.currentWorkspace.id, newName: "Changed")
        #expect(try Data(contentsOf: dataURL(in: directory)) == original)
        #expect(try Data(contentsOf: try #require(backupURLs(in: directory).first)) == original)

        let preserved = try model.startEmptyLibrary()
        #expect(preserved.lastPathComponent.hasPrefix("data.unreadable-"))
        #expect(try Data(contentsOf: preserved) == original)
        #expect(model.dataLoadIssue == nil)
        let saved = try DataStore.decodeState(from: Data(contentsOf: dataURL(in: directory)))
        #expect(saved.schemaVersion == AppState.currentSchemaVersion)
        #expect(saved.state.workspaces.map(\.name) == ["Inbox"])
        model.renameWorkspace(id: model.currentWorkspace.id, newName: "After recovery")
        #expect(DataStore(baseDirectory: directory).load().workspaces.first?.name == "After recovery")
        #expect(try Data(contentsOf: preserved) == original)
    }

    @Test func unreadableFileAccessBlocksWritesAndRecovery() throws {
        let directory = makeTempDirectory()
        try FileManager.default.createDirectory(at: dataURL(in: directory), withIntermediateDirectories: true)
        let store = DataStore(baseDirectory: directory)
        let state = store.load()
        guard case .readFailed = store.loadIssue else {
            Issue.record("Expected read failure")
            return
        }
        store.save(state)
        #expect(throws: (any Error).self) { try store.startEmptyLibrary(with: state) }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dataURL(in: directory).path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func failedPreservationDoesNotEnableWrites() throws {
        let directory = makeTempDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("invalid json".utf8)
        try original.write(to: dataURL(in: directory))
        let store = DataStore(baseDirectory: directory)
        let state = store.load()
        let relocated = directory.appendingPathComponent("relocated.json")
        try FileManager.default.moveItem(at: dataURL(in: directory), to: relocated)

        #expect(throws: (any Error).self) { try store.startEmptyLibrary(with: state) }
        store.save(state)
        #expect(!FileManager.default.fileExists(atPath: dataURL(in: directory).path))
        #expect(try Data(contentsOf: relocated) == original)
    }

    @Test func saveRejectsNewerVersionLabel() throws {
        let directory = makeTempDirectory()
        let store = DataStore(baseDirectory: directory)
        let original = store.load()
        let before = try Data(contentsOf: dataURL(in: directory))
        var newer = original
        newer.schemaVersion += 1
        store.save(newer)
        #expect(try Data(contentsOf: dataURL(in: directory)) == before)
    }

    @Test func testRelaunchWithUnchangedDataDoesNotDuplicateBackup() {
        let directory = makeTempDirectory()
        DataStore(baseDirectory: directory).save(makeState(name: "A"))

        _ = DataStore(baseDirectory: directory).load()
        _ = DataStore(baseDirectory: directory).load()

        #expect(backupURLs(in: directory).count == 1)
    }

    @Test func testBackupRotationKeepsTenMostRecent() {
        let directory = makeTempDirectory()
        var allNames = Set<String>()

        // Each fresh instance backs up the previous on-disk state before writing
        // a distinct new one; the final load() backs up the 12th state.
        for index in 0..<12 {
            DataStore(baseDirectory: directory).save(makeState(name: "Workspace \(index)"))
            backupURLs(in: directory).forEach { allNames.insert($0.lastPathComponent) }
            // Backup names carry millisecond timestamps: two saves in the same
            // millisecond would share one. 20 ms leaves room for a coarse or
            // slewing clock without making the test slow.
            Thread.sleep(forTimeInterval: 0.02)
        }
        _ = DataStore(baseDirectory: directory).load()
        backupURLs(in: directory).forEach { allNames.insert($0.lastPathComponent) }

        #expect(allNames.count == 12)
        let remaining = backupURLs(in: directory).map(\.lastPathComponent)
        #expect(remaining.count == 10)
        #expect(Set(remaining) == Set(allNames.sorted().suffix(10)))
    }

    @Test func testSaveWithoutPriorLoadStillBacksUp() throws {
        let directory = makeTempDirectory()
        DataStore(baseDirectory: directory).save(makeState(name: "A"))
        let originalData = try Data(contentsOf: dataURL(in: directory))

        DataStore(baseDirectory: directory).save(makeState(name: "B"))

        let backups = backupURLs(in: directory)
        #expect(backups.count == 1)
        #expect((try Data(contentsOf: #require(backups.first))) == originalData)
    }

    @Test func testFirstLaunchCreatesNoBackup() {
        let directory = makeTempDirectory()

        _ = DataStore(baseDirectory: directory).load()

        #expect(FileManager.default.fileExists(atPath: dataURL(in: directory).path))
        #expect(backupURLs(in: directory).isEmpty)
    }
}
