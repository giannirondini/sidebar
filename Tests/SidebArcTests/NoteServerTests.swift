import Foundation
import Darwin
import JavaScriptCore
import Testing
@testable import SidebArcCore

@MainActor
@Suite struct NoteServerTests {
    private let scratch = TempDir()
    private let testDefaults = TestDefaults()
    private func makeStore() -> DataStore {
        let temp = scratch.url.appendingPathComponent(UUID().uuidString)
        return DataStore(baseDirectory: temp)
    }

    private func startServer(idleTimeout: TimeInterval = NoteServer.defaultIdleTimeout) async throws -> (NoteServer, AppModel) {
        let store = makeStore()
        store.save(DataStore.defaultState())
        let model = AppModel(store: store, defaults: testDefaults.suite)
        let server = try NoteServer(model: model, idleTimeout: idleTimeout)
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
        let script = try String(contentsOf: resources.appendingPathComponent("NoteEditor/auth.js"), encoding: .utf8)
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
            """)

        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("window.location.hash").toString() == "")
        #expect(context.evaluateScript("window.sidebArcAuthToken").toString() == "secret")

        // Reload: no fragment any more, the token comes from the history state.
        context.evaluateScript("window.sidebArcAuthToken = null;")
        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("window.sidebArcAuthToken").toString() == "secret")
        #expect(context.evaluateScript("editor.contenteditable").isUndefined)

        // A tab from an earlier launch (no state): read-only, with a hint.
        context.evaluateScript("window.sidebArcAuthToken = null; window.history.state = null;")
        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("window.sidebArcAuthToken").isNull)
        #expect(context.evaluateScript("editor.contenteditable").toString() == "false")
        #expect(context.evaluateScript("status.textContent").toString().contains("Reopen"))
    }

    @Test func editorSendsOneSaveAtATimeAndFlushesOnPageHide() throws {
        let resources = try #require(NoteServer.resolveBundledResourcesURL())
        let script = try String(contentsOf: resources.appendingPathComponent("NoteEditor/editor.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript("""
            var handlers = {}, calls = [], pending = [];
            var editor = { innerText: "", classList: { toggle: function() {} },
                setAttribute: function() {}, addEventListener: function(k, f) { handlers[k] = f; } };
            Object.defineProperty(editor, "textContent", { set: function(s) { editor.innerText = s; } });
            var generic = { textContent: "", classList: { add: function(){}, remove: function(){} },
                setAttribute: function(){}, addEventListener: function(){} };
            var document = {
                body: { classList: { add: function(){} } },
                getElementById: function(id) { return id === "editor" ? editor : generic; },
                querySelectorAll: function() { return []; }, addEventListener: function(){}
            };
            function TextEncoder() { this.encode = function(s) { return s; }; }
            var window = { location: { search: "?id=123" }, sidebArcAuthToken: "secret", TextEncoder: TextEncoder,
                crypto: { subtle: { digest: function() { return Promise.resolve(new Uint8Array([10, 255]).buffer); } } },
                addEventListener: function(k, f) { handlers[k] = f; } };
            var navigator = { platform: "Mac" };
            function Blob(parts) { this.size = parts[0].length; }
            function URLSearchParams() { this.get = function() { return "123"; }; }
            function setInterval() { return 1; } function clearInterval() {}
            var scheduledSave;
            function setTimeout(f) { scheduledSave = f; return 1; } function clearTimeout() {}
            function fetch(path, options) {
                calls.push(options);
                if (options && options.method === "PUT" && !options.keepalive) {
                    // Held in flight until the test resolves it.
                    return new Promise(function(resolve) { pending.push(resolve); });
                }
                return Promise.resolve({ ok: true, status: 200, json: function() {
                    return Promise.resolve({ content: "original", revision: "rev", title: "Test" });
                } });
            }
            """)
        context.evaluateScript(script)
        #expect(context.exception == nil)
        // A save goes out and stays in flight.
        context.evaluateScript("editor.innerText = 'one'; handlers.input(); scheduledSave();")
        #expect(context.evaluateScript("calls.length").toInt32() == 2)
        #expect(context.evaluateScript("JSON.parse(calls[1].body).revision").toString() == "rev")
        // More typing while it is in flight: no second concurrent PUT.
        context.evaluateScript("editor.innerText = 'two'; handlers.input(); scheduledSave();")
        #expect(context.evaluateScript("calls.length").toInt32() == 2)
        // Closing now: the keepalive PUT follows the in-flight one (its revision is
        // the SHA-256 the in-flight content will have).
        context.evaluateScript("handlers.pagehide();")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("calls.length").toInt32() == 3)
        #expect(context.evaluateScript("calls[2].keepalive").toBool())
        #expect(context.evaluateScript("JSON.parse(calls[2].body).content").toString() == "two")
        #expect(context.evaluateScript("JSON.parse(calls[2].body).revision").toString() == "0aff")
    }

    @Test func editorFlushesPendingEditsWithRevisionOnPageHide() throws {
        let resources = try #require(NoteServer.resolveBundledResourcesURL())
        let script = try String(contentsOf: resources.appendingPathComponent("NoteEditor/editor.js"), encoding: .utf8)
        let context = try #require(JSContext())
        context.evaluateScript("""
            var handlers = {}, calls = [];
            var editor = { innerText: "", classList: { toggle: function() {} },
                setAttribute: function() {}, addEventListener: function(k, f) { handlers[k] = f; } };
            Object.defineProperty(editor, "textContent", { set: function(s) { editor.innerText = s; } });
            var generic = { textContent: "", classList: { add: function(){}, remove: function(){} },
                setAttribute: function(){}, addEventListener: function(){} };
            var document = {
                body: { classList: { add: function(){} } },
                getElementById: function(id) { return id === "editor" ? editor : generic; },
                querySelectorAll: function() { return []; }, addEventListener: function(){}
            };
            var window = { location: { search: "?id=123" }, sidebArcAuthToken: "secret",
                addEventListener: function(k, f) { handlers[k] = f; } };
            var navigator = { platform: "Mac" };
            var crypto = { randomUUID: function() { return "00000000-0000-0000-0000-000000000001"; } };
            function Blob(parts) { this.size = parts[0].length; }
            function URLSearchParams() { this.get = function() { return "123"; }; }
            function setInterval() { return 1; } function clearInterval() {}
            var scheduledSave;
            function setTimeout(f) { scheduledSave = f; return 1; } function clearTimeout() {}
            function fetch(path, options) {
                calls.push(options);
                return Promise.resolve({ ok: true, status: 200, json: function() {
                    return Promise.resolve({ content: "original", revision: "rev", title: "Test" });
                } });
            }
            """)
        context.evaluateScript(script)
        #expect(context.exception == nil)
        context.evaluateScript("editor.innerText = 'edited'; handlers.input(); handlers.pagehide();")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("calls.length").toInt32() == 2)
        #expect(context.evaluateScript("calls[1].keepalive").toBool())
        #expect(context.evaluateScript("JSON.parse(calls[1].body).content").toString() == "edited")
        #expect(context.evaluateScript("JSON.parse(calls[1].body).revision").toString() == "rev")
        context.evaluateScript("editor.innerText = 'a'.repeat(70000); handlers.input(); scheduledSave();")
        #expect(context.exception == nil)
        #expect(!context.evaluateScript("calls[2].keepalive").toBool())
    }

    @Test func cliAcceptsDashContentAndUsesTypedDeletes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("skills/sidebarc/scripts/sidebarc.js"), encoding: .utf8)
        let script = source.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
        let context = try #require(JSContext())
        context.evaluateScript("""
            var stderr = "";
            var process = { argv: ["node", "cli", "help"], stdout: { write: function(){} },
                stderr: { write: function(s){ stderr = s; } }, exit: function(){ throw new Error("exit"); } };
            function require(name) {
                if (name === "fs") return { readFileSync: function() {
                    return JSON.stringify({ host: "127.0.0.1", port: 1234, token: "a".repeat(64) });
                } };
                if (name === "os") return { homedir: function() { return "/tmp"; } };
                return { join: function() { return "/tmp/endpoint"; } };
            }
            var requestedURL = "";
            function fetch(url) {
                requestedURL = url;
                return Promise.resolve({ ok: true, text: function() { return Promise.resolve('{"ok":true}'); } });
            }
            """)
        context.evaluateScript(script)
        #expect(context.exception == nil)
        #expect(context.evaluateScript("parseArgs(['--content', '---']).flags.content").toString() == "---")
        context.evaluateScript("COMMANDS['links:delete']({ positional: ['id'], flags: {} });")
        #expect(context.exception == nil)
        #expect(context.evaluateScript("requestedURL").toString().hasSuffix("/api/nodes/id?type=link"))
        context.evaluateScript("""
            fetch = function() { return Promise.reject({ message: "offline", cause: { code: "ECONNREFUSED" } }); };
            request("GET", "/api/state").catch(function() {});
            """)
        #expect(context.evaluateScript("JSON.parse(stderr).code").toString() == "app_not_running")
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

    @Test func editorFilesArePublicButTheAPIIsNot() async throws {
        let (server, _) = try await startServer()
        defer { server.stop() }

        // Every response carries `nosniff`, so a wrong type would block the file.
        for (path, type) in [
            ("/editor/editor.css", "text/css"),
            ("/editor/auth.js", "application/javascript"),
            ("/editor/editor.js", "application/javascript"),
            ("/editor/vendor/marked.min.js", "application/javascript"),
            ("/editor/vendor/purify.min.js", "application/javascript")
        ] {
            let url = try #require(URL(string: "http://127.0.0.1:\(server.port)\(path)"))
            let (body, response) = try await URLSession.shared.data(from: url)
            let http = try #require(response as? HTTPURLResponse)
            #expect(http.statusCode == 200, "\(path)")
            #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix(type) == true, "\(path)")
            #expect(http.value(forHTTPHeaderField: "X-Content-Type-Options") == "nosniff")
            #expect(!body.isEmpty)
        }
        let (apiStatus, _) = try await request(method: "GET", path: "/api/state", includeAuthorization: false, server: server)
        #expect(apiStatus == 401)
    }

    @Test func editorPageAllowsOnlyBundledScriptsAndStyles() async throws {
        let (server, _) = try await startServer()
        defer { server.stop() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/?id=\(UUID().uuidString)"))
        let (data, response) = try await URLSession.shared.data(from: url)
        let http = try #require(response as? HTTPURLResponse)
        let policy = try #require(http.value(forHTTPHeaderField: "Content-Security-Policy"))
        #expect(policy == NoteServer.editorContentSecurityPolicy)
        #expect(policy.contains("frame-ancestors 'none'"))
        #expect(policy.contains("script-src 'self';"))
        #expect(policy.contains("style-src 'self';"))
        #expect(!policy.contains("blob:"))
        #expect(!policy.contains("unsafe"))
        // The CSP blocks inline code, so the page must have none.
        let html = String(decoding: data, as: UTF8.self)
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<style"))
        #expect(!html.contains(" style="))
        #expect(!html.contains(" on"))
    }

    @Test func tokenComparisonIsExact() {
        #expect(NoteServer.constantTimeEquals("Bearer abc", "Bearer abc"))
        #expect(!NoteServer.constantTimeEquals("Bearer abd", "Bearer abc"))
        #expect(!NoteServer.constantTimeEquals("Bearer ab", "Bearer abc"))
        #expect(!NoteServer.constantTimeEquals("Bearer abc\0", "Bearer abc"))
        #expect(!NoteServer.constantTimeEquals("", "Bearer abc"))
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
        // (This used to expect "# Untitled" through a no-op #expect: new notes
        // start empty, so check a real body instead.)
        let noteId = model.addNote(title: "Server Test", parentId: nil, content: "# Heading\n\nBody")

        let (status, body) = try await request(
            method: "GET",
            path: "/api/notes/\(noteId.uuidString)",
            server: server
        )
        #expect(status == 200)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["title"] as? String == "Server Test")
        let content = try #require(json?["content"] as? String)
        #expect(content == "# Heading\n\nBody")

        let emptyId = model.addNote(title: "Empty", parentId: nil)
        let (_, emptyBody) = try await request(method: "GET", path: "/api/notes/\(emptyId.uuidString)", server: server)
        let emptyJSON = try #require(try JSONSerialization.jsonObject(with: emptyBody) as? [String: Any])
        #expect(emptyJSON["content"] as? String == "")
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

    @Test func moveValidationAndTypedDeletionPreserveNodes() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let workspace = model.currentWorkspace.id
        let folder = model.addFolder(name: "Folder", parentId: nil)
        let child = model.addLink(urlString: "https://example.com", title: "Child", parentId: folder)
        let second = model.addLink(urlString: "https://example.org", title: "Second", parentId: folder)
        let childPath = "/api/nodes/\(child.uuidString)"
        let (reorder, _) = try await apiRequest("POST", "\(childPath)/move", body: ["index": 2], server: server)
        #expect(reorder == 200)
        #expect(model.location(of: child, in: workspace)?.parentId == folder)
        #expect(model.location(of: second, in: workspace)?.index == 0)
        let (badId, badIdBody) = try await apiRequest("POST", "\(childPath)/move", body: ["to_parent_id": "typo"], server: server)
        #expect(badId == 400)
        #expect(badIdBody["code"] as? String == "bad_id")
        let (cycle, _) = try await apiRequest("POST", "/api/nodes/\(folder.uuidString)/move", body: ["to_parent_id": folder.uuidString], server: server)
        #expect(cycle == 409)
        let (wrongType, _) = try await apiRequest("DELETE", "/api/nodes/\(folder.uuidString)?type=link", server: server)
        #expect(wrongType == 409)
        #expect(model.nodeAcrossWorkspaces(id: child) != nil)
        let (badParent, _) = try await apiRequest("POST", "/api/notes", body: ["workspace_id": workspace.uuidString, "title": "Bad", "parent_id": "typo"], server: server)
        #expect(badParent == 400)
        let (badPatch, _) = try await apiRequest("PATCH", "/api/folders/\(folder.uuidString)", body: ["nam": "Changed"], server: server)
        #expect(badPatch == 400)
    }

    @Test func noteRevisionsRejectStaleWrites() async throws {
        let (server, model) = try await startServer()
        defer { server.stop() }
        let note = model.addNote(title: "Note", parentId: nil, content: "original")
        let path = "/api/notes/\(note.uuidString)"
        let (_, initial) = try await apiRequest("GET", path, server: server)
        let base = try #require(initial["revision"] as? String)

        // Based on the current revision: accepted; the response names the new one.
        let (first, firstJSON) = try await apiRequest("PUT", path, body: ["content": "first", "revision": base], server: server)
        #expect(first == 200)
        let next = try #require(firstJSON["revision"] as? String)
        #expect(next != base)
        // The editor's next save follows with that revision.
        let (second, _) = try await apiRequest("PUT", path, body: ["content": "second", "revision": next], server: server)
        #expect(second == 200)
        // An old base (another tab, or a late request): refused, text kept.
        let (stale, staleJSON) = try await apiRequest("PUT", path, body: ["content": "stale", "revision": base], server: server)
        #expect(stale == 409)
        #expect(staleJSON["code"] as? String == "note_conflict")
        #expect(model.noteStorage.read(id: note) == "second")
        // Without a revision (agent CLI): unconditional.
        let (agent, _) = try await apiRequest("PUT", path, body: ["content": "agent edit"], server: server)
        #expect(agent == 200)
        #expect(model.noteStorage.read(id: note) == "agent edit")
        let (badRevision, _) = try await apiRequest("PUT", path, body: ["content": "x", "revision": 3], server: server)
        #expect(badRevision == 400)
        let (bad, badJSON) = try await apiRequest("GET", "/api/notes/not-a-uuid", server: server)
        #expect(bad == 400)
        #expect(badJSON["code"] as? String == "bad_id")
    }

    @Test func rawRequestsRejectMalformedAndOversizedInput() async throws {
        let (server, _) = try await startServer()
        defer { server.stop() }
        let port = server.port
        for (request, expected) in [
            ("BAD\r\n\r\n", "400"),
            ("POST / HTTP/1.1\r\nContent-Length: nope\r\n\r\n", "400"),
            ("POST / HTTP/1.1\r\nContent-Length: 8388609\r\n\r\n", "413"),
            ("GET / HTTP/1.1\r\nX-Long: " + String(repeating: "a", count: 16384) + "\r\n\r\n", "413")
        ] {
            let response = try await Task.detached {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                defer { close(fd) }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }

                }
                guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
                let bytes = Array(request.utf8)
                let sent = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
                guard sent == bytes.count else { throw POSIXError(.EIO) }
                var buffer = [UInt8](repeating: 0, count: 512)
                let count = recv(fd, &buffer, buffer.count, 0)
                guard count > 0 else { throw POSIXError(.EIO) }
                return String(decoding: buffer.prefix(count), as: UTF8.self)
            }.value
            #expect(response.hasPrefix("HTTP/1.1 \(expected)"))
        }
    }

    @Test func idleConnectionsAreLimitedAndReleased() async throws {
        let (server, model) = try await startServer(idleTimeout: 1)
        defer { server.stop() }
        let port = server.port
        let sockets = try await Task.detached {
            var sockets: [Int32] = []
            do {
                for _ in 0..<32 {
                    let fd = socket(AF_INET, SOCK_STREAM, 0)
                    guard fd >= 0 else { throw POSIXError(.EIO) }
                    sockets.append(fd)
                    var address = sockaddr_in()
                    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = port.bigEndian
                    address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
                    let result = withUnsafePointer(to: &address) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                    guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
                }
                return sockets
            } catch {
                sockets.forEach { close($0) }
                throw error
            }
        }.value
        defer { sockets.forEach { close($0) } }
        // Poll instead of fixed sleeps: under a loaded parallel run a fixed 0.5 s
        // could land after the 1 s idle timeout had already freed the slots.
        let clock = ContinuousClock()
        func status(becoming wanted: Int, within limit: Duration) async throws -> Int {
            let deadline = clock.now + limit
            while true {
                let (status, _) = try await request(method: "GET", path: "/api/state", server: server)
                if status == wanted || clock.now >= deadline { return status }
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        // Full while the 32 idle connections are held (well inside the timeout)…
        #expect(try await status(becoming: 503, within: .milliseconds(700)) == 503)
        // …and available again once the idle timeout has released them.
        #expect(try await status(becoming: 200, within: .seconds(5)) == 200)
        #expect(!model.workspaces.isEmpty)
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
            body: ["url": "javascript:alert(1)"],
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
