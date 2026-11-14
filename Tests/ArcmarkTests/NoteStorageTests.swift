import Foundation
import Testing
@testable import ArcmarkCore

@Suite struct NoteStorageTests {
    private func makeStore() -> DataStore {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DataStore(baseDirectory: temp)
    }

    @Test func testReadMissingReturnsEmptyString() {
        let storage = NoteStorage(store: makeStore())
        #expect(storage.read(id: UUID()) == "")
    }

    @Test func testWriteThenRead() throws {
        let storage = NoteStorage(store: makeStore())
        let id = UUID()
        try storage.write(id: id, content: "# Hello\n\nWorld")
        #expect(storage.read(id: id) == "# Hello\n\nWorld")
    }

    @Test func testOverwriteReplacesContent() throws {
        let storage = NoteStorage(store: makeStore())
        let id = UUID()
        try storage.write(id: id, content: "first")
        try storage.write(id: id, content: "second")
        #expect(storage.read(id: id) == "second")
    }

    @Test func testDeleteRemovesFile() throws {
        let store = makeStore()
        let storage = NoteStorage(store: store)
        let id = UUID()
        try storage.write(id: id, content: "anything")
        #expect(FileManager.default.fileExists(atPath: store.noteFileURL(for: id).path))

        storage.delete(id: id)
        #expect(!FileManager.default.fileExists(atPath: store.noteFileURL(for: id).path))
    }

    @Test func testDeleteMissingIsSilent() {
        let storage = NoteStorage(store: makeStore())
        // Should not throw
        storage.delete(id: UUID())
    }

    @Test func testFileLocationIsUnderNotesDirectory() throws {
        let store = makeStore()
        let storage = NoteStorage(store: store)
        let id = UUID()
        try storage.write(id: id, content: "x")
        let url = store.noteFileURL(for: id)
        #expect(url.path.contains("/Notes/"))
        #expect(url.pathExtension == "md")
    }
}
