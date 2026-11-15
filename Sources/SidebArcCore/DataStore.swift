import Foundation
import os

final class DataStore {
    enum LoadIssue: Equatable {
        case newerSchema(Int)
        case unreadable(String)
        case readFailed(String)
    }

    struct RecoveryWriteError: LocalizedError {
        let preservedURL: URL
        let underlying: Error

        var errorDescription: String? {
            "The original was preserved at \(preservedURL.path), but the empty library could not be saved: \(underlying.localizedDescription)"
        }
    }

    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let dataURL: URL
    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "store")
    private var hasBackedUpThisSession = false
    private(set) var loadIssue: LoadIssue?
    private let backupKeepCount = 10
    private let backupTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.baseDirectory = appSupport.appendingPathComponent(AppIdentity.dataDirectoryName, isDirectory: true)
        }
        self.dataURL = self.baseDirectory.appendingPathComponent("data.json")
    }

    func load() -> AppState {
        ensureDirectories()
        guard fileManager.fileExists(atPath: dataURL.path) else {
            let defaultState = Self.defaultState()
            save(defaultState)
            return defaultState
        }

        backupDataFileIfNeeded()

        let data: Data
        do {
            data = try Data(contentsOf: dataURL)
        } catch {
            loadIssue = .readFailed(error.localizedDescription)
            logger.error("Failed to read data.json: \(error.localizedDescription, privacy: .public)")
            return Self.defaultState()
        }

        do {
            let version = try JSONDecoder().decode(SchemaVersionProbe.self, from: data).schemaVersion
            if version > AppState.currentSchemaVersion {
                loadIssue = .newerSchema(version)
                logger.warning("data.json has unsupported schema v\(version)")
                return Self.defaultState()
            }
            let decoded = try Self.decodeState(from: data).state
            if version < 2 {
                // Persist right away so profile ids are stable across launches, but only
                // once a copy of the v1 file is safe outside the rotating backups.
                if writePreMigrationCopy(data, fromVersion: version) {
                    if save(decoded) {
                        logger.info("Migrated data.json from schema v\(version) to v2")
                    }
                }
                return decoded
            }
            return decoded.repaired()
        } catch {
            loadIssue = .unreadable(error.localizedDescription)
            logger.error("Failed to decode data.json; leaving file untouched: \(error.localizedDescription, privacy: .public)")
            return Self.defaultState()
        }
    }

    /// Only a deliberate user action may replace an incompatible library.
    /// The original is copied out of the rotation before writes are enabled.
    func startEmptyLibrary(with state: AppState) throws -> URL {
        guard let loadIssue else {
            throw CocoaError(.fileWriteUnknown)
        }
        if case .readFailed = loadIssue {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: dataURL.path])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        let timestamp = backupTimestampFormatter.string(from: Date())
        let preserved = baseDirectory.appendingPathComponent("data.unreadable-\(timestamp)-\(UUID().uuidString).json")
        try fileManager.copyItem(at: dataURL, to: preserved)
        do {
            try data.write(to: dataURL, options: [.atomic])
        } catch {
            throw RecoveryWriteError(preservedURL: preserved, underlying: error)
        }
        self.loadIssue = nil
        return preserved
    }

    /// Decodes a `data.json` of any known schema and returns it with the file's
    /// `schemaVersion`. A v1 file is migrated in memory (`SchemaMigration.v1ToV2`);
    /// v2 and later are decoded as they are. Doesn't repair or write anything.
    static func decodeState(from data: Data) throws -> (state: AppState, schemaVersion: Int) {
        let decoder = JSONDecoder()
        let version = try decoder.decode(SchemaVersionProbe.self, from: data).schemaVersion
        if version < 2 {
            return (SchemaMigration.v1ToV2(try decoder.decode(SchemaV1.AppState.self, from: data)), version)
        }
        return (try decoder.decode(AppState.self, from: data), version)
    }

    /// The `data.json` this store reads and writes.
    var dataFileURL: URL { dataURL }

    @discardableResult
    func save(_ state: AppState) -> Bool {
        guard loadIssue == nil else {
            logger.error("Refusing to overwrite unreadable data.json")
            return false
        }
        guard state.schemaVersion == AppState.currentSchemaVersion else {
            logger.error("Refusing to save state with unsupported schema v\(state.schemaVersion)")
            return false
        }
        backupDataFileIfNeeded()
        ensureDirectories()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: dataURL, options: [.atomic])
            return true
        } catch {
            logger.error("Failed to save data.json: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func iconsDirectory() -> URL {
        let iconsURL = baseDirectory.appendingPathComponent("Icons", isDirectory: true)
        if !fileManager.fileExists(atPath: iconsURL.path) {
            try? fileManager.createDirectory(at: iconsURL, withIntermediateDirectories: true)
        }
        return iconsURL
    }

    func notesDirectory() -> URL {
        let notesURL = baseDirectory.appendingPathComponent("Notes", isDirectory: true)
        if !fileManager.fileExists(atPath: notesURL.path) {
            try? fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)
        }
        return notesURL
    }

    func noteFileURL(for id: UUID) -> URL {
        notesDirectory().appendingPathComponent("\(id.uuidString).md")
    }

    func agentEndpointFileURL() -> URL {
        baseDirectory.appendingPathComponent("agent-endpoint.json")
    }

    func writeAgentEndpoint(_ data: Data) throws {
        ensureDirectories()
        let endpointURL = agentEndpointFileURL()
        let temporaryURL = baseDirectory.appendingPathComponent(".agent-endpoint-\(UUID().uuidString).tmp")

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporaryURL.path])
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.close()

            if fileManager.fileExists(atPath: endpointURL.path) {
                try fileManager.removeItem(at: endpointURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: endpointURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    /// Copies data.json into `Backups/` once per session, before this process
    /// first writes to it. Skips the copy when the file is byte-identical to the
    /// newest existing backup so repeated relaunches don't rotate away the last
    /// good backup. Keeps the `backupKeepCount` most recent backups.
    private func backupDataFileIfNeeded() {
        guard !hasBackedUpThisSession else { return }
        hasBackedUpThisSession = true

        guard fileManager.fileExists(atPath: dataURL.path) else { return }

        do {
            let data = try Data(contentsOf: dataURL)
            let backupsURL = backupsDirectory()
            if let newest = sortedBackupURLs(in: backupsURL).last,
               let newestData = try? Data(contentsOf: newest),
               newestData == data {
                return
            }
            let timestamp = backupTimestampFormatter.string(from: Date())
            let backupURL = backupsURL.appendingPathComponent("data-\(timestamp).json")
            try data.write(to: backupURL, options: [.atomic])
            pruneBackups(in: backupsURL)
        } catch {
            logger.error("Failed to back up data.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies the pre-migration file to `Backups/pre-v<n+1>-migration-<ts>.json`.
    /// The name doesn't start with `data-`, so `pruneBackups` never rotates it away.
    private func writePreMigrationCopy(_ data: Data, fromVersion version: Int) -> Bool {
        let timestamp = backupTimestampFormatter.string(from: Date())
        let url = backupsDirectory().appendingPathComponent("pre-v\(version + 1)-migration-\(timestamp).json")
        do {
            try data.write(to: url, options: [.atomic])
            return true
        } catch {
            logger.error("Failed to write pre-migration copy; keeping the migrated state in memory only: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Where an import backs up the current data: `Backups/` and a `pre-import-<ts>`
    /// folder name. The name doesn't start with `data-`, so `pruneBackups` never
    /// rotates it away.
    func preImportBackupDestination() -> (parent: URL, name: String) {
        (backupsDirectory(), "pre-import-\(backupTimestampFormatter.string(from: Date()))")
    }

    private func backupsDirectory() -> URL {
        let backupsURL = baseDirectory.appendingPathComponent("Backups", isDirectory: true)
        if !fileManager.fileExists(atPath: backupsURL.path) {
            try? fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        }
        return backupsURL
    }

    /// Backup filenames are fixed-width UTC timestamps, so lexicographic order
    /// equals chronological order.
    private func sortedBackupURLs(in backupsURL: URL) -> [URL] {
        let contents = (try? fileManager.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix("data-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func pruneBackups(in backupsURL: URL) {
        let backups = sortedBackupURLs(in: backupsURL)
        guard backups.count > backupKeepCount else { return }
        for url in backups.dropLast(backupKeepCount) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func ensureDirectories() {
        if !fileManager.fileExists(atPath: baseDirectory.path) {
            try? fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
    }

    static func defaultState() -> AppState {
        let profile = Profile.makeDefault()
        let workspace = Workspace(
            id: UUID(),
            name: "Inbox",
            colorId: .defaultColor(),
            items: [],
            profileId: profile.id
        )
        return AppState(profiles: [profile], workspaces: [workspace], selectedWorkspaceId: workspace.id)
    }
}
