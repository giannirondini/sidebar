import Foundation
import SQLite3
import Testing
@testable import SidebArcCore

/// `BrowserManager.detectProfileList` against fake browser data in a temp
/// "Application Support" root.
@Suite struct BrowserProfileDetectionTests {
    private let root: URL
    private let firefox = "org.mozilla.firefox"

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Creates a Firefox "Profile Groups" store with the given (path, name) rows.
    private func writeProfileGroup(storeId: String, rows: [(String, String)]) throws {
        let dir = root.appendingPathComponent("Firefox/Profile Groups")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(dir.appendingPathComponent("\(storeId).sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE Profiles (id INTEGER PRIMARY KEY, path TEXT, name TEXT)", nil, nil, nil) == SQLITE_OK)
        for (index, row) in rows.enumerated() {
            let sql = "INSERT INTO Profiles (id, path, name) VALUES (\(index + 1), '\(row.0)', '\(row.1)')"
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
    }

    @Test func classicFirefoxProfilesAreListedByName() throws {
        _ = try write("""
        [General]
        StartWithLastProfile=1

        [Profile1]
        Name=work
        IsRelative=1
        Path=Profiles/bbbb.work

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/aaaa.default-release
        Default=1

        [Install4F96D1932A9F858E]
        Default=Profiles/aaaa.default-release
        """, to: "Firefox/profiles.ini")

        let result = BrowserManager.detectProfileList(bundleId: firefox, supportRoot: root)
        #expect(result == .found([
            BrowserProfile(id: "default-release", displayName: "default-release"),
            BrowserProfile(id: "work", displayName: "work"),
        ]))
    }

    /// Regression: when any selectable profile existed, classic profiles
    /// (e.g. one just created in about:profiles) were not listed at all.
    @Test func selectableAndClassicProfilesAreMergedWithoutDuplicates() throws {
        _ = try write("""
        [Profile1]
        Name=New Classic
        IsRelative=1
        Path=Profiles/cccc.New Classic

        [Profile0]
        Name=Original profile
        IsRelative=1
        Path=Profiles/aaaa.Original
        StoreID=store1
        """, to: "Firefox/profiles.ini")
        try writeProfileGroup(storeId: "store1", rows: [("Profiles/aaaa.Original", "Personal"), ("Profiles/bbbb.Work", "Work")])

        let result = BrowserManager.detectProfileList(bundleId: firefox, supportRoot: root)
        #expect(result == .found([
            BrowserProfile(id: "New Classic", displayName: "New Classic"),
            BrowserProfile(id: "Profiles/aaaa.Original", displayName: "Personal"),
            BrowserProfile(id: "Profiles/bbbb.Work", displayName: "Work"),
        ]))
    }

    @Test func unreadableProfileListIsReportedAsDenied() throws {
        let ini = try write("[Profile0]\nName=x\nPath=Profiles/x\n", to: "Firefox/profiles.ini")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ini.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ini.path) }

        #expect(BrowserManager.detectProfileList(bundleId: firefox, supportRoot: root) == .accessDenied)
    }

    @Test func missingBrowserDataIsUnavailable() {
        #expect(BrowserManager.detectProfileList(bundleId: firefox, supportRoot: root) == .unavailable)
        #expect(BrowserManager.detectProfileList(bundleId: "com.google.Chrome", supportRoot: root) == .unavailable)
        #expect(BrowserManager.detectProfileList(bundleId: "com.apple.Safari", supportRoot: root) == .unavailable)
    }

    @Test func chromeProfilesComeFromLocalState() throws {
        let localState = try write(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work"}}}}"#,
                                   to: "Google/Chrome/Local State")
        #expect(BrowserManager.detectProfileList(bundleId: "com.google.Chrome", supportRoot: root) == .found([
            BrowserProfile(id: "Default", displayName: "Personal"),
            BrowserProfile(id: "Profile 1", displayName: "Work"),
        ]))

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: localState.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: localState.path) }
        #expect(BrowserManager.detectProfileList(bundleId: "com.google.Chrome", supportRoot: root) == .accessDenied)
    }

    @Test func firefoxArgumentsAcceptNameRelativeAndAbsolutePaths() {
        #expect(BrowserManager.profileArguments(for: firefox, profile: "work") == ["-P", "work"])
        #expect(BrowserManager.profileArguments(for: firefox, profile: "/Users/me/ff/abcd.work") == ["-profile", "/Users/me/ff/abcd.work"])
        let relative = BrowserManager.profileArguments(for: firefox, profile: "Profiles/abcd.work")
        #expect(relative.first == "-profile")
        #expect(relative.last?.hasSuffix("Library/Application Support/Firefox/Profiles/abcd.work") == true)
    }
}
