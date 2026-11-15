import Foundation

// MARK: - Chrome Import Result

/// Result of a Chrome bookmark import operation
struct ChromeImportResult: Sendable {
    let workspace: ImportWorkspace
    let linksImported: Int
    let foldersImported: Int
}

// MARK: - Chrome Import Errors

/// Errors that can occur during Chrome bookmark import
enum ChromeImportError: Error {
    case fileNotFound
    case invalidHTML
    case noBookmarksFound
    case parsingFailed(String)
}

extension ChromeImportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "The selected file could not be found."
        case .invalidHTML:
            return "The selected file is not a valid Chrome bookmarks HTML file."
        case .noBookmarksFound:
            return "No bookmarks were found in the file."
        case .parsingFailed(let detail):
            return "Failed to parse Chrome bookmarks: \(detail)"
        }
    }
}

// MARK: - Chrome Import Service

final class ChromeImportService: Sendable {
    static let shared = ChromeImportService()

    private init() {}

    /// Import bookmarks from a Chrome bookmarks HTML file
    /// - Parameter fileURL: URL to the exported Chrome bookmarks HTML file
    /// - Returns: Result containing import statistics or error
    func importFromChrome(fileURL: URL) async -> Result<ChromeImportResult, ChromeImportError> {
        await Task.yield()

        return await Task.detached {
            do {
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    return .failure(.fileNotFound)
                }

                let content = try String(contentsOf: fileURL, encoding: .utf8)

                // Validate this is a Netscape bookmark file
                guard content.contains("NETSCAPE-Bookmark-file-1") || content.contains("<DL>") || content.contains("<dl>") else {
                    return .failure(.invalidHTML)
                }

                let nodes = try self.parseBookmarksHTML(content)

                guard !nodes.isEmpty else {
                    return .failure(.noBookmarksFound)
                }

                let stats = self.countNodes(nodes)

                let workspace = ImportWorkspace(
                    name: "Imported Bookmarks",
                    colorId: .ember,
                    nodes: nodes
                )

                let result = ChromeImportResult(
                    workspace: workspace,
                    linksImported: stats.links,
                    foldersImported: stats.folders
                )

                return .success(result)

            } catch let error as ChromeImportError {
                return .failure(error)
            } catch {
                return .failure(.parsingFailed(error.localizedDescription))
            }
        }.value
    }

    // MARK: - Private Methods

    /// Top-level Chrome folders whose contents go straight to the root.
    private static let topLevelFolderNames: Set<String> = ["Bookmarks bar", "Other bookmarks", "Mobile bookmarks", "Bookmarks Bar"]

    /// Parses a Netscape bookmark file with one scan over its tags, in document
    /// order, so line breaks don't matter (a minified one-line file works) and
    /// `HREF` may be anywhere among the link's attributes.
    ///
    /// `<H3>` names a folder whose contents are the next `<DL>`; `</DL>` closes the
    /// innermost `<DL>`, and only one that opened a folder closes that folder.
    /// Malformed files lose no links: an `<H3>` without its `<DL>` becomes an empty
    /// folder, a stray `</DL>` is ignored, and folders still open at the end of
    /// the file (missing `</DL>`) are closed into their parents.
    private func parseBookmarksHTML(_ content: String) throws -> [Node] {
        // An attribute list that may contain `>` inside quoted values.
        let attributes = #"((?:\s+[^\s=>"']+(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'>]+))?)*)\s*"#
        let tokenPattern = try NSRegularExpression(
            pattern: #"<H3\b[^>]*>([^<]*)(?:</H3\s*>)?|<A\b"# + attributes + #">([^<]*)|<DL\b[^>]*>|</DL\s*>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let hrefPattern = try NSRegularExpression(
            pattern: #"(?:^|\s)HREF\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#,
            options: .caseInsensitive
        )

        struct Level {
            let folderName: String?
            var nodes: [Node] = []
        }
        // The root, then one level per open folder.
        var levels = [Level(folderName: nil)]
        // One entry per open <DL>: whether it opened a folder level.
        var openLists: [Bool] = []
        var pendingFolderName: String?

        func closeLevel() {
            let level = levels.removeLast()
            let name = level.folderName ?? "Untitled Folder"
            if levels.count == 1 && Self.topLevelFolderNames.contains(name) {
                levels[0].nodes.append(contentsOf: level.nodes)
            } else {
                let folder = Folder(id: UUID(), name: name, children: level.nodes, isExpanded: false)
                levels[levels.count - 1].nodes.append(.folder(folder))
            }
        }

        // A folder heading not followed by its <DL> is kept as an empty folder.
        func flushPendingFolder() {
            guard let name = pendingFolderName else { return }
            pendingFolderName = nil
            levels.append(Level(folderName: name))
            closeLevel()
        }

        func capture(_ match: NSTextCheckingResult, _ index: Int, in string: String) -> String? {
            Range(match.range(at: index), in: string).map { String(string[$0]) }
        }

        let fullRange = NSRange(content.startIndex..., in: content)
        for match in tokenPattern.matches(in: content, range: fullRange) {
            guard let token = capture(match, 0, in: content) else { continue }

            if let folderName = capture(match, 1, in: content) {
                flushPendingFolder()
                pendingFolderName = decodeHTMLEntities(folderName.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let attributeList = capture(match, 2, in: content) {
                flushPendingFolder()
                let attributeRange = NSRange(attributeList.startIndex..., in: attributeList)
                guard let hrefMatch = hrefPattern.firstMatch(in: attributeList, range: attributeRange) else { continue }
                let urlString = (1...3).lazy.compactMap { capture(hrefMatch, $0, in: attributeList) }.first ?? ""
                var title = decodeHTMLEntities((capture(match, 3, in: content) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                if title.isEmpty {
                    title = "Untitled"
                }
                if urlString.isEmpty ||
                    urlString.hasPrefix("javascript:") ||
                    urlString.hasPrefix("chrome://") ||
                    URL(string: urlString) == nil {
                    continue
                }
                let link = Link(id: UUID(), title: title, url: urlString, faviconPath: nil)
                levels[levels.count - 1].nodes.append(.link(link))
            } else if token.hasPrefix("</") {
                flushPendingFolder()
                guard let openedFolder = openLists.popLast() else { continue }
                if openedFolder {
                    closeLevel()
                }
            } else if let name = pendingFolderName {
                // <DL>: the contents of the folder just named.
                pendingFolderName = nil
                levels.append(Level(folderName: name))
                openLists.append(true)
            } else {
                // <DL> without a heading (the root list): structure only.
                openLists.append(false)
            }
        }

        // Missing </DL>s: close what's still open into its parent.
        flushPendingFolder()
        while levels.count > 1 {
            closeLevel()
        }
        return levels[0].nodes
    }

    /// Decode common HTML entities in a string
    private func decodeHTMLEntities(_ string: String) -> String {
        var result = string
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&amp;", with: "&") // must be last to avoid double-decoding
        return result
    }

    /// Count links and folders in a node array
    private func countNodes(_ nodes: [Node]) -> (links: Int, folders: Int) {
        var links = 0
        var folders = 0

        for node in nodes {
            switch node {
            case .link:
                links += 1
            case .note:
                continue
            case .folder(let folder):
                folders += 1
                let childStats = countNodes(folder.children)
                links += childStats.links
                folders += childStats.folders
            }
        }

        return (links, folders)
    }
}
