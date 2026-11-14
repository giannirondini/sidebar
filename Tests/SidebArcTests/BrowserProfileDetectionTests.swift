import Foundation
import Testing
@testable import SidebArcCore

/// `BrowserManager.detectProfileList` against fake browser data in a temp
/// "Application Support" root. Never touches the real browser folders.
@Suite struct BrowserProfileDetectionTests {
    private let root: URL
    private let chrome = "com.google.Chrome"

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

    @Test func chromeProfilesComeFromLocalState() throws {
        _ = try write(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 1":{"name":"Work"}}}}"#,
                      to: "Google/Chrome/Local State")
        #expect(BrowserManager.detectProfileList(bundleId: chrome, supportRoot: root) == .found([
            BrowserProfile(id: "Default", displayName: "Personal"),
            BrowserProfile(id: "Profile 1", displayName: "Work"),
        ]))
    }

    @Test func unreadableLocalStateIsReportedAsDenied() throws {
        let localState = try write(#"{"profile":{"info_cache":{"Default":{"name":"Personal"}}}}"#, to: "Google/Chrome/Local State")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: localState.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: localState.path) }
        #expect(BrowserManager.detectProfileList(bundleId: chrome, supportRoot: root) == .accessDenied)
    }

    @Test func missingOrUnsupportedIsUnavailable() {
        #expect(BrowserManager.detectProfileList(bundleId: chrome, supportRoot: root) == .unavailable)
        #expect(BrowserManager.detectProfileList(bundleId: "org.mozilla.firefox", supportRoot: root) == .unavailable)
        #expect(BrowserManager.detectProfileList(bundleId: "com.apple.Safari", supportRoot: root) == .unavailable)
    }

    @Test func browserProfileSupportIsChromiumOnly() {
        #expect(BrowserManager.supportsProfiles(bundleId: chrome))
        #expect(BrowserManager.profileArguments(for: chrome, profile: "Profile 1") == ["--profile-directory=Profile 1"])
        // Firefox browser profiles were dropped: a stored value is ignored and the link opens normally.
        #expect(!BrowserManager.supportsProfiles(bundleId: "org.mozilla.firefox"))
        #expect(BrowserManager.profileArguments(for: "org.mozilla.firefox", profile: "work").isEmpty)
    }

    @Test func launchArgumentsOnlyForSupportedBrowserProfiles() throws {
        let url = try #require(URL(string: "https://example.com/a?b=1"))
        #expect(BrowserManager.launchArguments(url: url, target: BrowserTarget(bundleId: chrome, profileDir: "Profile 1"))
                == ["--profile-directory=Profile 1", "https://example.com/a?b=1"])
        #expect(BrowserManager.launchArguments(url: url, target: BrowserTarget(bundleId: chrome, profileDir: nil)) == nil)
        #expect(BrowserManager.launchArguments(url: url, target: BrowserTarget(bundleId: chrome, profileDir: "")) == nil)
        #expect(BrowserManager.launchArguments(url: url, target: BrowserTarget(bundleId: "org.mozilla.firefox", profileDir: "work")) == nil)
        #expect(BrowserManager.launchArguments(url: url, target: BrowserTarget(bundleId: nil, profileDir: "Profile 1")) == nil)
    }
}
