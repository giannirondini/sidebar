import Foundation
import Testing
@testable import SidebArcCore

@Suite struct DataStoreBackupTests {
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
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
        let backupData = try Data(contentsOf: backups[0])
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
        #expect((try Data(contentsOf: backups[0])) == corruptBytes)
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
            Thread.sleep(forTimeInterval: 0.005)
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
        #expect((try Data(contentsOf: backups[0])) == originalData)
    }

    @Test func testFirstLaunchCreatesNoBackup() {
        let directory = makeTempDirectory()

        _ = DataStore(baseDirectory: directory).load()

        #expect(FileManager.default.fileExists(atPath: dataURL(in: directory).path))
        #expect(backupURLs(in: directory).isEmpty)
    }
}
