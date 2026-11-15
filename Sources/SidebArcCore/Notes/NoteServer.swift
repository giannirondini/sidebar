import Foundation
import CryptoKit
import Network
import os
import Security

/// Minimal loopback-only HTTP server that backs the bundled markdown note editor.
///
/// Binds to 127.0.0.1 on a system-assigned ephemeral port and rejects requests
/// whose Host header doesn't match 127.0.0.1:<port> (DNS rebinding defense).
@MainActor
final class NoteServer {
    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "noteserver")
    private weak var model: AppModel?
    private let noteStorage: NoteStorage
    private let resourcesURL: URL?

    let token: String
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private struct NoteWrite {
        let client: String
        let sequence: Int
        let bases: [String]
        let result: String
    }
    private var noteWrites: [UUID: NoteWrite] = [:]

    init(model: AppModel, resourcesURL: URL? = NoteServer.resolveBundledResourcesURL()) throws {
        self.model = model
        self.noteStorage = model.noteStorage
        self.resourcesURL = resourcesURL
        self.token = try Self.generateToken()
        if resourcesURL == nil {
            logger.error("NoteServer could not locate bundled editor resources; note editor will be unavailable")
        }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            let newListener = try NWListener(using: parameters)

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.handleConnection(connection)
                }
            }

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let p = newListener.port {
                        MainActor.assumeIsolated {
                            self.port = p.rawValue
                            self.logger.debug("NoteServer ready on 127.0.0.1:\(p.rawValue, privacy: .public)")
                        }
                    }
                case .failed(let error):
                    self.logger.error("NoteServer failed: \(String(describing: error), privacy: .public)")
                default:
                    break
                }
            }

            newListener.start(queue: .main)
            self.listener = newListener
        } catch {
            logger.error("NoteServer start failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        port = 0
    }

    func editorURL(noteId: UUID) -> URL? {
        guard port > 0 else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "id", value: noteId.uuidString)]
        components.fragment = "token=\(token)"
        return components.url
    }

    // MARK: - Connection handling

    private static let maxHeaderBytes = 16 * 1024
    private static let maxBodyBytes = 8 * 1024 * 1024
    private static let idleTimeout: TimeInterval = 15
    private static let maxConnections = 32
    private var connections: [UUID: NWConnection] = [:]

    @MainActor
    private final class ConnectionState {
        let connection: NWConnection
        var buffer = Data()
        var timeout: DispatchWorkItem?

        init(_ connection: NWConnection) {
            self.connection = connection
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        guard connections.count < Self.maxConnections else {
            sendStatus(503, message: "Too Many Connections", on: connection)
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                MainActor.assumeIsolated { _ = self?.connections.removeValue(forKey: id) }
            } else if case .failed = state {
                MainActor.assumeIsolated { _ = self?.connections.removeValue(forKey: id) }
            }
        }
        receive(ConnectionState(connection))
    }

    private func receive(_ state: ConnectionState) {
        state.timeout?.cancel()
        let connection = state.connection
        let timeout = DispatchWorkItem { connection.cancel() }
        state.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTimeout, execute: timeout)
        state.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            MainActor.assumeIsolated {
                state.timeout?.cancel()
                if let data, !data.isEmpty {
                    state.buffer.append(data)
                }
                switch self.tryParseRequest(buffer: state.buffer) {
                case .request(let request):
                    self.respond(to: request, on: state.connection)
                    return
                case .invalid(let status):
                    self.sendStatus(status, message: status == 413 ? "Payload Too Large" : "Bad Request", on: state.connection)
                    return
                case .incomplete:
                    break
                }
                if isComplete || error != nil {
                    state.connection.cancel()
                    return
                }
                self.receive(state)
            }
        }
    }

    // MARK: - HTTP parsing

    private struct ParsedRequest {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    private enum ParseResult {
        case incomplete
        case invalid(Int)
        case request(ParsedRequest)
    }

    private func tryParseRequest(buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > Self.maxHeaderBytes ? .invalid(413) : .incomplete
        }
        guard headerEnd.upperBound <= Self.maxHeaderBytes else { return .invalid(413) }
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .invalid(400) }

        var lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid(400) }
        let requestLine = lines.removeFirst()
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .invalid(400) }
        let method = parts[0]
        let target = parts[1]

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { return .invalid(400) }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard headers[name] == nil else { return .invalid(400) }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { return .invalid(400) }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }) else { return .invalid(400) }
        guard let contentLength = Int(rawLength), contentLength <= Self.maxBodyBytes else { return .invalid(413) }
        let bodyStart = headerEnd.upperBound
        let bodyAvailable = buffer.count - bodyStart
        if bodyAvailable < contentLength {
            return .incomplete
        }

        let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))

        let (path, query) = Self.splitTarget(target)
        return .request(ParsedRequest(method: method, path: path, query: query, headers: headers, body: body))
    }

    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        guard let qIndex = target.firstIndex(of: "?") else {
            return (target, [:])
        }
        let path = String(target[..<qIndex])
        let queryString = String(target[target.index(after: qIndex)...])
        var dict: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts.first?.removingPercentEncoding ?? ""
            let value = (parts.count > 1 ? parts[1] : "").removingPercentEncoding ?? ""
            if !key.isEmpty {
                dict[key] = value
            }
        }
        return (path, dict)
    }

    // MARK: - Routing

    private func respond(to request: ParsedRequest, on connection: NWConnection) {
        // Host header check
        let expectedHost = "127.0.0.1:\(port)"
        let host = request.headers["host"] ?? ""
        if host != expectedHost {
            sendStatus(400, message: "Bad Host", on: connection)
            return
        }

        let expectedOrigin = "http://\(expectedHost)"
        // The editor's authenticated PUTs carry this same-origin header.
        if let origin = request.headers["origin"], origin != expectedOrigin {
            if request.path.hasPrefix("/api/") {
                sendError(status: 403, code: "origin_not_allowed", message: "Cross-origin requests are not allowed", on: connection)
            } else {
                sendStatus(403, message: "Origin Not Allowed", on: connection)
            }
            return
        }

        let requiresToken = request.path.hasPrefix("/api/") || request.path.hasPrefix("/editor/")
        if requiresToken && request.headers["authorization"] != "Bearer \(token)" {
            if request.path.hasPrefix("/api/") {
                sendError(status: 401, code: "unauthorized", message: "A valid bearer token is required", on: connection)
            } else {
                sendStatus(401, message: "Unauthorized", on: connection)
            }
            return
        }

        if request.path.hasPrefix("/api/"), ["POST", "PATCH", "PUT"].contains(request.method) {
            let mediaType = request.headers["content-type"]?
                .split(separator: ";", maxSplits: 1)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard mediaType == "application/json" else {
                sendError(status: 415, code: "unsupported_media_type", message: "Content-Type must be application/json", on: connection)
                return
            }
        }
        if request.method == "PATCH", !validatePatch(request, on: connection) { return }

        if request.method == "GET" && request.path == "/favicon.ico" {
            sendResponse(status: 204, statusMessage: "No Content", contentType: "image/x-icon", body: Data(), on: connection)
            return
        }

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            serveIndexHTML(on: connection)
        case ("GET", let path) where path.hasPrefix("/editor/"):
            let relative = String(path.dropFirst("/editor/".count))
            serveEditorAsset(relative: relative, on: connection)

        // State / queries
        case ("GET", "/api/state"):
            handleGetState(on: connection)
        case ("GET", "/api/workspaces"):
            handleListWorkspaces(on: connection)
        case ("GET", "/api/workspaces/current"):
            handleCurrentWorkspace(on: connection)
        case ("GET", let path) where path.hasPrefix("/api/workspaces/") && path.hasSuffix("/tree"):
            let middle = path.dropFirst("/api/workspaces/".count).dropLast("/tree".count)
            handleWorkspaceTree(idString: String(middle), on: connection)

        // Workspaces
        case ("POST", "/api/workspaces"):
            handleCreateWorkspace(body: request.body, on: connection)
        case ("PATCH", let path) where path.hasPrefix("/api/workspaces/"):
            let idString = String(path.dropFirst("/api/workspaces/".count))
            handlePatchWorkspace(idString: idString, body: request.body, on: connection)

        // Profiles (no delete route: deleting one moves spaces, so it stays a UI action)
        case ("GET", "/api/profiles"):
            handleListProfiles(on: connection)
        case ("POST", "/api/profiles"):
            handleCreateProfile(body: request.body, on: connection)
        case ("POST", let path) where path.hasPrefix("/api/profiles/") && path.hasSuffix("/favorites"):
            let middle = path.dropFirst("/api/profiles/".count).dropLast("/favorites".count)
            handleAddFavorite(profileIdString: String(middle), body: request.body, on: connection)
        case ("PATCH", let path) where path.hasPrefix("/api/profiles/"):
            let idString = String(path.dropFirst("/api/profiles/".count))
            handlePatchProfile(idString: idString, body: request.body, on: connection)

        // Favorites (ids are link ids inside a profile's grid)
        case ("POST", let path) where path.hasPrefix("/api/favorites/") && path.hasSuffix("/move"):
            let middle = path.dropFirst("/api/favorites/".count).dropLast("/move".count)
            handleMoveFavorite(idString: String(middle), body: request.body, on: connection)
        case ("POST", let path) where path.hasPrefix("/api/favorites/") && path.hasSuffix("/unpin"):
            let middle = path.dropFirst("/api/favorites/".count).dropLast("/unpin".count)
            handleUnpinFavorite(idString: String(middle), body: request.body, on: connection)
        case ("DELETE", let path) where path.hasPrefix("/api/favorites/"):
            let idString = String(path.dropFirst("/api/favorites/".count))
            handleDeleteFavorite(idString: idString, on: connection)

        // Folders
        case ("POST", "/api/folders"):
            handleCreateFolder(body: request.body, on: connection)
        case ("PATCH", let path) where path.hasPrefix("/api/folders/"):
            let idString = String(path.dropFirst("/api/folders/".count))
            handlePatchFolder(idString: idString, body: request.body, on: connection)

        // Links
        case ("POST", "/api/links"):
            handleCreateLink(body: request.body, on: connection)
        case ("PATCH", let path) where path.hasPrefix("/api/links/"):
            let idString = String(path.dropFirst("/api/links/".count))
            handlePatchLink(idString: idString, body: request.body, on: connection)

        // Notes — create + metadata patch. Content read/write stays on the
        // existing GET/PUT routes below, shared with the bundled editor.
        case ("POST", "/api/notes"):
            handleCreateNote(body: request.body, on: connection)
        case ("PATCH", let path) where path.hasPrefix("/api/notes/"):
            let idString = String(path.dropFirst("/api/notes/".count))
            handlePatchNote(idString: idString, body: request.body, on: connection)
        case ("GET", let path) where path.hasPrefix("/api/notes/"):
            let idString = String(path.dropFirst("/api/notes/".count))
            handleGetNote(idString: idString, on: connection)
        case ("PUT", let path) where path.hasPrefix("/api/notes/"):
            let idString = String(path.dropFirst("/api/notes/".count))
            handlePutNote(idString: idString, body: request.body, on: connection)

        // Generic node ops
        case ("DELETE", let path) where path.hasPrefix("/api/nodes/"):
            let idString = String(path.dropFirst("/api/nodes/".count))
            handleDeleteNode(idString: idString, expectedType: request.query["type"], on: connection)
        case ("POST", let path) where path.hasPrefix("/api/nodes/") && path.hasSuffix("/move"):
            let middle = path.dropFirst("/api/nodes/".count).dropLast("/move".count)
            handleMoveNode(idString: String(middle), body: request.body, on: connection)

        default:
            sendStatus(404, message: "Not Found", on: connection)
        }
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func noteTitle(id: UUID) -> String? {
        guard let node = model?.nodeAcrossWorkspaces(id: id) else { return nil }
        if case .note(let note) = node { return note.title }
        return nil
    }

    private func handleGetNote(idString: String, on connection: NWConnection) {
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid note id", on: connection)
            return
        }
        guard let title = noteTitle(id: id) else {
            sendError(status: 404, code: "note_not_found", message: "Note not found", on: connection)
            return
        }
        let content = noteStorage.read(id: id)
        let payload: [String: Any] = [
            "id": id.uuidString,
            "title": title,
            "content": content,
            "revision": Self.noteRevision(content)
        ]
        sendJSON(payload, on: connection)
    }

    private func handlePutNote(idString: String, body: Data, on connection: NWConnection) {
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid note id", on: connection)
            return
        }
        guard noteTitle(id: id) != nil else {
            // The sidebar entry is gone; do not resurrect the .md file.
            sendError(status: 404, code: "note_not_found", message: "Note not found", on: connection)
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let content = json["content"] as? String else {
            sendError(status: 400, code: "bad_body", message: "content must be a string", on: connection)
            return
        }
        let current = Self.noteRevision(noteStorage.read(id: id))
        var client: String?
        var sequence: Int?
        var priorBases: [String] = []
        if let value = json["revision"] {
            guard let revision = value as? String else {
                sendError(status: 400, code: "bad_revision", message: "revision must be a string", on: connection)
                return
            }
            if json["client_id"] != nil || json["sequence"] != nil {
                guard let id = json["client_id"] as? String, UUID(uuidString: id) != nil,
                      let number = json["sequence"] as? Int, number > 0 else {
                    sendError(status: 400, code: "bad_revision", message: "Invalid editor write sequence", on: connection)
                    return
                }
                client = id
                sequence = number
            }
            let last = noteWrites[id]
            let sameClient = last?.client == client && last?.result == current
            let newer = sequence.map { $0 > (last?.sequence ?? 0) } ?? false
            let canFollow = sameClient && newer && (last?.bases.contains(revision) ?? false)
            guard (revision == current && !(sameClient && !newer)) || canFollow else {
                sendError(status: 409, code: "note_conflict", message: "Note changed since it was loaded", on: connection)
                return
            }
            if sameClient { priorBases = last?.bases ?? [] }
        } else if json["client_id"] != nil || json["sequence"] != nil {
            sendError(status: 400, code: "bad_revision", message: "revision is required with an editor write sequence", on: connection)
            return
        }
        do {
            try noteStorage.write(id: id, content: content)
            let revision = Self.noteRevision(content)
            if let client, let sequence, let base = json["revision"] as? String {
                priorBases.append(base)
                priorBases.append(current)
                noteWrites[id] = NoteWrite(client: client, sequence: sequence, bases: Array(priorBases.suffix(128)), result: revision)
            } else {
                noteWrites.removeValue(forKey: id)
            }
            sendJSON(["ok": true, "revision": revision], on: connection)
        } catch {
            logger.error("Note write failed: \(error.localizedDescription, privacy: .public)")
            sendError(status: 500, code: "write_failed", message: "Could not write note", on: connection)
        }
    }

    private static func noteRevision(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Agent API handlers

    private func handleGetState(on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(model.state)
            sendOkRawJSON(top: ["state": data], on: connection)
        } catch {
            sendError(status: 500, code: "encode_failed", message: "Failed to encode state", on: connection)
        }
    }

    private func handleListWorkspaces(on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        let list: [[String: Any]] = model.workspaces.map { ws in
            [
                "id": ws.id.uuidString,
                "name": ws.name,
                "colorId": ws.colorId.rawValue,
                "profileId": ws.profileId.uuidString
            ]
        }
        sendOk(["workspaces": list], on: connection)
    }

    private func handleCurrentWorkspace(on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        let state = model.state
        let settingsShown = model.isSettingsShown
        // Agent API contract: while Settings is shown there is no current space, so
        // the agent asks instead of guessing (skills/sidebarc/SKILL.md).
        let selectedId = settingsShown ? nil : state.selectedWorkspaceId
        let workspace = selectedId.flatMap { id in model.workspaces.first(where: { $0.id == id }) }

        if let workspace {
            let payload: [String: Any] = [
                "selected": true,
                "settingsSelected": settingsShown,
                "workspace": [
                    "id": workspace.id.uuidString,
                    "name": workspace.name,
                    "colorId": workspace.colorId.rawValue,
                    "profileId": workspace.profileId.uuidString
                ]
            ]
            sendOk(payload, on: connection)
            return
        }

        let payload: [String: Any] = [
            "selected": false,
            "settingsSelected": settingsShown,
            "workspace": NSNull()
        ]
        sendOk(payload, on: connection)
    }

    private func handleWorkspaceTree(idString: String, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid workspace id", on: connection)
            return
        }
        guard let workspace = model.workspaces.first(where: { $0.id == id }) else {
            sendError(status: 404, code: "workspace_not_found", message: "Workspace not found", on: connection)
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(workspace)
            sendOkRawJSON(top: ["workspace": data], on: connection)
        } catch {
            sendError(status: 500, code: "encode_failed", message: "Failed to encode workspace", on: connection)
        }
    }

    private func handleCreateWorkspace(body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        guard let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            sendError(status: 400, code: "bad_name", message: "name is required", on: connection)
            return
        }
        let color: WorkspaceColorId
        if let raw = json["colorId"] as? String {
            guard let resolved = Self.resolveColor(raw) else {
                sendError(status: 400, code: "bad_color", message: "Unknown colorId: \(raw)", on: connection)
                return
            }
            color = resolved
        } else {
            color = .defaultColor()
        }
        var profileId: UUID?
        if json["profile_id"] != nil {
            guard let parsed = Self.parseUUID(json["profile_id"]), model.profile(id: parsed) != nil else {
                sendError(status: 404, code: "profile_not_found", message: "Profile not found", on: connection)
                return
            }
            profileId = parsed
        }
        let id = model.createWorkspace(name: name, colorId: color)
        if let profileId {
            model.assignWorkspace(id, toProfile: profileId)
        }
        sendOk(["id": id.uuidString], on: connection)
    }

    private func handlePatchWorkspace(idString: String, body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid workspace id", on: connection)
            return
        }
        guard model.workspaces.contains(where: { $0.id == id }) else {
            sendError(status: 404, code: "workspace_not_found", message: "Workspace not found", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        // Resolve all fields before mutating so a bad colorId can't leave
        // a partial rename applied.
        let trimmedName = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName: String? = (trimmedName?.isEmpty == false) ? trimmedName : nil

        let newColor: WorkspaceColorId?
        if let raw = json["colorId"] as? String {
            guard let resolved = Self.resolveColor(raw) else {
                sendError(status: 400, code: "bad_color", message: "Unknown colorId: \(raw)", on: connection)
                return
            }
            newColor = resolved
        } else {
            newColor = nil
        }

        var newProfileId: UUID?
        if json["profile_id"] != nil {
            guard let parsed = Self.parseUUID(json["profile_id"]), model.profile(id: parsed) != nil else {
                sendError(status: 404, code: "profile_not_found", message: "Profile not found", on: connection)
                return
            }
            newProfileId = parsed
        }

        if let newName {
            model.renameWorkspace(id: id, newName: newName)
        }
        if let newColor {
            model.updateWorkspaceColor(id: id, colorId: newColor)
        }
        if let newProfileId {
            model.assignWorkspace(id, toProfile: newProfileId)
        }
        sendOk([:], on: connection)
    }

    private func handleCreateFolder(body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        guard let wsId = Self.parseUUID(json["workspace_id"]) else {
            sendError(status: 400, code: "bad_workspace_id", message: "workspace_id is required", on: connection)
            return
        }
        guard let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            sendError(status: 400, code: "bad_name", message: "name is required", on: connection)
            return
        }
        guard Self.validOptionalUUID(json["parent_id"]) else {
            sendError(status: 400, code: "bad_id", message: "Invalid parent_id", on: connection)
            return
        }
        let parentId = Self.parseOptionalUUID(json["parent_id"])
        if let parentResult = validateParent(workspaceId: wsId, parentId: parentId, expectFolder: true) {
            switch parentResult {
            case .success: break
            case .failure(let code, let message):
                sendError(status: 404, code: code, message: message, on: connection)
                return
            }
        }
        let expanded = (json["expanded"] as? Bool) ?? true
        guard let id = model.addFolder(name: name, workspaceId: wsId, parentId: parentId, isExpanded: expanded) else {
            sendError(status: 404, code: "workspace_not_found", message: "Workspace not found", on: connection)
            return
        }
        sendOk(["id": id.uuidString], on: connection)
    }

    private func handlePatchFolder(idString: String, body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid id", on: connection)
            return
        }
        guard let node = model.nodeAcrossWorkspaces(id: id), case .folder = node else {
            sendError(status: 404, code: "folder_not_found", message: "Folder not found", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        if let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            model.renameNode(id: id, newName: name)
        }
        if let expanded = json["expanded"] as? Bool {
            model.setFolderExpanded(id: id, isExpanded: expanded)
        }
        sendOk([:], on: connection)
    }

    private func handleCreateLink(body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        guard let wsId = Self.parseUUID(json["workspace_id"]) else {
            sendError(status: 400, code: "bad_workspace_id", message: "workspace_id is required", on: connection)
            return
        }
        guard let url = (json["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            sendError(status: 400, code: "bad_url", message: "url is required", on: connection)
            return
        }
        guard BrowserManager.validatedLinkURL(from: url) != nil else {
            sendError(status: 400, code: "bad_url", message: "url must be an HTTP or HTTPS URL with a host", on: connection)
            return
        }
        guard Self.validOptionalUUID(json["parent_id"]) else {
            sendError(status: 400, code: "bad_id", message: "Invalid parent_id", on: connection)
            return
        }
        let parentId = Self.parseOptionalUUID(json["parent_id"])
        if let result = validateParent(workspaceId: wsId, parentId: parentId, expectFolder: true) {
            switch result {
            case .success: break
            case .failure(let code, let message):
                sendError(status: 404, code: code, message: message, on: connection)
                return
            }
        }
        let providedTitle = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let providedTitle, !providedTitle.isEmpty {
            title = providedTitle
        } else {
            title = URL(string: url)?.host ?? url
        }
        guard let id = model.addLink(urlString: url, title: title, workspaceId: wsId, parentId: parentId) else {
            sendError(status: 404, code: "workspace_not_found", message: "Workspace not found", on: connection)
            return
        }
        sendOk(["id": id.uuidString], on: connection)
    }

    private func handlePatchLink(idString: String, body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid id", on: connection)
            return
        }
        guard let node = model.nodeAcrossWorkspaces(id: id), case .link = node else {
            sendError(status: 404, code: "link_not_found", message: "Link not found", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        if let value = json["url"] {
            guard let url = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  BrowserManager.validatedLinkURL(from: url) != nil else {
                sendError(status: 400, code: "bad_url", message: "url must be an HTTP or HTTPS URL with a host", on: connection)
                return
            }
        }
        if let value = json["browser_bundle_id"] {
            if let bundleId = value as? String {
                let trimmed = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, !BrowserManager.isBrowser(bundleId: trimmed) {
                    sendError(status: 400, code: "bad_browser", message: "browser_bundle_id must identify an installed browser", on: connection)
                    return
                }
            } else if !(value is NSNull) {
                sendError(status: 400, code: "bad_browser", message: "browser_bundle_id must be an installed browser or null", on: connection)
                return
            }
        }
        if let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            model.renameNode(id: id, newName: title)
        }
        if let url = json["url"] as? String {
            model.updateLinkUrl(id: id, newUrl: url)
        }
        if let value = json["browser_bundle_id"] {
            // A bundle id sets the override; null (or "") clears it.
            let bundleId = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            model.setLinkBrowserOverride(id: id, bundleId: (bundleId?.isEmpty ?? true) ? nil : bundleId)
        }
        sendOk([:], on: connection)
    }

    // MARK: - Profiles and favorites

    private func profilePayload(_ profile: Profile, model: AppModel) -> [String: Any] {
        [
            "id": profile.id.uuidString,
            "name": profile.name,
            "browserBundleId": profile.browserBundleId ?? NSNull(),
            "browserProfiles": profile.browserProfiles,
            "workspaceIds": model.workspaces(inProfile: profile.id).map(\.id.uuidString),
            "favorites": profile.favorites.map { link in
                [
                    "id": link.id.uuidString,
                    "title": link.title,
                    "url": link.url,
                    "browserBundleId": link.browserBundleId ?? NSNull()
                ] as [String: Any]
            },
            "maxFavorites": Profile.maxFavorites
        ]
    }

    private func handleListProfiles(on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        sendOk(["profiles": model.profiles.map { profilePayload($0, model: model) }], on: connection)
    }

    private func handleCreateProfile(body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        guard let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            sendError(status: 400, code: "bad_name", message: "name is required", on: connection)
            return
        }
        let id = model.createProfile(name: name)
        sendOk(["id": id.uuidString], on: connection)
    }

    private func handlePatchProfile(idString: String, body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid profile id", on: connection)
            return
        }
        guard model.profile(id: id) != nil else {
            sendError(status: 404, code: "profile_not_found", message: "Profile not found", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        let updatesBrowser = json["browser_bundle_id"] != nil
        var browserBundleId: String?
        if let value = json["browser_bundle_id"] {
            // A bundle id sets the profile's browser; null (or "") inherits the default browser.
            if let raw = value as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                browserBundleId = trimmed.isEmpty ? nil : trimmed
                if let browserBundleId, !BrowserManager.isBrowser(bundleId: browserBundleId) {
                    sendError(status: 400, code: "bad_browser", message: "browser_bundle_id must identify an installed browser", on: connection)
                    return
                }
            } else if value is NSNull {
                browserBundleId = nil
            } else {
                sendError(status: 400, code: "bad_browser", message: "browser_bundle_id must be an installed browser or null", on: connection)
                return
            }
        }
        if let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            model.renameProfile(id: id, newName: name)
        }
        if updatesBrowser {
            model.setProfileBrowser(id: id, bundleId: browserBundleId)
        }
        sendOk([:], on: connection)
    }

    private func handleAddFavorite(profileIdString: String, body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let profileId = UUID(uuidString: profileIdString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid profile id", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        guard let url = (json["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
            sendError(status: 400, code: "bad_url", message: "url is required", on: connection)
            return
        }
        guard BrowserManager.validatedLinkURL(from: url) != nil else {
            sendError(status: 400, code: "bad_url", message: "url must be an HTTP or HTTPS URL with a host", on: connection)
            return
        }
        let providedTitle = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (providedTitle?.isEmpty == false) ? providedTitle! : (URL(string: url)?.host ?? url)
        switch model.addFavorite(profileId: profileId, urlString: url, title: title) {
        case .success(let id):
            sendOk(["id": id.uuidString], on: connection)
        case .failure(.profileNotFound):
            sendError(status: 404, code: "profile_not_found", message: "Profile not found", on: connection)
        case .failure(.invalidURL):
            sendError(status: 400, code: "bad_url", message: "url must be an HTTP or HTTPS URL with a host", on: connection)
        case .failure(.full):
            sendError(status: 409, code: "favorites_full", message: "Profile already has \(Profile.maxFavorites) favorites", on: connection)
        case .failure(.duplicate(let existingId)):
            sendError(status: 409, code: "duplicate_favorite", message: "Already a favorite: \(existingId.uuidString)", on: connection)
        }
    }

    private func handleMoveFavorite(idString: String, body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid favorite id", on: connection)
            return
        }
        guard let json = parseJSONObject(body), let index = json["index"] as? Int else {
            sendError(status: 400, code: "bad_index", message: "index (integer) is required", on: connection)
            return
        }
        guard model.moveFavorite(id: id, toIndex: index) else {
            sendError(status: 404, code: "favorite_not_found", message: "Favorite not found", on: connection)
            return
        }
        sendOk([:], on: connection)
    }

    private func handleUnpinFavorite(idString: String, body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid favorite id", on: connection)
            return
        }
        guard let json = parseJSONObject(body), let workspaceId = Self.parseUUID(json["workspace_id"]) else {
            sendError(status: 400, code: "bad_workspace_id", message: "workspace_id is required", on: connection)
            return
        }
        guard model.profileId(forFavoriteId: id) != nil else {
            sendError(status: 404, code: "favorite_not_found", message: "Favorite not found", on: connection)
            return
        }
        guard model.unpinFavorite(id: id, toWorkspaceId: workspaceId) else {
            sendError(status: 404, code: "workspace_not_found", message: "Workspace not found", on: connection)
            return
        }
        sendOk([:], on: connection)
    }

    private func handleDeleteFavorite(idString: String, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid favorite id", on: connection)
            return
        }
        guard model.deleteFavorite(id: id) else {
            sendError(status: 404, code: "favorite_not_found", message: "Favorite not found", on: connection)
            return
        }
        sendOk([:], on: connection)
    }

    private func handleCreateNote(body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        guard let wsId = Self.parseUUID(json["workspace_id"]) else {
            sendError(status: 400, code: "bad_workspace_id", message: "workspace_id is required", on: connection)
            return
        }
        guard let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            sendError(status: 400, code: "bad_title", message: "title is required", on: connection)
            return
        }
        guard Self.validOptionalUUID(json["parent_id"]) else {
            sendError(status: 400, code: "bad_id", message: "Invalid parent_id", on: connection)
            return
        }
        let parentId = Self.parseOptionalUUID(json["parent_id"])
        if let result = validateParent(workspaceId: wsId, parentId: parentId, expectFolder: true) {
            switch result {
            case .success: break
            case .failure(let code, let message):
                sendError(status: 404, code: code, message: message, on: connection)
                return
            }
        }
        let content = (json["content"] as? String) ?? ""
        guard let id = model.addNote(title: title, workspaceId: wsId, parentId: parentId, content: content) else {
            sendError(status: 404, code: "workspace_not_found", message: "Workspace not found", on: connection)
            return
        }
        sendOk(["id": id.uuidString], on: connection)
    }

    private func handlePatchNote(idString: String, body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid id", on: connection)
            return
        }
        guard let node = model.nodeAcrossWorkspaces(id: id), case .note = node else {
            sendError(status: 404, code: "note_not_found", message: "Note not found", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        if let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            model.renameNode(id: id, newName: title)
        }
        sendOk([:], on: connection)
    }

    private func handleDeleteNode(idString: String, expectedType: String?, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid id", on: connection)
            return
        }
        guard let node = model.nodeAcrossWorkspaces(id: id) else {
            sendError(status: 404, code: "node_not_found", message: "Node not found", on: connection)
            return
        }
        if let expectedType {
            let matches: Bool
            switch (expectedType, node) {
            case ("link", .link), ("folder", .folder), ("note", .note): matches = true
            default: matches = false
            }
            guard matches else {
                sendError(status: 409, code: "node_type_mismatch", message: "Node has a different type", on: connection)
                return
            }
        }
        guard model.deleteNode(id: id) else {
            sendError(status: 500, code: "save_failed", message: "Could not save the deletion", on: connection)
            return
        }
        sendOk([:], on: connection)
    }

    private func handleMoveNode(idString: String, body: Data, on connection: NWConnection) {
        guard let model else {
            sendError(status: 503, code: "model_unavailable", message: "App model not available", on: connection)
            return
        }
        guard let id = UUID(uuidString: idString) else {
            sendError(status: 400, code: "bad_id", message: "Invalid id", on: connection)
            return
        }
        guard let sourceWsId = model.workspaceId(forNodeId: id) else {
            sendError(status: 404, code: "node_not_found", message: "Node not found", on: connection)
            return
        }
        guard let json = parseJSONObject(body) else {
            sendError(status: 400, code: "bad_body", message: "Body must be a JSON object", on: connection)
            return
        }
        guard Self.validOptionalUUID(json["to_workspace_id"], allowRoot: false),
              Self.validOptionalUUID(json["to_parent_id"]) else {
            sendError(status: 400, code: "bad_id", message: "Invalid destination id", on: connection)
            return
        }
        if let value = json["index"], !(value is Int) {
            sendError(status: 400, code: "bad_index", message: "index must be an integer", on: connection)
            return
        }
        let toWsId = Self.parseOptionalUUID(json["to_workspace_id"])
        let destWsId = toWsId ?? sourceWsId
        let toParentId = json["to_parent_id"] == nil && destWsId == sourceWsId
            ? model.location(of: id, in: sourceWsId)?.parentId
            : Self.parseOptionalUUID(json["to_parent_id"])
        let index = json["index"] as? Int

        guard Set(json.keys).isSubset(of: ["to_workspace_id", "to_parent_id", "index"]) else {
            sendError(status: 400, code: "bad_body", message: "Unknown move field", on: connection)
            return
        }
        if json["to_workspace_id"] == nil, json["to_parent_id"] == nil, json["index"] == nil {
            sendError(status: 400, code: "no_move_params", message: "Provide at least one of to_workspace_id, to_parent_id, or index", on: connection)
            return
        }

        guard model.workspaces.contains(where: { $0.id == destWsId }) else {
            sendError(status: 404, code: "workspace_not_found", message: "Destination workspace not found", on: connection)
            return
        }
        if let toParentId {
            guard let parentNode = model.nodeAcrossWorkspaces(id: toParentId), case .folder = parentNode else {
                sendError(status: 404, code: "parent_not_found", message: "Target parent folder not found", on: connection)
                return
            }
            if model.workspaceId(forNodeId: toParentId) != destWsId {
                sendError(status: 400, code: "parent_wrong_workspace", message: "Target parent is in a different workspace", on: connection)
                return
            }
        }

        if destWsId == sourceWsId {
            guard model.moveNode(id: id, toParentId: toParentId, index: index ?? Int.max) else {
                sendError(status: 409, code: "invalid_move", message: "Cannot move a folder into itself or its descendants", on: connection)
                return
            }
        } else {
            model.moveNodeToWorkspace(id: id, workspaceId: destWsId, parentId: toParentId, index: index)
        }
        sendOk([:], on: connection)
    }

    // MARK: - Agent API helpers

    private func validatePatch(_ request: ParsedRequest, on connection: NWConnection) -> Bool {
        let allowed: Set<String>
        switch request.path {
        case let path where path.hasPrefix("/api/workspaces/"):
            allowed = ["name", "colorId", "profile_id"]
        case let path where path.hasPrefix("/api/profiles/"):
            allowed = ["name", "browser_bundle_id"]
        case let path where path.hasPrefix("/api/folders/"):
            allowed = ["name", "expanded"]
        case let path where path.hasPrefix("/api/links/"):
            allowed = ["title", "url", "browser_bundle_id"]
        case let path where path.hasPrefix("/api/notes/"):
            allowed = ["title"]
        default:
            return true
        }
        guard let json = parseJSONObject(request.body), !json.isEmpty,
              Set(json.keys).isSubset(of: allowed) else {
            sendError(status: 400, code: "bad_body", message: "Invalid or unknown patch fields", on: connection)
            return false
        }
        for (key, value) in json {
            if key == "expanded" {
                guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() else {
                    sendError(status: 400, code: "bad_body", message: "expanded must be a boolean", on: connection)
                    return false
                }
            } else if key == "browser_bundle_id", value is NSNull {
                continue
            } else {
                guard let string = value as? String,
                      key == "browser_bundle_id" || !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    sendError(status: 400, code: "bad_body", message: "\(key) must be a valid string", on: connection)
                    return false
                }
            }
        }
        return true
    }

    private enum ParentValidation {
        case success
        case failure(code: String, message: String)
    }

    private func validateParent(workspaceId: UUID, parentId: UUID?, expectFolder: Bool) -> ParentValidation? {
        guard let parentId else { return nil }
        guard let model else { return .failure(code: "model_unavailable", message: "App model not available") }
        guard let workspace = model.workspaces.first(where: { $0.id == workspaceId }) else {
            return .failure(code: "workspace_not_found", message: "Workspace not found")
        }
        guard let node = model.findNode(id: parentId, in: workspace.items) else {
            return .failure(code: "parent_not_found", message: "Parent folder not found in workspace")
        }
        if expectFolder, case .folder = node { return .success }
        if expectFolder { return .failure(code: "parent_not_folder", message: "parent_id must reference a folder") }
        return .success
    }

    private func parseJSONObject(_ data: Data) -> [String: Any]? {
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func parseUUID(_ value: Any?) -> UUID? {
        guard let s = value as? String else { return nil }
        return UUID(uuidString: s)
    }

    private static func parseOptionalUUID(_ value: Any?) -> UUID? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return UUID(uuidString: s)
    }

    private static func validOptionalUUID(_ value: Any?, allowRoot: Bool = true) -> Bool {
        guard let value else { return true }
        if value is NSNull { return true }
        if allowRoot, let string = value as? String, string == "root" { return true }
        return parseUUID(value) != nil
    }

    private static func resolveColor(_ raw: String) -> WorkspaceColorId? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let direct = WorkspaceColorId(rawValue: trimmed) {
            return direct == .settingsBackground ? nil : direct
        }
        let lower = trimmed.lowercased()
        for case let c in WorkspaceColorId.allCases where c.name.lowercased() == lower {
            return c
        }
        return nil
    }

    private func sendOk(_ payload: [String: Any], on connection: NWConnection) {
        var dict = payload
        dict["ok"] = true
        sendJSON(dict, on: connection)
    }

    private func sendOkRawJSON(top: [String: Data], on connection: NWConnection) {
        // Builds `{"ok":true,"<key>":<rawJson>,...}` so we can splice in
        // pre-encoded JSON (e.g. AppState) without lossy round-tripping.
        var parts: [String] = ["\"ok\":true"]
        for (key, data) in top {
            let escapedKey = key.replacingOccurrences(of: "\"", with: "\\\"")
            let json = String(data: data, encoding: .utf8) ?? "null"
            parts.append("\"\(escapedKey)\":\(json)")
        }
        let body = Data("{\(parts.joined(separator: ","))}".utf8)
        sendResponse(status: 200, statusMessage: "OK", contentType: "application/json; charset=utf-8", body: body, on: connection)
    }

    private func sendError(status: Int, code: String, message: String, on connection: NWConnection) {
        let payload: [String: Any] = [
            "ok": false,
            "error": message,
            "code": code
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"ok\":false}".utf8)
        sendResponse(status: status, statusMessage: "Error", contentType: "application/json; charset=utf-8", body: data, on: connection)
    }

    // MARK: - Resource resolution

    /// Locates the directory that holds the bundled `NoteEditor/` assets.
    ///
    /// Deliberately does **not** use `Bundle.module`: Swift Bundler injects a
    /// custom `Bundle.module` accessor that calls `fatalError` when its two
    /// hardcoded search paths (the app root and a developer `.build` path) miss.
    /// Because the resource bundle actually ships under `Contents/Resources`,
    /// every external install of 0.1.12 trapped at launch the moment this
    /// accessor was touched. Here we search the real locations and return `nil`
    /// on miss so a missing bundle degrades to "editor unavailable" (the server
    /// already 404s/500s) instead of killing the app.
    static func resolveBundledResourcesURL() -> URL? {
        let fm = FileManager.default

        // Bases that might contain the resource bundle (packaged app, flat dev
        // builds) or the assets directly. `Bundle(for:)` covers test/dynamic
        // builds where SidebArcCore is not statically linked into Bundle.main.
        var bases: [URL] = []
        if let main = Bundle.main.resourceURL { bases.append(main) }
        bases.append(Bundle.main.bundleURL)
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            bases.append(exeDir)
        }
        let codeBundle = Bundle(for: NoteServer.self)
        if let codeResources = codeBundle.resourceURL { bases.append(codeResources) }
        bases.append(codeBundle.bundleURL)

        func hasEditor(_ dir: URL) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent("NoteEditor/index.html").path)
        }

        for base in bases {
            // Nested SwiftPM resource bundle (`<Package>_<Target>.bundle`). Matched by
            // content, not name, so package/target renames can't break the lookup;
            // scripts/verify-build.sh applies the same rule.
            let nested = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            for candidate in nested.filter({ $0.pathExtension == "bundle" }).sorted(by: { $0.path < $1.path }) {
                if let bundle = Bundle(url: candidate), let resources = bundle.resourceURL, hasEditor(resources) {
                    return resources
                }
            }
            // Resources copied directly under the base directory.
            if hasEditor(base) {
                return base
            }
        }
        return nil
    }

    // MARK: - Static asset serving

    private func serveIndexHTML(on connection: NWConnection) {
        guard let resourcesURL else {
            sendStatus(500, message: "No Resources", on: connection)
            return
        }
        let assetURL = resourcesURL
            .appendingPathComponent("NoteEditor", isDirectory: true)
            .appendingPathComponent("index.html")
        guard let html = try? String(contentsOf: assetURL, encoding: .utf8) else {
            sendStatus(404, message: "Asset Missing", on: connection)
            return
        }
        guard let start = html.range(of: "<script>"), let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex) else {
            sendStatus(500, message: "Invalid Editor", on: connection)
            return
        }
        let script = Data(html[start.upperBound..<end.lowerBound].utf8)
        let hash = Data(SHA256.hash(data: script)).base64EncodedString()
        let policy = "default-src 'none'; script-src 'sha256-\(hash)' blob:; style-src 'unsafe-inline'; connect-src 'self'; img-src https: http: data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
        sendResponse(status: 200, statusMessage: "OK", contentType: "text/html; charset=utf-8", body: Data(html.utf8), on: connection, contentSecurityPolicy: policy)
    }

    private func serveEditorAsset(relative: String, on connection: NWConnection) {
        // Percent-decode first so that escaped traversal sequences (e.g.
        // `%2e%2e`) are caught by the check below — `Data(contentsOf:)`
        // resolves the URL via its decoded path, which would otherwise
        // collapse them back into `..`.
        guard let decoded = relative.removingPercentEncoding else {
            sendStatus(400, message: "Bad Path", on: connection)
            return
        }
        if decoded.contains("..") || decoded.hasPrefix("/") {
            sendStatus(400, message: "Bad Path", on: connection)
            return
        }

        guard let resourcesURL else {
            sendStatus(500, message: "No Resources", on: connection)
            return
        }

        let editorRoot = resourcesURL.appendingPathComponent("NoteEditor", isDirectory: true)
        let assetURL = editorRoot.appendingPathComponent(decoded)

        // Belt-and-braces: ensure the resolved path stays under the editor
        // root after symlink/`..` resolution.
        let resolvedAsset = assetURL.standardizedFileURL.resolvingSymlinksInPath().path
        let resolvedRoot = editorRoot.standardizedFileURL.resolvingSymlinksInPath().path
        if !resolvedAsset.hasPrefix(resolvedRoot + "/") {
            sendStatus(400, message: "Bad Path", on: connection)
            return
        }

        guard let data = try? Data(contentsOf: assetURL) else {
            sendStatus(404, message: "Asset Missing", on: connection)
            return
        }

        let contentType = Self.mimeType(for: assetURL.pathExtension.lowercased())
        sendResponse(status: 200, statusMessage: "OK", contentType: contentType, body: data, on: connection)
    }

    private static func mimeType(for ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Response helpers

    private func sendStatus(_ status: Int, message: String, on connection: NWConnection) {
        let body = Data("\(status) \(message)".utf8)
        sendResponse(status: status, statusMessage: message, contentType: "text/plain; charset=utf-8", body: body, on: connection)
    }

    private func sendJSON(_ object: Any, on connection: NWConnection) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        sendResponse(status: 200, statusMessage: "OK", contentType: "application/json; charset=utf-8", body: data, on: connection)
    }

    private func sendResponse(status: Int, statusMessage: String, contentType: String, body: Data, on connection: NWConnection, contentSecurityPolicy: String? = nil) {
        var headers = ""
        headers += "HTTP/1.1 \(status) \(statusMessage)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(body.count)\r\n"
        headers += "Cache-Control: no-store\r\n"
        headers += "X-Content-Type-Options: nosniff\r\n"
        if let contentSecurityPolicy {
            headers += "Content-Security-Policy: \(contentSecurityPolicy)\r\n"
        }
        headers += "Connection: close\r\n"
        headers += "\r\n"

        var packet = Data(headers.utf8)
        packet.append(body)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

}
