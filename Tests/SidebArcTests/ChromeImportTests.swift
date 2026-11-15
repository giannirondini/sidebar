import Testing
import Foundation
@testable import SidebArcCore

@Suite("Chrome Import Tests")
struct ChromeImportTests {
    private let scratch = TempDir()
    private let testDefaults = TestDefaults()

    // MARK: - Helpers

    /// Create a minimal valid Chrome bookmarks HTML file
    private func createBookmarksHTML(body: String) -> String {
        return """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
        \(body)
        </DL><p>
        """
    }

    /// Write HTML string to a temp file and return its URL
    private func writeTempFile(_ content: String) throws -> URL {
        let tempDir = scratch.url
        let fileURL = tempDir.appendingPathComponent("test_bookmarks_\(UUID().uuidString).html")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Clean up temp file
    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Basic Link Parsing

    @Test("Basic link parsing extracts URL and title")
    func testBasicLinkParsing() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://example.com" ADD_DATE="1234567890">Example Site</A>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 1)
            #expect(importResult.foldersImported == 0)

            let nodes = importResult.workspace.nodes
            #expect(nodes.count == 1)

            if case .link(let link)? = nodes[safe: 0] {
                #expect(link.title == "Example Site")
                #expect(link.url == "https://example.com")
            } else {
                Issue.record("Expected a link node")
            }
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    @Test("Every bookmark is preserved; a relative one can't be opened")
    func testUnsupportedURLSchemesArePreserved() async throws {
        let html = createBookmarksHTML(body: """
            <DT><A HREF="--renderer-cmd-prefix=/tmp/x">Flag</A>
            <DT><A HREF="file:///tmp/run.command">File</A>
            <DT><A HREF="https://example.com">Web</A>
        """)
        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 3)
            let store = DataStore(baseDirectory: scratch.url.appendingPathComponent(UUID().uuidString))
            let model = AppModel(store: store, defaults: testDefaults.suite)
            model.showSettings()
            let profileId = model.currentProfile.id
            model.applyChromeImport(importResult.workspace)
            #expect(model.isSettingsShown)
            #expect(model.currentWorkspace.profileId == profileId)
            let restored = AppModel(store: store, defaults: testDefaults.suite).currentWorkspace.items
            let urls = restored.compactMap { node -> String? in
                guard case .link(let link) = node else { return nil }
                return link.url
            }
            #expect(urls == ["--renderer-cmd-prefix=/tmp/x", "file:///tmp/run.command", "https://example.com"])
            let relative = try #require(urls[safe: 0])
            let file = try #require(urls[safe: 1])
            #expect(BrowserManager.validatedLinkURL(from: relative) == nil)
            #expect(BrowserManager.validatedLinkURL(from: file) != nil)
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - Folder with Nested Links

    @Test("Folder with nested links preserves hierarchy")
    func testFolderWithNestedLinks() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><H3>My Folder</H3>
                <DL><p>
                    <DT><A HREF="https://one.com">One</A>
                    <DT><A HREF="https://two.com">Two</A>
                </DL><p>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 2)
            #expect(importResult.foldersImported == 1)

            let nodes = importResult.workspace.nodes
            #expect(nodes.count == 1) // One folder

            if case .folder(let folder)? = nodes[safe: 0] {
                #expect(folder.name == "My Folder")
                #expect(folder.children.count == 2)
            } else {
                Issue.record("Expected a folder node")
            }
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - Deep Nesting

