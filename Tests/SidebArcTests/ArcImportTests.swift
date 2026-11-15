import Foundation
import Testing
@testable import SidebArcCore

@Suite struct ArcImportTests {
    private let scratch = TempDir()
    private let testDefaults = TestDefaults()

    // MARK: - Test Data Generation

    /// Creates minimal valid Arc JSON data for testing
    private func createArcJSON(
        spaces: [[String: Any?]],
        items: [[String: Any?]],
        topApps: [Any] = []
    ) throws -> Data {
        let arcData: [String: Any] = [
            "version": 1,
            "sidebar": [
                "containers": [
                    ["global": [:]], // Empty global container
                    [
                        "spaces": spaces,
                        "items": items,
                        "topAppsContainerIDs": topApps
                    ]
                ]
            ]
        ]

        return try JSONSerialization.data(withJSONObject: arcData, options: [])
    }

    /// Creates a test space with optional title
    private func createSpace(id: String = "space1", title: String?, containerIDs: [String] = ["pinned", "container1"]) -> [String: Any?] {
        return [
            "id": id,
            "title": title,
            "containerIDs": containerIDs
        ]
    }

    /// Creates a test link item with optional title
    private func createLinkItem(
        id: String,
        parentID: String,
        savedTitle: String?,
        savedURL: String?
    ) -> [String: Any?] {
        return [
            "id": id,
            "title": savedTitle as Any, // Item-level title (not used for links)
            "parentID": parentID,
            "childrenIds": nil,
            "data": [
                "tab": [
                    "savedTitle": savedTitle as Any,
                    "savedURL": savedURL as Any,
                    "timeLastActiveAt": 1234567890.0
                ]
            ]
        ]
    }

    /// Creates a test folder item with optional title
    private func createFolderItem(
        id: String,
        parentID: String,
        title: String?,
        childrenIds: [String] = []
    ) -> [String: Any?] {
        return [
            "id": id,
            "title": title,
            "parentID": parentID,
            "childrenIds": childrenIds,
            "data": nil
        ]
    }

    // MARK: - Null Field Tests

