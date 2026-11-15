import Foundation
import os

/// Export and import of SidebArc's data, to move it to another Mac (Phase 3b.3).
///
/// An export is a folder:
///
///     SidebArc Export <date>/
///     ├── export.json   manifest: format, formatVersion, schemaVersion, exportedAt
///     ├── data.json     exact copy of the data file
///     ├── Notes/        note bodies (<id>.md)
///     └── Icons/        favicons; custom favicon icons point into it
///
/// Import accepts only such a folder (the manifest is required) and replaces all
/// data after a backup (`AppModel.applyDataImport`); a readable previous library
/// can be restored by importing `Backups/pre-import-<ts>/`. App preferences (UserDefaults),
/// `agent-endpoint.json` (holds a token) and `Backups/` are not exported.
enum DataTransfer {
    private static let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "transfer")
    static let manifestFileName = "export.json"
    static let dataFileName = "data.json"
    static let notesFolderName = "Notes"
    static let iconsFolderName = "Icons"
    /// Identifies a SidebArc export; checked on import.
    static let format = "\(AppIdentity.bundleIdentifier).export"
    static let formatVersion = 1

    struct Manifest: Codable, Equatable {
        var format: String
        var formatVersion: Int
        /// `schemaVersion` of the exported `data.json`.
        var schemaVersion: Int
        var exportedAt: Date
        var appVersion: String?
    }

    enum TransferError: Error, Equatable, LocalizedError {
        /// No readable `export.json` with SidebArc's format.
        case notAnExport
        case unsupportedFormatVersion(Int)
        case missingDataFile
        case unreadableDataFile(String)
        /// The data was written by a newer SidebArc; importing would drop what this version doesn't know.
        case newerSchema(Int)
        case fileOperationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAnExport:
                return "This folder isn't a \(AppIdentity.displayName) export. Choose a folder created with Export Data…."
            case .unsupportedFormatVersion(let version):
                return "This export uses format version \(version), which this version of \(AppIdentity.displayName) can't read. Update \(AppIdentity.displayName) and try again."
            case .missingDataFile:
                return "The export has no \(DataTransfer.dataFileName)."
            case .unreadableDataFile(let detail):
                return "The \(DataTransfer.dataFileName) file can't be read: \(detail)"
            case .newerSchema(let version):
                return "The export was made by a newer \(AppIdentity.displayName) (data version \(version)). Update \(AppIdentity.displayName) and try again."
            case .fileOperationFailed(let detail):
                return detail
            }
        }
    }

    /// What an import would bring in, for the confirmation.
    struct Summary: Equatable {
        var profiles: Int
        var spaces: Int
        var links: Int
        var favorites: Int
        var notes: Int
    }

    /// A validated export, read but not applied.
    struct Package {
        let folder: URL
        let manifest: Manifest
        let state: AppState
        let summary: Summary
    }

    // MARK: - Export

    /// Writes a new export folder inside `parent` and returns it. The name is
    /// `baseName`, or "SidebArc Export <local date and time>"; an existing folder is
    /// never overwritten (" 2", " 3", … is appended instead).
    static func export(
        store: DataStore,
        to parent: URL,
        baseName: String? = nil,
        now: Date = Date(),
        appVersion: String? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let source = store.dataFileURL
        guard fileManager.fileExists(atPath: source.path) else { throw TransferError.missingDataFile }

        let data: Data
        let schemaVersion: Int
        do {
            data = try Data(contentsOf: source)
            schemaVersion = try DataStore.decodeState(from: data).schemaVersion
        } catch {
            throw TransferError.unreadableDataFile(error.localizedDescription)
        }

        return try writeFolder(
            store: store, data: data, schemaVersion: schemaVersion, to: parent,
            baseName: baseName ?? "\(AppIdentity.displayName) Export \(folderDateFormatter.string(from: now))",
            now: now, appVersion: appVersion
        )
    }

    /// Preserves the live bytes even if this version cannot decode them. When no
    /// schema version can be read, the backup has no manifest and is for manual recovery.
    static func backupForImport(store: DataStore, to parent: URL, baseName: String) throws -> URL {
        let data: Data
        do {
            data = try Data(contentsOf: store.dataFileURL)
        } catch {
            throw TransferError.unreadableDataFile(error.localizedDescription)
        }
        let version = try? JSONDecoder().decode(SchemaVersionProbe.self, from: data).schemaVersion
        return try writeFolder(store: store, data: data, schemaVersion: version, to: parent, baseName: baseName, now: Date(), appVersion: nil)
    }

    private static func writeFolder(
        store: DataStore, data: Data, schemaVersion: Int?, to parent: URL,
        baseName: String, now: Date, appVersion: String?
    ) throws -> URL {
        let fileManager = FileManager.default
        let folder = uniqueFolder(in: parent, baseName: baseName)
        var created = false
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            created = true
            try data.write(to: folder.appendingPathComponent(dataFileName), options: [.atomic])
            try copyFolder(store.notesDirectory(), to: folder.appendingPathComponent(notesFolderName, isDirectory: true))
            try copyFolder(store.iconsDirectory(), to: folder.appendingPathComponent(iconsFolderName, isDirectory: true))
            if let schemaVersion {
                let manifest = Manifest(
                    format: format,
                    formatVersion: formatVersion,
                    schemaVersion: schemaVersion,
                    exportedAt: now,
                    appVersion: appVersion
                )
                try manifestEncoder.encode(manifest).write(to: folder.appendingPathComponent(manifestFileName), options: [.atomic])
            }
        } catch {
            // Don't leave a half-written export that looks complete.
            if created { try? fileManager.removeItem(at: folder) }
            throw TransferError.fileOperationFailed("Export failed: \(error.localizedDescription)")
        }
        return folder
    }

    // MARK: - Import

    /// Reads and validates an export folder without changing anything.
    static func readPackage(at folder: URL) throws -> Package {
        let manifestURL = folder.appendingPathComponent(manifestFileName)
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? manifestDecoder.decode(Manifest.self, from: manifestData),
              manifest.format == format else {
            throw TransferError.notAnExport
        }
        guard manifest.formatVersion <= formatVersion else {
            throw TransferError.unsupportedFormatVersion(manifest.formatVersion)
        }

        let dataURL = folder.appendingPathComponent(dataFileName)
        guard FileManager.default.fileExists(atPath: dataURL.path) else { throw TransferError.missingDataFile }
        let data: Data
        let version: Int
        do {
            data = try Data(contentsOf: dataURL)
            version = try JSONDecoder().decode(SchemaVersionProbe.self, from: data).schemaVersion
        } catch {
            throw TransferError.unreadableDataFile(error.localizedDescription)
        }
        guard version <= AppState.currentSchemaVersion else {
            throw TransferError.newerSchema(version)
        }
        let decoded: (state: AppState, schemaVersion: Int)
        do {
            decoded = try DataStore.decodeState(from: data)
        } catch {
            throw TransferError.unreadableDataFile(error.localizedDescription)
        }

        let state = decoded.state.repaired()
        return Package(folder: folder, manifest: manifest, state: state, summary: summary(of: state))
    }

    /// Copies the export's `Notes/` and `Icons/` files into `store`, replacing files
    /// with the same name. Local files the export doesn't have are kept (unused notes
    /// and icons are never shown). A missing folder in the export counts as empty.
    static func copyFiles(from package: Package, into store: DataStore) throws {
        let fileManager = FileManager.default
        let staging = store.dataFileURL.deletingLastPathComponent()
            .appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            do {
                try fileManager.removeItem(at: staging)
            } catch {
                logger.error("Could not remove import staging directory: \(error.localizedDescription, privacy: .public)")
            }
        }
        let stagedNotes = staging.appendingPathComponent(notesFolderName, isDirectory: true)
        let stagedIcons = staging.appendingPathComponent(iconsFolderName, isDirectory: true)
        try fileManager.createDirectory(at: stagedNotes, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: stagedIcons, withIntermediateDirectories: false)
        try copyContents(of: package.folder.appendingPathComponent(notesFolderName, isDirectory: true), into: stagedNotes)
        try copyContents(of: package.folder.appendingPathComponent(iconsFolderName, isDirectory: true), into: stagedIcons)
        try copyContents(of: stagedNotes, into: store.notesDirectory())
        try copyContents(of: stagedIcons, into: store.iconsDirectory())
    }

    /// Points every icon path that lives in an `Icons/` folder (another Mac's, or this
    /// one's) at the same file in `iconsDirectory`. A `Link.faviconPath` elsewhere is
    /// dropped (the favicon is fetched again); a custom icon elsewhere is kept as is.
    /// Covers the space trees, space icons and every profile's favorites.
    static func remapIconPaths(in state: AppState, iconsDirectory: URL) -> AppState {
        func localPath(_ path: String) -> String? {
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().lastPathComponent == iconsFolderName else { return nil }
            return iconsDirectory.appendingPathComponent(url.lastPathComponent).path
        }
        func remapIcon(_ icon: CustomIcon?) -> CustomIcon? {
            guard case .cachedFavicon(let path)? = icon else { return icon }
            return .cachedFavicon(localPath(path) ?? path)
        }
        func remapLink(_ link: Link) -> Link {
            var link = link
            link.faviconPath = link.faviconPath.flatMap(localPath)
            link.customIcon = remapIcon(link.customIcon)
            return link
        }
        func remapNode(_ node: Node) -> Node {
            switch node {
            case .link(let link):
                return .link(remapLink(link))
            case .note(var note):
                note.customIcon = remapIcon(note.customIcon)
                return .note(note)
            case .folder(var folder):
                folder.children = folder.children.map(remapNode)
                return .folder(folder)
            }
        }

        var state = state
        for index in state.workspaces.indices {
            state.workspaces[index].items = state.workspaces[index].items.map(remapNode)
            state.workspaces[index].icon = remapIcon(state.workspaces[index].icon)
        }
        for index in state.profiles.indices {
            state.profiles[index].favorites = state.profiles[index].favorites.map(remapLink)
        }
        return state
    }

    /// File names (in `Icons/`) that something in `state` shows: link favicons,
    /// custom favicon icons on links, notes and spaces, and favorites.
    static func referencedIconFileNames(in state: AppState) -> Set<String> {
        var names = Set<String>()
        func add(_ path: String?) {
            if let path { names.insert(URL(fileURLWithPath: path).lastPathComponent) }
        }
        func add(_ icon: CustomIcon?) {
            if case .cachedFavicon(let path)? = icon { add(path) }
        }
        func add(_ link: Link) {
            add(link.faviconPath)
            add(link.customIcon)
        }
        func visit(_ node: Node) {
            switch node {
            case .link(let link): add(link)
            case .note(let note): add(note.customIcon)
            case .folder(let folder): folder.children.forEach(visit)
            }
        }
        for workspace in state.workspaces {
            workspace.items.forEach(visit)
            add(workspace.icon)
        }
        state.profiles.flatMap(\.favorites).forEach(add)
        return names
    }

    static func summary(of state: AppState) -> Summary {
        func count(_ nodes: [Node]) -> (links: Int, notes: Int) {
            nodes.reduce(into: (0, 0)) { total, node in
                switch node {
                case .link: total.0 += 1
                case .note: total.1 += 1
                case .folder(let folder):
                    let inner = count(folder.children)
                    total.0 += inner.links
                    total.1 += inner.notes
                }
            }
        }
        let trees = state.workspaces.map { count($0.items) }
        return Summary(
            profiles: state.profiles.count,
            spaces: state.workspaces.count,
            links: trees.reduce(0) { $0 + $1.links },
            favorites: state.profiles.reduce(0) { $0 + $1.favorites.count },
            notes: trees.reduce(0) { $0 + $1.notes }
        )
    }

    // MARK: - Helpers

    private static let folderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"   // no ':' (Finder shows it as '/')
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static var manifestEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var manifestDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func uniqueFolder(in parent: URL, baseName: String) -> URL {
        var candidate = parent.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(baseName) \(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    /// Copies `source` to `destination` (which must not exist); a missing source
    /// becomes an empty folder, so every export has the same layout.
    private static func copyFolder(_ source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: source.path) {
            try fileManager.copyItem(at: source, to: destination)
        } else {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
        }
    }

    /// Copies the regular files directly inside `source` into `destination`,
    /// replacing files with the same name.
    private static func copyContents(of source: URL, into destination: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        do {
            let files = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for file in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let target = destination.appendingPathComponent(file.lastPathComponent)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: file, to: target)
            }
        } catch {
            throw TransferError.fileOperationFailed("Copying \(source.lastPathComponent) failed: \(error.localizedDescription)")
        }
    }
}