    @Test("Deep nesting (3+ levels) is preserved")
    func testDeepNesting() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><H3>Level 1</H3>
                <DL><p>
                    <DT><H3>Level 2</H3>
                    <DL><p>
                        <DT><H3>Level 3</H3>
                        <DL><p>
                            <DT><A HREF="https://deep.com">Deep Link</A>
                        </DL><p>
                    </DL><p>
                </DL><p>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 1)
            #expect(importResult.foldersImported == 3)

            // Navigate down the hierarchy
            if case .folder(let l1)? = importResult.workspace.nodes[safe: 0] {
                #expect(l1.name == "Level 1")
                if case .folder(let l2)? = l1.children[safe: 0] {
                    #expect(l2.name == "Level 2")
                    if case .folder(let l3)? = l2.children[safe: 0] {
                        #expect(l3.name == "Level 3")
                        if case .link(let link)? = l3.children[safe: 0] {
                            #expect(link.url == "https://deep.com")
                        } else {
                            Issue.record("Expected link at level 3")
                        }
                    } else {
                        Issue.record("Expected folder at level 2")
                    }
                } else {
                    Issue.record("Expected folder at level 1")
                }
            } else {
                Issue.record("Expected folder at root")
            }
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - Top-Level Folders Flattened

    @Test("Top-level Chrome folders are flattened into root")
    func testTopLevelFoldersFlattened() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://bar.com">Bar Link</A>
            </DL><p>
            <DT><H3>Other bookmarks</H3>
            <DL><p>
                <DT><A HREF="https://other.com">Other Link</A>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 2)
            // Both top-level folders flattened, so no folders in output
            #expect(importResult.foldersImported == 0)

            let nodes = importResult.workspace.nodes
            #expect(nodes.count == 2) // Both links at root level

            let link1 = try #require(nodes[safe: 0]?.asLink)
            #expect(link1.url == "https://bar.com")
            let link2 = try #require(nodes[safe: 1]?.asLink)
            #expect(link2.url == "https://other.com")
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - Empty Bookmarks File

    @Test("Empty bookmarks file returns noBookmarksFound error")
    func testEmptyBookmarksFile() async throws {
        let html = createBookmarksHTML(body: "")

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success:
            Issue.record("Should fail with noBookmarksFound")
        case .failure(let error):
            #expect(error == .noBookmarksFound)
        }
    }

    // MARK: - Invalid HTML File

    @Test("Invalid/non-HTML file returns invalidHTML error")
    func testInvalidHTMLFile() async throws {
        let content = "This is just plain text, not a bookmark file."

        let fileURL = try writeTempFile(content)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success:
            Issue.record("Should fail with invalidHTML")
        case .failure(let error):
            #expect(error == .invalidHTML)
        }
    }

    // MARK: - HTML Entities Decoded

    @Test("HTML entities are decoded in titles")
    func testHTMLEntitiesDecoded() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://example.com">Tom &amp; Jerry&#39;s &lt;Site&gt;</A>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            if case .link(let link)? = importResult.workspace.nodes[safe: 0] {
                #expect(link.title == "Tom & Jerry's <Site>")
            } else {
                Issue.record("Expected a link node")
            }
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - Order Preserved

    @Test("Links appear in file order")
    func testOrderPreserved() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://first.com">First</A>
                <DT><A HREF="https://second.com">Second</A>
                <DT><A HREF="https://third.com">Third</A>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            let nodes = importResult.workspace.nodes
            #expect(nodes.count == 3)

            let l1 = try #require(nodes[safe: 0]?.asLink)
            #expect(l1.title == "First")
            let l2 = try #require(nodes[safe: 1]?.asLink)
            #expect(l2.title == "Second")
            let l3 = try #require(nodes[safe: 2]?.asLink)
            #expect(l3.title == "Third")
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - Empty Title

    @Test("Link with empty title uses Untitled")
    func testEmptyTitleUsesUntitled() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://example.com"></A>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            if case .link(let link)? = importResult.workspace.nodes[safe: 0] {
                #expect(link.title == "Untitled")
            } else {
                Issue.record("Expected a link node")
            }
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - Workspace Properties

    @Test("Workspace created with correct name and colorId")
    func testWorkspaceProperties() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://example.com">Example</A>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.workspace.name == "Imported Bookmarks")
            #expect(importResult.workspace.colorId == .ember)
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - File Not Found

    @Test("File not found returns fileNotFound error")
    func testFileNotFound() async throws {
        let fakeURL = URL(fileURLWithPath: "/tmp/nonexistent_bookmarks_\(UUID().uuidString).html")

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fakeURL)

        switch result {
        case .success:
            Issue.record("Should fail with fileNotFound")
        case .failure(let error):
            #expect(error == .fileNotFound)
        }
    }

    // MARK: - Invalid URLs Skipped

    @Test("javascript: and chrome:// URLs are skipped")
    func testInvalidURLsSkipped() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="javascript:void(0)">JS Link</A>
                <DT><A HREF="chrome://settings">Chrome Settings</A>
                <DT><A HREF="">Empty URL</A>
                <DT><A HREF="https://valid.com">Valid Link</A>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 1)
            let link = try #require(importResult.workspace.nodes[safe: 0]?.asLink)
            #expect(link.url == "https://valid.com")
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - HTML Entities in Folder Names

    @Test("HTML entities decoded in folder names")
    func testHTMLEntitiesInFolderNames() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><H3>Tom &amp; Jerry&#39;s Folder</H3>
                <DL><p>
                    <DT><A HREF="https://example.com">Link</A>
                </DL><p>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            if case .folder(let folder)? = importResult.workspace.nodes[safe: 0] {
                #expect(folder.name == "Tom & Jerry's Folder")
            } else {
                Issue.record("Expected a folder node")
            }
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - HTML Entity Double-Decoding Prevention

    @Test("HTML entities with escaped ampersands are not double-decoded")
    func testHTMLEntitiesNotDoubleDeccoded() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://example.com">A &amp;lt; B</A>
                <DT><A HREF="https://example2.com">Use &amp;amp; for ampersands</A>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            let nodes = importResult.workspace.nodes
            #expect(nodes.count == 2)

            if case .link(let link1)? = nodes[safe: 0] {
                #expect(link1.title == "A &lt; B")
            } else {
                Issue.record("Expected a link node")
            }

            if case .link(let link2)? = nodes[safe: 1] {
                #expect(link2.title == "Use &amp; for ampersands")
            } else {
                Issue.record("Expected a link node")
            }
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - Mixed Content

    @Test("Mixed folders and links at same level")
    func testMixedContent() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://standalone.com">Standalone</A>
                <DT><H3>My Folder</H3>
                <DL><p>
                    <DT><A HREF="https://nested.com">Nested</A>
                </DL><p>
                <DT><A HREF="https://another.com">Another</A>
            </DL><p>
        """)

        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }

        let result = await ChromeImportService.shared.importFromChrome(fileURL: fileURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 3)
            #expect(importResult.foldersImported == 1)

            let nodes = importResult.workspace.nodes
            #expect(nodes.count == 3)

            let l1 = try #require(nodes[safe: 0]?.asLink)
            #expect(l1.title == "Standalone")
            let f = try #require(nodes[safe: 1]?.asFolder)
            #expect(f.name == "My Folder")
            let l2 = try #require(nodes[safe: 2]?.asLink)
            #expect(l2.title == "Another")
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
        }
    }

    // MARK: - Malformed and minified files

    /// Imports `html` and returns the result, recording an issue on failure.
    private func importSucceeding(_ html: String) async throws -> ChromeImportResult {
        let fileURL = try writeTempFile(html)
        defer { cleanup(fileURL) }
        switch await ChromeImportService.shared.importFromChrome(fileURL: fileURL) {
        case .success(let result):
            return result
        case .failure(let error):
            Issue.record("Import should succeed: \(error)")
            throw error
        }
    }

    /// The tree as indented lines: `Folder` for a folder, `title url` for a link.
    private func outline(_ nodes: [Node], depth: Int = 0) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        return nodes.flatMap { node -> [String] in
            switch node {
            case .link(let link): return ["\(indent)\(link.title) \(link.url)"]
            case .folder(let folder): return ["\(indent)\(folder.name)/"] + outline(folder.children, depth: depth + 1)
            case .note: return ["\(indent)note"]
            }
        }
    }

    @Test("Folders left open by missing </DL> keep their links")
    func testMissingClosingListKeepsLinks() async throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3>Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://top.com">Top</A>
                <DT><H3>Work</H3>
                <DL><p>
                    <DT><A HREF="https://a.com">A</A>
                    <DT><H3>Deep</H3>
                    <DL><p>
                        <DT><A HREF="https://b.com">B</A>
        """
        let result = try await importSucceeding(html)
        #expect(outline(result.workspace.nodes) == [
            "Top https://top.com",
            "Work/",
            "  A https://a.com",
            "  Deep/",
            "    B https://b.com"
        ])
        #expect(result.linksImported == 3)
        #expect(result.foldersImported == 2)
    }

    @Test("A minified one-line file imports every link and folder")
    func testMinifiedSingleLineFile() async throws {
        let html = #"<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><p><DT><H3>Bookmarks bar</H3><DL><p><DT><A HREF="https://a.com">A</A><DT><H3>Sub</H3><DL><p><DT><A HREF="https://b.com">B</A></DL><p><DT><A HREF="https://c.com">C</A></DL><p></DL><p>"#
        let result = try await importSucceeding(html)
        #expect(outline(result.workspace.nodes) == [
            "A https://a.com",
            "Sub/",
            "  B https://b.com",
            "C https://c.com"
        ])
    }

    @Test("HREF is found among the attributes in any order, case and quoting")
    func testHrefAttributeInAnyPosition() async throws {
        let html = createBookmarksHTML(body: """
            <DT><A ADD_DATE="1" HREF="https://first.com" ICON="data:image/png;base64,AAA=">First</A>
            <DT><a add_date="2" href='https://single.com'>Single</a>
            <DT><A TAGS="a>b" HREF="https://quoted-gt.com">Quoted gt</A>
            <DT><A
                ADD_DATE="3"
                HREF=https://unquoted.com>Unquoted</A>
            <DT><A DATA-HREF="https://not-a-link.com" HREF="https://real.com">Real</A>
        """)
        let result = try await importSucceeding(html)
        #expect(outline(result.workspace.nodes) == [
            "First https://first.com",
            "Single https://single.com",
            "Quoted gt https://quoted-gt.com",
            "Unquoted https://unquoted.com",
            "Real https://real.com"
        ])
    }

    @Test("A heading missing </H3> doesn't swallow the links after it")
    func testHeadingWithoutClosingTag() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Broken
            <DL><p>
                <DT><A HREF="https://x.com">X</A>
            </DL><p>
            <DT><H3>Later</H3>
            <DL><p>
                <DT><A HREF="https://y.com">Y</A>
            </DL><p>
        """)
        let result = try await importSucceeding(html)
        #expect(outline(result.workspace.nodes) == [
            "Broken/",
            "  X https://x.com",
            "Later/",
            "  Y https://y.com"
        ])
    }

    @Test("A folder heading without its list and a stray </DL> keep the structure")
    func testHeadingWithoutListAndStrayClose() async throws {
        let html = createBookmarksHTML(body: """
            <DT><H3>Empty</H3>
            <DT><H3>Full</H3>
            <DL><p>
                <DT><A HREF="https://in.com">In</A>
            </DL><p>
            </DL><p>
            <DT><A HREF="https://after.com">After</A>
        """)
        let result = try await importSucceeding(html)
        #expect(outline(result.workspace.nodes) == [
            "Empty/",
            "Full/",
            "  In https://in.com",
            "After https://after.com"
        ])
    }

    @Test("HREF entities are decoded and spaces encoded, in any quoting")
    func testHrefEntitiesAndSpaces() async throws {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <DL><p>
            <DT><A HREF="https://example.com/search?a=1&amp;b=2&#38;c=3">Firefox style</A>
            <DT><A HREF='https://example.com/my page?q=two words'>Spaces</A>
            <DT><A HREF="https://example.com/&quot;quoted&quot;">Quoted</A>
            <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
        </DL><p>
        """
        let result = try await importSucceeding(html)
        #expect(outline(result.workspace.nodes) == [
            "Firefox style https://example.com/search?a=1&b=2&c=3",
            "Spaces https://example.com/my%20page?q=two%20words",
            "Quoted https://example.com/%22quoted%22"
        ])
    }
}

// MARK: - Equatable for ChromeImportError (for test assertions)

extension ChromeImportError: Equatable {
    public static func == (lhs: ChromeImportError, rhs: ChromeImportError) -> Bool {
        switch (lhs, rhs) {
        case (.fileNotFound, .fileNotFound): return true
        case (.invalidHTML, .invalidHTML): return true
        case (.noBookmarksFound, .noBookmarksFound): return true
        case (.parsingFailed(let a), .parsingFailed(let b)): return a == b
        default: return false
        }
    }
}