    @Test func testSpaceWithNullTitle() async throws {
        // Arrange: Create Arc data with a space that has null title
        let spaces = [
            createSpace(id: "space1", title: nil) // NULL title
        ]

        let items = [
            createLinkItem(
                id: "link1",
                parentID: "container1",
                savedTitle: "Example Link",
                savedURL: "https://example.com"
            )
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)

        // Act: Write to temp file and import
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)

        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)

        // Assert: Import should succeed with fallback to "Untitled"
        switch result {
        case .success(let importResult):
            #expect(importResult.workspacesCreated == 1, "Should import workspace even with null title")
            #expect(importResult.workspaces[safe: 0]?.name == "Untitled", "Should use 'Untitled' for null space title")
            #expect(importResult.linksImported == 1, "Should import the link")
        case .failure(let error):
            Issue.record("Import should succeed with null space title, but failed with: \(error)")
        }
    }

    @Test func testLinkWithNullSavedTitle() async throws {
        // Arrange: Create Arc data with a link that has null savedTitle
        let spaces = [
            createSpace(id: "space1", title: "My Space")
        ]

        let items = [
            createLinkItem(
                id: "link1",
                parentID: "container1",
                savedTitle: nil, // NULL savedTitle
                savedURL: "https://example.com"
            )
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)

        // Act
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)

        try? FileManager.default.removeItem(at: tempURL)

        // Assert: Import should succeed with fallback to "Untitled"
        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 1, "Should import link even with null savedTitle")
            let firstNode = try #require(importResult.workspaces.first).nodes.first
            if case .link(let link) = firstNode {
                #expect(link.title == "Untitled", "Should use 'Untitled' for null savedTitle")
                #expect(link.url == "https://example.com")
            } else {
                Issue.record("Expected link node")
            }
        case .failure(let error):
            Issue.record("Import should succeed with null savedTitle, but failed with: \(error)")
        }
    }

    @Test func testLinkWithNullSavedURL() async throws {
        // Arrange: Create Arc data with a link that has null savedURL
        let spaces = [
            createSpace(id: "space1", title: "My Space")
        ]

        let items = [
            createLinkItem(
                id: "link1",
                parentID: "container1",
                savedTitle: "Example Link",
                savedURL: nil // NULL savedURL
            )
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)

        // Act
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)

        try? FileManager.default.removeItem(at: tempURL)

        // Assert: Link with null URL should be skipped (invalid)
        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 0, "Should skip link with null savedURL")
        case .failure(let error):
            Issue.record("Import should succeed but skip invalid link, but failed with: \(error)")
        }
    }

    @Test func testUnsupportedURLSchemeIsPreserved() async throws {
        let items = [
            createLinkItem(
                id: "link1",
                parentID: "container1",
                savedTitle: "Local file",
                savedURL: "file:///tmp/run.command"
            )
        ]
        let result = try await importJSON(createArcJSON(
            spaces: [createSpace(id: "space1", title: "Home")],
            items: items
        ))

        #expect(result.linksImported == 1)
        guard case .link(let link) = try #require(result.workspaces.first?.nodes.first) else {
            Issue.record("Expected imported link")
            return
        }
        #expect(link.url == "file:///tmp/run.command")
        #expect(BrowserManager.validatedLinkURL(from: link.url) != nil)
    }

    @Test func testFolderWithNullTitle() async throws {
        // Arrange: Create Arc data with a folder that has null title
        let spaces = [
            createSpace(id: "space1", title: "My Space")
        ]

        let items = [
            createFolderItem(
                id: "folder1",
                parentID: "container1",
                title: nil, // NULL title
                childrenIds: ["link1"]
            ),
            createLinkItem(
                id: "link1",
                parentID: "folder1",
                savedTitle: "Child Link",
                savedURL: "https://example.com"
            )
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)

        // Act
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)

        try? FileManager.default.removeItem(at: tempURL)

        // Assert: Import should succeed with fallback to "Untitled Folder"
        switch result {
        case .success(let importResult):
            #expect(importResult.foldersImported == 1, "Should import folder even with null title")
            let firstNode = try #require(importResult.workspaces.first).nodes.first
            if case .folder(let folder) = firstNode {
                #expect(folder.name == "Untitled Folder", "Should use 'Untitled Folder' for null folder title")
                #expect(folder.children.count == 1, "Should import child link")
            } else {
                Issue.record("Expected folder node")
            }
        case .failure(let error):
            Issue.record("Import should succeed with null folder title, but failed with: \(error)")
        }
    }

    @Test func testMultipleItemsWithMixedNullFields() async throws {
        // Arrange: Real-world scenario with mix of valid and null fields
        let spaces = [
            createSpace(id: "space1", title: "Valid Space", containerIDs: ["pinned", "container1"]),
            createSpace(id: "space2", title: nil, containerIDs: ["pinned", "container2"]) // NULL title
        ]

        let items = [
            // Valid link in space 1
            createLinkItem(
                id: "link1",
                parentID: "container1",
                savedTitle: "Valid Link",
                savedURL: "https://valid.com"
            ),
            // Link with null title in space 1
            createLinkItem(
                id: "link2",
                parentID: "container1",
                savedTitle: nil, // NULL
                savedURL: "https://example.com"
            ),
            // Link with null URL (should be skipped)
            createLinkItem(
                id: "link3",
                parentID: "container1",
                savedTitle: "Bad Link",
                savedURL: nil // NULL - invalid
            ),
            // Valid folder in space 2
            createFolderItem(
                id: "folder1",
                parentID: "container2",
                title: "Valid Folder",
                childrenIds: ["link4"]
            ),
            // Link in folder with null title
            createLinkItem(
                id: "link4",
                parentID: "folder1",
                savedTitle: nil, // NULL
                savedURL: "https://nested.com"
            )
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)

        // Act
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)

        try? FileManager.default.removeItem(at: tempURL)

        // Assert
        switch result {
        case .success(let importResult):
            #expect(importResult.workspacesCreated == 2, "Should import both spaces")
            #expect(importResult.linksImported == 3, "Should import 3 valid links (skip link3 with null URL)")
            #expect(importResult.foldersImported == 1, "Should import 1 folder")

            // Verify space 2 has "Untitled" name
            if importResult.workspaces.count == 2 {
                #expect(importResult.workspaces[safe: 1]?.name == "Untitled", "Space 2 should use 'Untitled'")
            }
        case .failure(let error):
            Issue.record("Import should succeed with mixed null fields, but failed with: \(error)")
        }
    }

    // MARK: - childrenIds Traversal Tests

    @Test func testChildrenIdsTraversal_FolderChildrenFoundViaChildrenIds() async throws {
        // Arc stores parent-child relationships in childrenIds. The parentID field
        // on the child may NOT match the folder's id — it can point to the container.
        let spaces = [
            createSpace(id: "space1", title: "Test Space")
        ]

        let items: [[String: Any?]] = [
            // Folder at root of pinned container — parentID points to container
            [
                "id": "folder1",
                "title": "My Folder",
                "parentID": "container1",
                "childrenIds": ["link-inside-folder"],
                "data": nil
            ],
            // Link that folder claims as child via childrenIds,
            // BUT whose parentID points to the container (not the folder)
            [
                "id": "link-inside-folder",
                "title": nil,
                "parentID": "container1",  // Mismatched! Points to container, not folder
                "childrenIds": [],
                "data": [
                    "tab": [
                        "savedTitle": "Nested Link",
                        "savedURL": "https://nested.example.com",
                        "timeLastActiveAt": 1234567890.0
                    ]
                ]
            ],
            // A link directly under the container
            [
                "id": "root-link",
                "title": nil,
                "parentID": "container1",
                "childrenIds": [],
                "data": [
                    "tab": [
                        "savedTitle": "Root Link",
                        "savedURL": "https://root.example.com",
                        "timeLastActiveAt": 1234567890.0
                    ]
                ]
            ]
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)
        try? FileManager.default.removeItem(at: tempURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.workspacesCreated == 1)
            #expect(importResult.linksImported == 2, "Should find both links")
            #expect(importResult.foldersImported == 1)

            // The folder should contain the nested link (found via childrenIds)
            let folderNode = try #require(importResult.workspaces.first).nodes.compactMap { node -> Folder? in
                if case .folder(let f) = node { return f }
                return nil
            }.first

            #expect(folderNode != nil, "Should have a folder")
            #expect(folderNode?.children.count == 1, "Folder should have 1 child via childrenIds")

            if case .link(let link) = folderNode?.children.first {
                #expect(link.title == "Nested Link")
                #expect(link.url == "https://nested.example.com")
            } else {
                Issue.record("Expected link inside folder")
            }
        case .failure(let error):
            Issue.record("Import failed: \(error)")
        }
    }

    @Test func testChildrenIdsTraversal_DeepNesting() async throws {
        // Verify childrenIds traversal works for deeply nested structures
        let spaces = [
            createSpace(id: "space1", title: "Deep Space")
        ]

        let items: [[String: Any?]] = [
            // Top-level folder
            [
                "id": "folder-top",
                "title": "Top",
                "parentID": "container1",
                "childrenIds": ["folder-mid"],
                "data": nil
            ],
            // Mid-level folder (child of top, but parentID could differ)
            [
                "id": "folder-mid",
                "title": "Middle",
                "parentID": "container1",  // parentID mismatch
                "childrenIds": ["link-deep"],
                "data": nil
            ],
            // Deep link
            [
                "id": "link-deep",
                "title": nil,
                "parentID": "container1",  // parentID mismatch
                "childrenIds": [],
                "data": [
                    "tab": [
                        "savedTitle": "Deep Link",
                        "savedURL": "https://deep.example.com",
                        "timeLastActiveAt": 1234567890.0
                    ]
                ]
            ]
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)
        try? FileManager.default.removeItem(at: tempURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 1)
            #expect(importResult.foldersImported == 2)

            // Verify the nesting: Top > Middle > Deep Link
            guard let topFolder = try #require(importResult.workspaces.first).nodes.compactMap({ node -> Folder? in
                if case .folder(let f) = node { return f }
                return nil
            }).first else {
                Issue.record("Expected top folder"); return
            }

            #expect(topFolder.name == "Top")
            #expect(topFolder.children.count == 1)

            if case .folder(let midFolder) = topFolder.children.first {
                #expect(midFolder.name == "Middle")
                #expect(midFolder.children.count == 1)

                if case .link(let link) = midFolder.children.first {
                    #expect(link.title == "Deep Link")
                } else {
                    Issue.record("Expected link inside middle folder")
                }
            } else {
                Issue.record("Expected middle folder inside top folder")
            }
        case .failure(let error):
            Issue.record("Import failed: \(error)")
        }
    }

    @Test func testChildrenIdsTraversal_PreservesOrdering() async throws {
        // childrenIds defines the canonical order — verify it's preserved
        let spaces = [
            createSpace(id: "space1", title: "Ordered Space")
        ]

        let items: [[String: Any?]] = [
            // Container item that exists in the items map
            [
                "id": "container1",
                "title": nil,
                "parentID": nil as String?,
                "childrenIds": ["link-c", "link-a", "link-b"],  // Specific order
                "data": nil
            ],
            [
                "id": "link-a",
                "title": nil,
                "parentID": "container1",
                "childrenIds": [],
                "data": ["tab": ["savedTitle": "Alpha", "savedURL": "https://a.com", "timeLastActiveAt": 1.0]]
            ],
            [
                "id": "link-b",
                "title": nil,
                "parentID": "container1",
                "childrenIds": [],
                "data": ["tab": ["savedTitle": "Beta", "savedURL": "https://b.com", "timeLastActiveAt": 1.0]]
            ],
            [
                "id": "link-c",
                "title": nil,
                "parentID": "container1",
                "childrenIds": [],
                "data": ["tab": ["savedTitle": "Charlie", "savedURL": "https://c.com", "timeLastActiveAt": 1.0]]
            ]
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)
        try? FileManager.default.removeItem(at: tempURL)

        switch result {
        case .success(let importResult):
            let nodes = try #require(importResult.workspaces.first).nodes
            #expect(nodes.count == 3)

            // Verify order matches childrenIds: C, A, B
            let first = try #require(nodes[safe: 0]?.asLink)
            #expect(first.title == "Charlie")

            let second = try #require(nodes[safe: 1]?.asLink)
            #expect(second.title == "Alpha")

            let third = try #require(nodes[safe: 2]?.asLink)
            #expect(third.title == "Beta")
        case .failure(let error):
            Issue.record("Import failed: \(error)")
        }
    }

    @Test func testParentIDFallback_WhenContainerNotInItems() async throws {
        // When the pinned container ID doesn't exist as an item in the map,
        // the importer should fall back to parentID-based filtering
        let spaces = [
            createSpace(id: "space1", title: "Fallback Space")
        ]

        // No item has id == "container1", so fallback to parentID matching
        let items = [
            createLinkItem(
                id: "link1",
                parentID: "container1",
                savedTitle: "Link One",
                savedURL: "https://one.com"
            ),
            createLinkItem(
                id: "link2",
                parentID: "container1",
                savedTitle: "Link Two",
                savedURL: "https://two.com"
            )
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)
        try? FileManager.default.removeItem(at: tempURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 2, "Fallback should find both links via parentID")
        case .failure(let error):
            Issue.record("Import failed: \(error)")
        }
    }

    @Test func testContainerIDs_UnpinnedBeforePinned() async throws {
        // Real Arc data puts "unpinned" BEFORE "pinned" in containerIDs
        let spaces = [
            createSpace(
                id: "space1",
                title: "Real Format",
                containerIDs: ["unpinned", "unpinned-ctr", "pinned", "pinned-ctr"]
            )
        ]

        let items: [[String: Any?]] = [
            [
                "id": "pinned-ctr",
                "title": nil,
                "parentID": nil as String?,
                "childrenIds": ["pinned-link"],
                "data": nil
            ],
            [
                "id": "pinned-link",
                "title": nil,
                "parentID": "pinned-ctr",
                "childrenIds": [],
                "data": ["tab": ["savedTitle": "Pinned", "savedURL": "https://pinned.com", "timeLastActiveAt": 1.0]]
            ],
            // Unpinned item should NOT be imported
            [
                "id": "unpinned-link",
                "title": nil,
                "parentID": "unpinned-ctr",
                "childrenIds": [],
                "data": ["tab": ["savedTitle": "Unpinned", "savedURL": "https://unpinned.com", "timeLastActiveAt": 1.0]]
            ]
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)
        try? FileManager.default.removeItem(at: tempURL)

        switch result {
        case .success(let importResult):
            #expect(importResult.linksImported == 1, "Should only import pinned link")
            if case .link(let link) = try #require(importResult.workspaces.first).nodes.first {
                #expect(link.title == "Pinned")
            } else {
                Issue.record("Expected pinned link")
            }
        case .failure(let error):
            Issue.record("Import failed: \(error)")
        }
    }

    // MARK: - Integration Test with Real File

    // MARK: - Regression Test for User's File

    @Test func testUserFileWithNullSavedTitle() async throws {
        // This test simulates the exact issue from the user's StorableSidebar.json
        // where item D5547566-F700-4C85-BB55-DEC3AD41D2A1 has savedTitle: null

        let spaces = [
            createSpace(id: "space1", title: "User Space")
        ]

        let items = [
            // Normal link before the problematic one
            createLinkItem(
                id: "link-before",
                parentID: "container1",
                savedTitle: "Normal Link",
                savedURL: "https://normal.com"
            ),
            // The problematic link from the user's file
            createLinkItem(
                id: "D5547566-F700-4C85-BB55-DEC3AD41D2A1",
                parentID: "container1",
                savedTitle: nil, // THIS caused the entire import to fail
                savedURL: "https://problematic.com"
            ),
            // Normal link after the problematic one
            createLinkItem(
                id: "link-after",
                parentID: "container1",
                savedTitle: "Another Link",
                savedURL: "https://another.com"
            )
        ]

        let jsonData = try createArcJSON(spaces: spaces, items: items)

        // Act
        let tempURL = scratch.url
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")

        try jsonData.write(to: tempURL)

        let service = ArcImportService.shared
        let result = await service.importFromArc(fileURL: tempURL)

        try? FileManager.default.removeItem(at: tempURL)

        // Assert: BEFORE the fix, this would fail with .noDataContainer
        // AFTER the fix, it should successfully import all 3 links
        switch result {
        case .success(let importResult):
            #expect(importResult.workspacesCreated == 1, "Should create workspace")
            #expect(importResult.linksImported == 3, "Should import all 3 links despite null savedTitle")

            // Verify the problematic link uses "Untitled"
            let nodes = try #require(importResult.workspaces.first).nodes
            #expect(nodes.count == 3, "Should have 3 link nodes")

            // Find the problematic link by URL since order may vary
            let problematicLink = nodes.compactMap { node -> Link? in
                if case .link(let link) = node, link.url == "https://problematic.com" {
                    return link
                }
                return nil
            }.first

            #expect(problematicLink != nil, "Should find problematic link")
            #expect(problematicLink?.title == "Untitled", "Problematic link should use 'Untitled'")
        case .failure(let error):
            Issue.record("Import should succeed after fix, but failed with: \(error)")
        }
    }

    // MARK: - Cycles in childrenIds (corrupt files)

    /// The tree as indented lines: `Folder/` for a folder, the URL for a link.
    private func outline(_ nodes: [Node], depth: Int = 0) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        return nodes.flatMap { node -> [String] in
            switch node {
            case .link(let link): return ["\(indent)\(link.url)"]
            case .folder(let folder): return ["\(indent)\(folder.name)/"] + outline(folder.children, depth: depth + 1)
            case .note: return ["\(indent)note"]
            }
        }
    }

    /// An item listing itself, A → B → A, and a container listing itself: each
    /// repeated edge is dropped, every item and link is kept, nothing recurses forever.
    @Test func testCyclicChildrenIdsDropOnlyTheRepeatedEdge() async throws {
        var space = createSpace(id: "s1", title: "Loops")
        space["profile"] = ["default": true]
        let favContainer: [String: Any?] = [
            "id": "fav", "title": nil, "parentID": nil, "childrenIds": ["fav", "f1"],
            "data": ["itemContainer": ["containerType": ["topApps": ["_0": ["default": true]]]]]
        ]
        let items: [[String: Any?]] = [
            createFolderItem(id: "container1", parentID: "", title: nil, childrenIds: ["container1", "a", "self", "top"]),
            createFolderItem(id: "a", parentID: "container1", title: "A", childrenIds: ["b", "linkA"]),
            createFolderItem(id: "b", parentID: "a", title: "B", childrenIds: ["a", "linkB"]),
            createFolderItem(id: "self", parentID: "container1", title: "Self", childrenIds: ["self", "linkS"]),
            createLinkItem(id: "linkA", parentID: "a", savedTitle: "A", savedURL: "https://a.com"),
            createLinkItem(id: "linkB", parentID: "b", savedTitle: "B", savedURL: "https://b.com"),
            createLinkItem(id: "linkS", parentID: "self", savedTitle: "S", savedURL: "https://s.com"),
            createLinkItem(id: "top", parentID: "container1", savedTitle: "Top", savedURL: "https://top.com"),
            favContainer,
            createLinkItem(id: "f1", parentID: "fav", savedTitle: "Fav", savedURL: "https://fav.com"),
        ]
        let result = try await importJSON(createArcJSON(spaces: [space], items: items, topApps: [["default": true], "fav"]))

        let workspace = try #require(result.workspaces.first)
        #expect(outline(workspace.nodes) == [
            "A/",
            "  B/",
            "    https://b.com",
            "  https://a.com",
            "Self/",
            "  https://s.com",
            "https://top.com"
        ])
        #expect(result.linksImported == 4)
        #expect(result.foldersImported == 3)
        #expect(result.profiles.first?.favorites.map(\.url) == ["https://fav.com"])
    }

    // MARK: - Profiles and favorites (topAppsContainerIDs)

    private func importJSON(_ data: Data) async throws -> ArcImportResult {
        let url = scratch.url.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        switch await ArcImportService.shared.importFromArc(fileURL: url) {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    /// Real Arc layout: `[{"default": true}, "<container id>"]`, favorites are tab items
    /// whose parent is that container item.
    @Test func testFavoritesOfDefaultProfileAreImported() async throws {
        var space = createSpace(id: "s1", title: "Home")
        space["profile"] = ["default": true]
        let favContainer: [String: Any?] = [
            "id": "fav", "title": nil, "parentID": nil, "childrenIds": ["f1", "f2"],
            "data": ["itemContainer": ["containerType": ["topApps": ["_0": ["default": true]]]]]
        ]
        let items = [
            createLinkItem(id: "l1", parentID: "container1", savedTitle: "List", savedURL: "https://list.com"),
            favContainer,
            createLinkItem(id: "f1", parentID: "fav", savedTitle: "Mail", savedURL: "https://mail.com"),
            createLinkItem(id: "f2", parentID: "fav", savedTitle: "Docs", savedURL: "https://docs.com"),
        ]
        let result = try await importJSON(createArcJSON(spaces: [space], items: items, topApps: [["default": true], "fav"]))

        #expect(result.workspaces.map(\.name) == ["Home"])
        #expect(result.workspaces[safe: 0]?.arcProfile == .default)
        #expect(result.profiles.count == 1)
        #expect(result.profiles[safe: 0]?.arcProfile.name == "Default")
        #expect(result.profiles[safe: 0]?.favorites.map(\.url) == ["https://mail.com", "https://docs.com"])
        // Favorites are not counted as list links.
        #expect(result.linksImported == 1)
    }

    @Test func testCustomProfileGetsItsOwnKeyAndName() async throws {
        let custom: [String: Any] = ["custom": ["_0": ["directoryBasename": "Profile 1"]]]
        var work = createSpace(id: "s2", title: "Work", containerIDs: ["pinned", "c2"])
        work["profile"] = custom
        var home = createSpace(id: "s1", title: "Home")
        home["profile"] = ["default": true]
        let items = [
            createLinkItem(id: "l1", parentID: "container1", savedTitle: "A", savedURL: "https://a.com"),
            createLinkItem(id: "l2", parentID: "c2", savedTitle: "B", savedURL: "https://b.com"),
            createLinkItem(id: "f1", parentID: "workFav", savedTitle: "W", savedURL: "https://w.com"),
        ]
        let result = try await importJSON(createArcJSON(spaces: [home, work], items: items, topApps: [custom, "workFav"]))

        let workProfile = try #require(result.workspaces.first(where: { $0.name == "Work" })?.arcProfile)
        #expect(workProfile.name == "Arc Profile 1")
        #expect(workProfile != .default)
        #expect(result.profiles.map(\.arcProfile) == [workProfile])
    }

    @Test func testMissingOrMalformedTopAppsImportsNoFavorites() async throws {
        let items = [createLinkItem(id: "l1", parentID: "container1", savedTitle: "A", savedURL: "https://a.com")]
        for topApps in [[], ["dangling-profile-only"], [["default": true]]] as [[Any]] {
            let result = try await importJSON(createArcJSON(spaces: [createSpace(title: "S")], items: items, topApps: topApps))
            #expect(result.profiles.isEmpty)
            #expect(result.workspacesCreated == 1)
        }
    }

    @Test func testSpaceWithoutProfileFieldUsesDefault() async throws {
        let items = [createLinkItem(id: "l1", parentID: "container1", savedTitle: "A", savedURL: "https://a.com")]
        let result = try await importJSON(createArcJSON(spaces: [createSpace(title: "S")], items: items))
        #expect(result.workspaces[safe: 0]?.arcProfile == .default)
    }

    // MARK: - Opt-in acceptance check against a real StorableSidebar.json

    /// Set SIDEBARC_ARC_FIXTURE to a copy of a real StorableSidebar.json to run this.
    /// Prints only counts, never titles or URLs.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIDEBARC_ARC_FIXTURE"] != nil))
    func testRealArcFileImportsFavoritesPerProfile() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SIDEBARC_ARC_FIXTURE"])
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        let result = try await importJSON(raw)

        // Ground truth from the raw JSON: the tab children of each favorites container.
        let root = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let containers = try #require((root["sidebar"] as? [String: Any])?["containers"] as? [Any])
        let data = try #require(containers.compactMap { $0 as? [String: Any] }.first(where: { $0["spaces"] != nil }))
        let items = (data["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let byId = Dictionary(items.compactMap { item in (item["id"] as? String).map { ($0, item) } }, uniquingKeysWith: { a, _ in a })
        let topApps = data["topAppsContainerIDs"] as? [Any] ?? []
        var expectedFavorites = 0
        for index in stride(from: 1, to: topApps.count, by: 2) {
            let children = (byId[topApps[index] as? String ?? ""]?["childrenIds"] as? [String]) ?? []
            expectedFavorites += children.filter { id in
                let tab = (byId[id]?["data"] as? [String: Any])?["tab"] as? [String: Any]
                return !((tab?["savedURL"] as? String) ?? "").isEmpty
            }.count
        }

        let imported = result.profiles.reduce(0) { $0 + $1.favorites.count }
        print("Arc fixture: \(result.workspacesCreated) spaces, \(result.linksImported) links, \(result.foldersImported) folders, \(result.profiles.count) profile(s) with \(imported) favorites (expected \(expectedFavorites))")
        #expect(imported == expectedFavorites)
        #expect(expectedFavorites > 0)

        // Apply to a fresh model: nothing is dropped.
        let store = DataStore(baseDirectory: scratch.url.appendingPathComponent(UUID().uuidString))
        store.save(DataStore.defaultState())
        let model = AppModel(store: store, defaults: testDefaults.suite)
        model.applyArcImport(result)
        let favoritesInModel = model.profiles.reduce(0) { $0 + $1.favorites.count }
        let migratedFolder = model.workspaces.flatMap(\.items).compactMap { node -> Int? in
            if case .folder(let folder) = node, folder.name == AppModel.arcFavoritesFolderName { return folder.children.count }
            return nil
        }.reduce(0, +)
        print("Applied: \(model.profiles.count) profile(s), \(model.workspaces.count) spaces, \(favoritesInModel) favorites + \(migratedFolder) in overflow folders")
        #expect(favoritesInModel + migratedFolder == imported)
    }

    /// Arc writes Chromium's canonical URLs, but a hand-edited or other-tool file may
    /// not: a space must not make the link depend on the macOS version.
    @Test func savedURLsWithSpacesAreEncoded() async throws {
        let items = [
            createLinkItem(id: "a", parentID: "container1", savedTitle: "Spaced", savedURL: "https://example.com/a b?q=c d"),
            createLinkItem(id: "b", parentID: "container1", savedTitle: "Plain", savedURL: "https://example.com/plain"),
            createLinkItem(id: "c", parentID: "container1", savedTitle: "Blank", savedURL: "   ")
        ]
        let url = scratch.url.appendingPathComponent("spaces.json")
        try createArcJSON(spaces: [createSpace(title: "Space")], items: items).write(to: url)

        guard case .success(let result) = await ArcImportService.shared.importFromArc(fileURL: url) else {
            Issue.record("Import failed")
            return
        }
        let urls = try #require(result.workspaces.first).nodes.compactMap { $0.asLink?.url }
        // No container childrenIds here, so the order isn't defined; the blank URL is skipped.
        #expect(urls.sorted() == ["https://example.com/a%20b?q=c%20d", "https://example.com/plain"])
    }
}
