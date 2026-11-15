import Foundation
import os

final class NoteStorage {
    private let store: DataStore
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "notes")

    init(store: DataStore) {
        self.store = store
    }

    func read(id: UUID) -> String {
        let url = store.noteFileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func write(id: UUID, content: String) throws {
        let url = store.noteFileURL(for: id)
        try content.data(using: .utf8)?.write(to: url, options: [.atomic])
    }

    func delete(id: UUID) {
        let url = store.noteFileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logger.error("Could not remove note file: \(error.localizedDescription, privacy: .public)")
        }
    }
}
