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

        let flagLike = try #require(URL(string: "--renderer-cmd-prefix=/tmp/x"))
        #expect(BrowserManager.launchArguments(url: flagLike, target: BrowserTarget(bundleId: chrome, profileDir: "Profile 1")) == nil)
    }

    @Test(arguments: [
        "https://example.com", "HTTP://example.com/path", "file:///tmp/run.command",
        "mailto:name@example.com", "obsidian://open?vault=Notes&file=Today", "slack://channel?id=C1"
    ])
    func linkURLsWithASchemeAreAccepted(_ string: String) {
        #expect(BrowserManager.validatedLinkURL(from: string) != nil)
    }

    @Test(arguments: [
        "--remote-debugging-port=9222", "https:example.com", "https://", "example.com/path",
        "javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,<b>x</b>", "chrome://settings",
        "about:blank", "file:///", "mailto:", "", "x-man-page://-P/bin/sh/ls", "telnet://-l/x"
    ])
    func relativeEmptyAndBlockedURLsAreRefused(_ string: String) {
        #expect(BrowserManager.validatedLinkURL(from: string) == nil)
    }

    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("example.com/path?q=1", "https://example.com/path?q=1"),
        ("Example.com:8443/x", "https://Example.com:8443/x"),
        ("localhost:3000/app", "http://localhost:3000/app"),
        ("192.168.1.10:8080", "http://192.168.1.10:8080"),
        ("  https://example.com/  ", "https://example.com/"),
        ("mailto:name@example.com", "mailto:name@example.com"),
        ("obsidian://open?vault=Notes", "obsidian://open?vault=Notes"),
        ("file:///Users/me/Doc.pdf", "file:///Users/me/Doc.pdf")
    ])
    func typedURLsGetASchemeWhenTheyAreABareHost(_ input: String, _ expected: String) {
        #expect(BrowserManager.typedLinkURL(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "not a url", "words", "javascript:alert(1)", "--flag", "https://", "two words.com"])
    func typedNonURLsAreRefused(_ input: String) {
        #expect(BrowserManager.typedLinkURL(from: input) == nil)
    }

    @Test func onlyWebURLsReachABrowserCommandLine() throws {
        let target = BrowserTarget(bundleId: "com.google.Chrome", profileDir: "Profile 1")
        for string in ["obsidian://open?vault=--flag", "mailto:a@b.c", "file:///tmp/x"] {
            let url = try #require(BrowserManager.validatedLinkURL(from: string))
            #expect(!BrowserManager.isWebURL(url))
            #expect(BrowserManager.launchArguments(url: url, target: target) == nil)
        }
        let web = try #require(BrowserManager.validatedLinkURL(from: "https://example.com"))
        #expect(BrowserManager.isWebURL(web))
    }

    @Test func runnableFilesAreRevealedNotOpened() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("run.command")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        let executable = dir.appendingPathComponent("tool")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let document = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: document)

        // An alias to an app, and a harmless-looking symlink to a script.
        let alias = dir.appendingPathComponent("Readme")
        let bookmark = try URL(fileURLWithPath: "/System/Applications/Calculator.app")
            .bookmarkData(options: .suitableForBookmarkFile)
        try URL.writeBookmarkData(bookmark, to: alias)
        let symlink = dir.appendingPathComponent("notes-link.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: script)
        // Documents that launch something.
        let terminal = dir.appendingPathComponent("Run.terminal")
        try Data("<plist/>".utf8).write(to: terminal)
        let fileloc = dir.appendingPathComponent("Target.fileloc")
        try Data("<plist/>".utf8).write(to: fileloc)

        for runnable in [script, executable, alias, symlink, terminal, fileloc] {
            #expect(BrowserManager.revealsInsteadOfOpening(runnable), "\(runnable.lastPathComponent)")
        }
        #expect(BrowserManager.revealsInsteadOfOpening(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        #expect(!BrowserManager.revealsInsteadOfOpening(document))
        #expect(!BrowserManager.revealsInsteadOfOpening(dir))
    }
}
