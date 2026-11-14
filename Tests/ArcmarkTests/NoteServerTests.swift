import Foundation
import Testing
@testable import ArcmarkCore

@MainActor
@Suite struct NoteServerTests {
    private func makeStore() -> DataStore {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return DataStore(baseDirectory: temp)
    }

    private func startServer() async throws -> (NoteServer, AppModel) {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store)
        let server = NoteServer(model: model)
        server.start()

        // Wait briefly for the listener to enter .ready
        for _ in 0..<50 {
            if server.port > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(server.port > 0, "Server did not bind to a port")
        return (server, model)
    }

    private func request(method: String, path: String, host: String? = nil, body: Data? = nil, port: UInt16) async throws -> (status: Int, body: Data) {
        var url = URLComponents()
        url.scheme = "http"
        url.host = "127.0.0.1"
        url.port = Int(port)
        url.path = path.components(separatedBy: "?").first ?? path
        if let q = path.components(separatedBy: "?").dropFirst().first {
            url.percentEncodedQuery = q
        }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        return (httpResponse.statusCode, data)
    }

    @Test func testServerStartsOnEphemeralPort() async throws {
        let (server, _) = try await startServer()
        defer { server.stop() }
        #expect(server.port > 0)
    }

    @Test func testGetReturnsNoteJSON() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let noteId = model.addNote(title: "Server Test", parentId: nil)

