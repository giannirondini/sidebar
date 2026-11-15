import Foundation
import JavaScriptCore
import Testing
@testable import SidebArcCore

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
        let server = try NoteServer(model: model)
        server.start()

        // Wait briefly for the listener to enter .ready
        for _ in 0..<50 {
            if server.port > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(server.port > 0, "Server did not bind to a port")
        return (server, model)
    }

    private func request(
        method: String,
        path: String,
        host: String? = nil,
        body: Data? = nil,
        authorization: String? = nil,
        includeAuthorization: Bool = true,
        origin: String? = nil,
        contentType: String? = nil,
        server: NoteServer
    ) async throws -> (status: Int, body: Data) {
        var url = URLComponents()
        url.scheme = "http"
        url.host = "127.0.0.1"
        url.port = Int(server.port)
        url.path = path.components(separatedBy: "?").first ?? path
        if let q = path.components(separatedBy: "?").dropFirst().first {
            url.percentEncodedQuery = q
        }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        if includeAuthorization {
            request.setValue(authorization ?? "Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        }
        if let host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        return (httpResponse.statusCode, data)
    }

    @Test func testServerStartsOnEphemeralPort() async throws {
        let (server, _) = try await startServer()
        defer { server.stop() }
        #expect(server.port > 0)
        #expect(server.token.count == 64)
        #expect(server.token.allSatisfy { $0.isHexDigit })
        #expect(server.editorURL(noteId: UUID())?.fragment == "token=\(server.token)")
    }

    @Test func testEditorTokenSurvivesReloadWithoutRemainingInURL() throws {
        let resources = try #require(NoteServer.resolveBundledResourcesURL())
        let html = try String(contentsOf: resources.appendingPathComponent("NoteEditor/index.html"), encoding: .utf8)
        let script = try #require(html.components(separatedBy: "<script>").dropFirst().first?
            .components(separatedBy: "</script>").first)
        let context = try #require(JSContext())
        context.evaluateScript("""
            var status = { textContent: "" };
            var editor = { setAttribute: function (name, value) { this[name] = value; } };
            var window = {
              location: { hash: "#token=secret", pathname: "/", search: "?id=123" },
              history: {
                state: null,
                replaceState: function (state) { this.state = state; window.location.hash = ""; }
              }
            };
            var document = { getElementById: function (id) { return id === "status" ? status : editor; } };
            function URLSearchParams(value) {
              this.get = function () { return value.startsWith("token=") ? value.slice(6) : null; };
            }
            var authorization;
            function fetch(path, options) {
              authorization = options.headers.Authorization;
              return new Promise(function () {});
            }
            """)

        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("window.location.hash").toString() == "")
        #expect(context.evaluateScript("authorization").toString() == "Bearer secret")

        context.evaluateScript("authorization = null; window.sidebArcAuthToken = null;")
        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("authorization").toString() == "Bearer secret")
        #expect(context.evaluateScript("editor.contenteditable").isUndefined)

        context.evaluateScript("authorization = null; window.history.state = null;")
        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("authorization").isNull)
        #expect(context.evaluateScript("editor.contenteditable").toString() == "false")
    }

    @Test func testAPIRoutesRequireBearerToken() async throws {
        let (server, _) = try await startServer()
        defer { server.stop() }

        let (missingStatus, _) = try await request(
            method: "GET",
            path: "/api/state",
            includeAuthorization: false,
            server: server
        )
        #expect(missingStatus == 401)

        let (invalidStatus, _) = try await request(
            method: "GET",
            path: "/api/state",
            authorization: "Bearer invalid",
            server: server
        )
        #expect(invalidStatus == 401)
    }

    @Test func testCrossOriginRequestsAreRejectedButEditorOriginIsAllowed() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }

        let (crossOriginStatus, _) = try await request(
            method: "GET",
            path: "/api/state",
            origin: "https://example.com",
            server: server
        )
        #expect(crossOriginStatus == 403)

        let (sameOriginStatus, _) = try await request(
            method: "GET",
            path: "/api/state",
            origin: "http://127.0.0.1:\(server.port)",
            server: server
        )
        #expect(sameOriginStatus == 200)
        #expect(!model.workspaces.isEmpty)
    }

    @Test func testAPIWriteRequiresJSONContentType() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let initialCount = model.workspaces.count
        let body = try JSONSerialization.data(withJSONObject: ["name": "Blocked"])

        let (status, _) = try await request(
            method: "POST",
            path: "/api/workspaces",
            body: body,
            contentType: "text/plain",
            server: server
        )
        #expect(status == 415)
        #expect(model.workspaces.count == initialCount)
    }

    @Test func testEditorAssetsRequireBearerToken() async throws {
        let (server, _) = try await startServer()
        defer { server.stop() }

        let (unauthorizedStatus, _) = try await request(
            method: "GET",
            path: "/editor/editor.css",
            includeAuthorization: false,
            server: server
        )
        #expect(unauthorizedStatus == 401)

        let (authorizedStatus, body) = try await request(
            method: "GET",
            path: "/editor/editor.css",
            server: server
        )
        #expect(authorizedStatus == 200)
        #expect(!body.isEmpty)
    }

    @Test func testAgentEndpointFileIsOwnerOnly() throws {
        let store = makeStore()
        let endpoint = store.agentEndpointFileURL()
        let data = Data(#"{"token":"test"}"#.utf8)

        try store.writeAgentEndpoint(data)

        let attributes = try FileManager.default.attributesOfItem(atPath: endpoint.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try Data(contentsOf: endpoint) == data)
    }

    @Test func testGetReturnsNoteJSON() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let noteId = model.addNote(title: "Server Test", parentId: nil)

        let (status, body) = try await request(
            method: "GET",
            path: "/api/notes/\(noteId.uuidString)",
            server: server
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
            server: server
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
            server: server
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
            server: server
        )
        #expect(status == 200)
        #expect(model.noteStorage.read(id: noteId) == "## Updated")
    }

    // MARK: - Agent API round-trips

    private func apiRequest(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil,
        server: NoteServer
    ) async throws -> (status: Int, json: [String: Any]) {
        let data = body.map { try? JSONSerialization.data(withJSONObject: $0) } ?? nil
        let (status, raw) = try await request(method: method, path: path, body: data ?? nil, server: server)
        let parsed = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
        return (status, parsed)
    }

    @Test func testWorkspaceRoundTrip() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }

        let (createStatus, createJson) = try await apiRequest(
            "POST", "/api/workspaces",
            body: ["name": "Reading", "colorId": "leaf"],
            server: server
        )
        #expect(createStatus == 200)
        #expect(createJson["ok"] as? Bool == true)
        let id = try #require(createJson["id"] as? String)
        let uuid = try #require(UUID(uuidString: id))
        #expect(model.workspaces.contains(where: { $0.id == uuid }))

        let (renameStatus, _) = try await apiRequest(
            "PATCH", "/api/workspaces/\(id)",
            body: ["name": "Reading List"],
            server: server
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
            server: server
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
            server: server
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
            server: server
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
            server: server
        )
        #expect(patchStatus == 200)
        if case .link(let updated) = try #require(model.nodeAcrossWorkspaces(id: uuid)) {
            #expect(updated.title == "Anthropic AI")
            #expect(updated.url == "https://www.anthropic.com")
        } else {
            Issue.record("Expected link after patch")
        }
    }

    @Test func testPatchLinkURLInAnotherWorkspace() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let id = model.addLink(urlString: "https://old.example", title: "Link", parentId: nil)
        _ = model.createWorkspace(name: "Other", colorId: .moss)

        let (status, json) = try await apiRequest(
            "PATCH", "/api/links/\(id.uuidString)",
            body: ["url": "  https://new.example  "],
            server: server
        )
        #expect(status == 200)
        #expect(json["ok"] as? Bool == true)
        guard case .link(let link) = model.nodeAcrossWorkspaces(id: id) else {
            Issue.record("Expected link in the original space")
            return
        }
        #expect(link.url == "https://new.example")
    }

    @Test func testNoteRoundTrip() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let wsId = try #require(model.workspaces.first?.id).uuidString

        let (status, createJson) = try await apiRequest(
            "POST", "/api/notes",
            body: ["workspace_id": wsId, "title": "Plan", "content": "# Hello"],
            server: server
        )
        #expect(status == 200)
        let id = try #require(createJson["id"] as? String)
        let uuid = try #require(UUID(uuidString: id))
        #expect(model.noteStorage.read(id: uuid) == "# Hello")

        let (renameStatus, _) = try await apiRequest(
            "PATCH", "/api/notes/\(id)",
            body: ["title": "Renamed"],
            server: server
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
            server: server
        )
        let linkId = try #require(createJson["id"] as? String)
        let linkUUID = try #require(UUID(uuidString: linkId))

        let (moveStatus, moveJson) = try await apiRequest(
            "POST", "/api/nodes/\(linkId)/move",
            body: ["to_workspace_id": destWsId.uuidString],
            server: server
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
            server: server
        )
        let id = try #require(createJson["id"] as? String)
        let uuid = try #require(UUID(uuidString: id))
        #expect(model.nodeAcrossWorkspaces(id: uuid) != nil)

        let (status, _) = try await apiRequest(
            "DELETE", "/api/nodes/\(id)",
            server: server
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

        let (stateStatus, stateJson) = try await apiRequest("GET", "/api/state", server: server)
        #expect(stateStatus == 200)
        #expect(stateJson["ok"] as? Bool == true)
        #expect(stateJson["state"] != nil)

        let (treeStatus, treeJson) = try await apiRequest("GET", "/api/workspaces/\(wsId)/tree", server: server)
        #expect(treeStatus == 200)
        #expect(treeJson["workspace"] != nil)
    }

    @Test func testCurrentWorkspaceReturnsSelected() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let wsId = try #require(model.workspaces.first?.id)
        model.selectWorkspace(id: wsId)

        let (status, json) = try await apiRequest("GET", "/api/workspaces/current", server: server)
        #expect(status == 200)
        #expect(json["selected"] as? Bool == true)
        #expect(json["settingsSelected"] as? Bool == false)
        let workspace = try #require(json["workspace"] as? [String: Any])
        #expect(workspace["id"] as? String == wsId.uuidString)
    }

    @Test func testCurrentWorkspaceReportsSettings() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        model.showSettings()

        let (status, json) = try await apiRequest("GET", "/api/workspaces/current", server: server)
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
            server: server
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
            server: server
        )
        #expect(status == 404)
    }

    // MARK: - Profiles and favorites (agent API v2)

    @Test func testWorkspacePayloadsIncludeProfileId() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let workspace = try #require(model.workspaces.first)
        model.selectWorkspace(id: workspace.id)

        let (_, listJson) = try await apiRequest("GET", "/api/workspaces", server: server)
        let list = try #require(listJson["workspaces"] as? [[String: Any]])
        #expect(list.first?["profileId"] as? String == workspace.profileId.uuidString)

        let (_, currentJson) = try await apiRequest("GET", "/api/workspaces/current", server: server)
        let current = try #require(currentJson["workspace"] as? [String: Any])
        #expect(current["profileId"] as? String == workspace.profileId.uuidString)
    }

    @Test func testProfileCreatePatchListAndAssign() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }

        let (createStatus, createJson) = try await apiRequest("POST", "/api/profiles", body: ["name": "Work"], server: server)
        #expect(createStatus == 200)
        let profileId = try #require((createJson["id"] as? String).flatMap { UUID(uuidString: $0) })

        let (patchStatus, _) = try await apiRequest(
            "PATCH", "/api/profiles/\(profileId.uuidString)",
            body: ["name": "Job", "browser_bundle_id": "org.mozilla.firefox"],
            server: server
        )
        #expect(patchStatus == 200)
        #expect(model.profile(id: profileId)?.name == "Job")
        #expect(model.profile(id: profileId)?.browserBundleId == "org.mozilla.firefox")

        _ = try await apiRequest("PATCH", "/api/profiles/\(profileId.uuidString)", body: ["browser_bundle_id": NSNull()], server: server)
        #expect(model.profile(id: profileId)?.browserBundleId == nil)

        // Create a workspace directly in the profile, and move an existing one there.
        let (_, wsJson) = try await apiRequest(
            "POST", "/api/workspaces", body: ["name": "Office", "profile_id": profileId.uuidString], server: server
        )
        let officeId = try #require((wsJson["id"] as? String).flatMap { UUID(uuidString: $0) })
        #expect(model.workspaces.first(where: { $0.id == officeId })?.profileId == profileId)

        let inbox = try #require(model.workspaces.first(where: { $0.id != officeId }))
        _ = try await apiRequest("PATCH", "/api/workspaces/\(inbox.id.uuidString)", body: ["profile_id": profileId.uuidString], server: server)
        #expect(model.workspaces.first(where: { $0.id == inbox.id })?.profileId == profileId)

        let (_, listJson) = try await apiRequest("GET", "/api/profiles", server: server)
        let profiles = try #require(listJson["profiles"] as? [[String: Any]])
        let job = try #require(profiles.first(where: { $0["id"] as? String == profileId.uuidString }))
        #expect(Set(job["workspaceIds"] as? [String] ?? []) == [officeId.uuidString, inbox.id.uuidString])
        #expect(job["browserBundleId"] is NSNull)
    }

    @Test func testUnknownProfileIsRejected() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let wsId = try #require(model.workspaces.first?.id).uuidString
        let bogus = UUID().uuidString

        let (patchStatus, patchJson) = try await apiRequest("PATCH", "/api/workspaces/\(wsId)", body: ["profile_id": bogus], server: server)
        #expect(patchStatus == 404)
        #expect(patchJson["code"] as? String == "profile_not_found")

        let (createStatus, _) = try await apiRequest("POST", "/api/workspaces", body: ["name": "X", "profile_id": bogus], server: server)
        #expect(createStatus == 404)
        #expect(model.workspaces.count == 1)
    }

    @Test func testNoDeleteProfileRoute() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let profileId = model.currentProfile.id.uuidString
        let (status, _) = try await apiRequest("DELETE", "/api/profiles/\(profileId)", server: server)
        #expect(status == 404)
        #expect(model.profiles.count == 1)
    }

    @Test func testFavoritesAddMoveUnpinDelete() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let profileId = model.currentProfile.id.uuidString
        let wsId = model.currentWorkspace.id

        var ids: [String] = []
        for url in ["https://a.com", "https://b.com", "https://c.com"] {
            let (status, json) = try await apiRequest("POST", "/api/profiles/\(profileId)/favorites", body: ["url": url], server: server)
            #expect(status == 200)
            ids.append(try #require(json["id"] as? String))
        }
        #expect(model.currentProfile.favorites.map(\.title) == ["a.com", "b.com", "c.com"])

        let (dupStatus, dupJson) = try await apiRequest("POST", "/api/profiles/\(profileId)/favorites", body: ["url": "https://A.com/"], server: server)
        #expect(dupStatus == 409)
        #expect(dupJson["code"] as? String == "duplicate_favorite")

        let (moveStatus, _) = try await apiRequest("POST", "/api/favorites/\(ids[2])/move", body: ["index": 0], server: server)
        #expect(moveStatus == 200)
        #expect(model.currentProfile.favorites.map(\.title) == ["c.com", "a.com", "b.com"])

        let (unpinStatus, _) = try await apiRequest("POST", "/api/favorites/\(ids[0])/unpin", body: ["workspace_id": wsId.uuidString], server: server)
        #expect(unpinStatus == 200)
        #expect(model.currentProfile.favorites.map(\.title) == ["c.com", "b.com"])
        #expect(model.currentWorkspace.items.map(\.id.uuidString) == [ids[0]])

        let (deleteStatus, _) = try await apiRequest("DELETE", "/api/favorites/\(ids[1])", server: server)
        #expect(deleteStatus == 200)
        #expect(model.currentProfile.favorites.map(\.title) == ["c.com"])

        let (missingStatus, missingJson) = try await apiRequest("DELETE", "/api/favorites/\(ids[1])", server: server)
        #expect(missingStatus == 404)
        #expect(missingJson["code"] as? String == "favorite_not_found")
    }

    @Test func testFavoritesFullReturnsConflict() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let profileId = model.currentProfile.id
        for i in 0..<Profile.maxFavorites {
            _ = model.addFavorite(profileId: profileId, urlString: "https://f\(i).com", title: "F\(i)")
        }
        let (status, json) = try await apiRequest("POST", "/api/profiles/\(profileId.uuidString)/favorites", body: ["url": "https://late.com"], server: server)
        #expect(status == 409)
        #expect(json["code"] as? String == "favorites_full")
    }

    @Test func testLinkBrowserOverrideViaPatch() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let linkId = model.addLink(urlString: "https://x.com", title: "X", parentId: nil)

        _ = try await apiRequest("PATCH", "/api/links/\(linkId.uuidString)", body: ["browser_bundle_id": "com.apple.Safari"], server: server)
        guard case .link(let overridden) = model.nodeById(linkId) else {
            Issue.record("Expected link")
            return
        }
        #expect(overridden.browserBundleId == "com.apple.Safari")

        _ = try await apiRequest("PATCH", "/api/links/\(linkId.uuidString)", body: ["browser_bundle_id": NSNull()], server: server)
        guard case .link(let cleared) = model.nodeById(linkId) else {
            Issue.record("Expected link")
            return
        }
        #expect(cleared.browserBundleId == nil)
    }

    @Test func testLinkAndFavoriteURLsRejectUnsupportedSchemes() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let workspaceId = model.currentWorkspace.id
        let profileId = model.currentProfile.id

        let (createStatus, createJson) = try await apiRequest(
            "POST",
            "/api/links",
            body: ["workspace_id": workspaceId.uuidString, "url": "--renderer-cmd-prefix=/tmp/x"],
            server: server
        )
        #expect(createStatus == 400)
        #expect(createJson["code"] as? String == "bad_url")

        let (favoriteStatus, favoriteJson) = try await apiRequest(
            "POST",
            "/api/profiles/\(profileId.uuidString)/favorites",
            body: ["url": "file:///tmp/run.command"],
            server: server
        )
        #expect(favoriteStatus == 400)
        #expect(favoriteJson["code"] as? String == "bad_url")
        #expect(model.currentProfile.favorites.isEmpty)
    }

    @Test func testPatchRejectsInvalidURLsAndNonBrowserOverridesAtomically() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let linkId = model.addLink(urlString: "https://safe.example", title: "Safe", parentId: nil)

        let (urlStatus, urlJson) = try await apiRequest(
            "PATCH",
            "/api/links/\(linkId.uuidString)",
            body: ["title": "Changed", "url": "--remote-debugging-port=9222"],
            server: server
        )
        #expect(urlStatus == 400)
        #expect(urlJson["code"] as? String == "bad_url")
        guard case .link(let unchanged) = model.nodeById(linkId) else {
            Issue.record("Expected link")
            return
        }
        #expect(unchanged.title == "Safe")
        #expect(unchanged.url == "https://safe.example")

        let profileId = model.currentProfile.id
        let originalName = model.currentProfile.name
        let (browserStatus, browserJson) = try await apiRequest(
            "PATCH",
            "/api/profiles/\(profileId.uuidString)",
            body: ["name": "Changed", "browser_bundle_id": "com.apple.Terminal"],
            server: server
        )
        #expect(browserStatus == 400)
        #expect(browserJson["code"] as? String == "bad_browser")
        #expect(model.currentProfile.name == originalName)
        #expect(model.currentProfile.browserBundleId == nil)

        let (linkBrowserStatus, linkBrowserJson) = try await apiRequest(
            "PATCH",
            "/api/links/\(linkId.uuidString)",
            body: ["browser_bundle_id": "com.apple.Terminal"],
            server: server
        )
        #expect(linkBrowserStatus == 400)
        #expect(linkBrowserJson["code"] as? String == "bad_browser")
    }
}
