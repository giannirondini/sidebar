import Foundation
@testable import SidebArcCore

/// A temporary directory removed when the last reference goes away. Keep one as a
/// suite property: swift-testing makes a fresh suite instance per test and releases
/// it afterwards, so every test cleans up after itself.
final class TempDir {
    let url: URL

    init(_ label: String = "SidebArcTests") {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A fresh, not-yet-created subdirectory (a separate data folder, a separate Mac).
    func subdirectory(_ name: String = UUID().uuidString) -> URL {
        url.appendingPathComponent(name, isDirectory: true)
    }

    deinit {
        // Tests may leave read-only folders behind (permission tests); make them
        // writable again so removal can't fail halfway.
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

/// A private `UserDefaults` suite for `AppModel(store:defaults:)`, so tests never
/// write `UserDefaults.standard`. The suite name is an absolute path, which
/// CFPreferences stores as `<path>.plist`: it lives in a `TempDir` and goes with
/// it (a named suite would leave an empty plist in ~/Library/Preferences, since
/// `removePersistentDomain` only clears its keys).
final class TestDefaults {
    private let directory = TempDir("SidebArcTests-defaults")
    let suite: UserDefaults

    init() {
        suite = UserDefaults(suiteName: directory.url.appendingPathComponent("defaults").path)!
    }
}

extension Array {
    /// The element at `index`, or nil: tests use it instead of `[i]`, which traps
    /// and kills the whole run when a result is shorter than expected.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Node {
    var asLink: Link? {
        if case .link(let link) = self { return link }
        return nil
    }

    var asFolder: Folder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }

    var asNote: Note? {
        if case .note(let note) = self { return note }
        return nil
    }
}