        let (status, body) = try await request(
            method: "GET",
            path: "/api/notes/\(noteId.uuidString)",
            port: server.port
        )
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["title"] as? String == "Server Test")
        #expect((json?["content"] as? String ?? "").contains("# Untitled"))
    }

    @Test func testGetReturns404WhenNoteDeleted() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let noteId = model.addNote(title: "Doomed", parentId: nil)
        model.deleteNode(id: noteId)

        let (status, _) = try await request(
            method: "GET",
            path: "/api/notes/\(noteId.uuidString)",
            port: server.port
        )
        #expect(status == 404)
    }

    @Test func testPutReturns404WhenNoteDeleted() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let noteId = model.addNote(title: "Doomed", parentId: nil)
        model.deleteNode(id: noteId)

        let body = try JSONSerialization.data(withJSONObject: ["content": "should not write"])
        let (status, _) = try await request(
            method: "PUT",
            path: "/api/notes/\(noteId.uuidString)",
            body: body,
            port: server.port
        )
        #expect(status == 404)
        #expect(model.noteStorage.read(id: noteId) == "")
    }

    @Test func testPutWritesContent() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let noteId = model.addNote(title: "Writable", parentId: nil)

        let body = try JSONSerialization.data(withJSONObject: ["content": "## Updated"])
        let (status, _) = try await request(
            method: "PUT",
            path: "/api/notes/\(noteId.uuidString)",
            body: body,
            port: server.port
        )
        #expect(status == 200)
        #expect(model.noteStorage.read(id: noteId) == "## Updated")
    }

    // MARK: - Agent API round-trips

    private func apiRequest(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        port: UInt16
    ) async throws -> (status: Int, json: [String: Any]) {
        let data = body.map { try? JSONSerialization.data(withJSONObject: $0) } ?? nil
        let (status, raw) = try await request(method: method, path: path, body: data ?? nil, port: port)
        let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
        return (status, parsed)
    }

    @Test func testWorkspaceRoundTrip() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }

        let (createStatus, createJson) = try await apiRequest(
            "POST", "/api/workspaces",
            body: ["name": "Reading", "colorId": "leaf"],
            port: server.port
        )
        #expect(createStatus == 200)
        #expect(createJson["ok"] as? Bool == true)
        let id = try #require(createJson["id"] as? String)
        let uuid = try #require(UUID(uuidString: id))
        #expect(model.workspaces.contains(where: { $0.id == uuid }))

        let (renameStatus, _) = try await apiRequest(
            "PATCH", "/api/workspaces/\(id)",
            body: ["name": "Reading List"],
            port: server.port
        )
        #expect(renameStatus == 200)
        #expect(model.workspaces.first(where: { $0.id == uuid })?.name == "Reading List")
    }

    @Test func testFolderRoundTrip() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let wsId = try #require(model.workspaces.first?.id).uuidString

        let (createStatus, createJson) = try await apiRequest(
            "POST", "/api/folders",
            body: ["workspace_id": wsId, "name": "Inbox"],
            port: server.port
        )
        #expect(createStatus == 200)
        let id = try #require(createJson["id"] as? String)
        let uuid = try #require(UUID(uuidString: id))

        let node = try #require(model.nodeAcrossWorkspaces(id: uuid))
        guard case .folder(let folder) = node else { Issue.record("Expected folder"); return }
        #expect(folder.name == "Inbox")

        let (renameStatus, _) = try await apiRequest(
            "PATCH", "/api/folders/\(id)",
            body: ["name": "Triage", "expanded": false],
            port: server.port
        )
        #expect(renameStatus == 200)
        if case .folder(let updated) = try #require(model.nodeAcrossWorkspaces(id: uuid)) {
            #expect(updated.name == "Triage")
            #expect(!updated.isExpanded)
        } else {
            Issue.record("Expected folder after rename")
        }
    }

    @Test func testLinkRoundTrip() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let wsId = try #require(model.workspaces.first?.id).uuidString

        let (status, createJson) = try await apiRequest(
            "POST", "/api/links",
            body: ["workspace_id": wsId, "url": "https://anthropic.com", "title": "Anthropic"],
            port: server.port
        )
        #expect(status == 200)
        let id = try #require(createJson["id"] as? String)
        let uuid = try #require(UUID(uuidString: id))
        guard case .link(let link) = try #require(model.nodeAcrossWorkspaces(id: uuid)) else {
            Issue.record("Expected link"); return
        }
        #expect(link.url == "https://anthropic.com")
        #expect(link.title == "Anthropic")

        let (patchStatus, _) = try await apiRequest(
            "PATCH", "/api/links/\(id)",
            body: ["title": "Anthropic AI", "url": "https://www.anthropic.com"],
            port: server.port
        )
        #expect(patchStatus == 200)
        if case .link(let updated) = try #require(model.nodeAcrossWorkspaces(id: uuid)) {
            #expect(updated.title == "Anthropic AI")
            #expect(updated.url == "https://www.anthropic.com")
        } else {
            Issue.record("Expected link after patch")
        }
    }

    @Test func testNoteRoundTrip() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let wsId = try #require(model.workspaces.first?.id).uuidString

        let (status, createJson) = try await apiRequest(
            "POST", "/api/notes",
            body: ["workspace_id": wsId, "title": "Plan", "content": "# Hello"],
            port: server.port
        )
        #expect(status == 200)
        let id = try #require(createJson["id"] as? String)
        let uuid = try #require(UUID(uuidString: id))
        #expect(model.noteStorage.read(id: uuid) == "# Hello")

        let (renameStatus, _) = try await apiRequest(
            "PATCH", "/api/notes/\(id)",
            body: ["title": "Renamed"],
            port: server.port
        )
        #expect(renameStatus == 200)
        if case .note(let note) = try #require(model.nodeAcrossWorkspaces(id: uuid)) {
            #expect(note.title == "Renamed")
        } else {
            Issue.record("Expected note after patch")
        }
    }

    @Test func testMoveAcrossWorkspaces() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let sourceWsId = try #require(model.workspaces.first?.id)
        let destWsId = model.createWorkspace(name: "Other", colorId: .moss)

        // Note: createWorkspace also flips selectedWorkspaceId. Re-select source
        // so addLink without explicit workspaceId would still go there if used,
        // but we use the explicit workspaceId variant via the API for safety.
        model.selectWorkspace(id: sourceWsId)

        let (_, createJson) = try await apiRequest(
            "POST", "/api/links",
            body: ["workspace_id": sourceWsId.uuidString, "url": "https://example.com"],
            port: server.port
        )
        let linkId = try #require(createJson["id"] as? String)
        let linkUUID = try #require(UUID(uuidString: linkId))

        let (moveStatus, moveJson) = try await apiRequest(
            "POST", "/api/nodes/\(linkId)/move",
            body: ["to_workspace_id": destWsId.uuidString],
            port: server.port
        )
        #expect(moveStatus == 200)
        #expect(moveJson["ok"] as? Bool == true)

        #expect(model.workspaceId(forNodeId: linkUUID) == destWsId)
    }

    @Test func testDeleteNode() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let wsId = try #require(model.workspaces.first?.id).uuidString

        let (_, createJson) = try await apiRequest(
            "POST", "/api/notes",
            body: ["workspace_id": wsId, "title": "Doomed", "content": "bye"],
            port: server.port
        )
        let id = try #require(createJson["id"] as? String)
        let uuid = try #require(UUID(uuidString: id))
        #expect(model.nodeAcrossWorkspaces(id: uuid) != nil)

        let (status, _) = try await apiRequest(
            "DELETE", "/api/nodes/\(id)",
            port: server.port
        )
        #expect(status == 200)
        #expect(model.nodeAcrossWorkspaces(id: uuid) == nil)
        // The note .md file is cleaned up by deleteNode.
        #expect(model.noteStorage.read(id: uuid) == "")
    }

    @Test func testStateAndTreeEndpoints() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let wsId = try #require(model.workspaces.first?.id).uuidString

        let (stateStatus, stateJson) = try await apiRequest("GET", "/api/state", port: server.port)
        #expect(stateStatus == 200)
        #expect(stateJson["ok"] as? Bool == true)
        #expect(stateJson["state"] != nil)

        let (treeStatus, treeJson) = try await apiRequest("GET", "/api/workspaces/\(wsId)/tree", port: server.port)
        #expect(treeStatus == 200)
        #expect(treeJson["workspace"] != nil)
    }

    @Test func testCurrentWorkspaceReturnsSelected() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let wsId = try #require(model.workspaces.first?.id)
        model.selectWorkspace(id: wsId)

        let (status, json) = try await apiRequest("GET", "/api/workspaces/current", port: server.port)
        #expect(status == 200)
        #expect(json["selected"] as? Bool == true)
        #expect(json["settingsSelected"] as? Bool == false)
        let workspace = try #require(json["workspace"] as? [String: Any])
        #expect(workspace["id"] as? String == wsId.uuidString)
    }

    @Test func testCurrentWorkspaceReportsSettings() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        model.selectSettings()

        let (status, json) = try await apiRequest("GET", "/api/workspaces/current", port: server.port)
        #expect(status == 200)
        #expect(json["selected"] as? Bool == false)
        #expect(json["settingsSelected"] as? Bool == true)
        #expect(json["workspace"] is NSNull)
    }

    @Test func testCreateWorkspaceRejectsUnknownColor() async throws {
        // Bind `model` so NoteServer's weak reference stays alive.
        let (server, model) = try await startServer()
        defer { server.stop() }
        _ = model
        let (status, json) = try await apiRequest(
            "POST", "/api/workspaces",
            body: ["name": "X", "colorId": "puce"],
            port: server.port
        )
        #expect(status == 400)
        #expect(json["code"] as? String == "bad_color")
    }

    @Test func testNoDeleteWorkspaceRoute() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let wsId = try #require(model.workspaces.first?.id).uuidString
        let (status, _) = try await apiRequest(
            "DELETE", "/api/workspaces/\(wsId)",
            port: server.port
        )
        #expect(status == 404)
    }
}
