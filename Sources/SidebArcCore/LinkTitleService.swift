import AppKit
import os

@MainActor
final class LinkTitleService {
    static let shared = LinkTitleService()

    /// The most of a page that's read looking for `<title>`.
    nonisolated static let maxHTMLBytes = 200_000
    /// Longer titles are cut here (with "…").
    nonisolated static let maxTitleLength = 300
    /// Fetches running at once; the rest wait their turn (a paste of many URLs).
    nonisolated static let maxConcurrentFetches = 4

    /// Downloads at most `limit` bytes of the body. Non-2xx responses may return
    /// no body. Injected by tests; the app streams with `URLSession.bytes(for:)`.
    typealias Fetch = @Sendable (_ request: URLRequest, _ limit: Int) async throws -> (Data, URLResponse)

    private let fetch: Fetch
    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "title")
    private var inFlight: Set<UUID> = []
    private var running = 0
    private var waiting: [() -> Void] = []

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    private convenience init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        config.httpAdditionalHeaders = ["Accept": "text/html,application/xhtml+xml"]
        let session = URLSession(configuration: config)
        self.init(fetch: { request, limit in
            try await Self.download(request, limit: limit, session: session)
        })
    }

    func fetchTitle(for url: URL, linkId: UUID, completion: @escaping (String?) -> Void) {
        if inFlight.contains(linkId) {
            completion(nil)
            return
        }
        inFlight.insert(linkId)
        let start = { self.startFetch(for: url, linkId: linkId, completion: completion) }
        if running < Self.maxConcurrentFetches {
            start()
        } else {
            waiting.append(start)
        }
    }

    private func startFetch(for url: URL, linkId: UUID, completion: @escaping (String?) -> Void) {
        running += 1
        logger.debug("Fetching title for \(url.host ?? "unknown", privacy: .private)")

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        Task {
            defer {
                inFlight.remove(linkId)
                running -= 1
                if !waiting.isEmpty {
                    waiting.removeFirst()()
                }
            }
            do {
                let (data, response) = try await fetch(request, Self.maxHTMLBytes)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    logger.debug("Title fetch non-200 for \(url.host ?? "unknown", privacy: .private)")
                    completion(nil)
                    return
                }
                let title = Self.title(fromHTML: data.prefix(Self.maxHTMLBytes), textEncodingName: response.textEncodingName)
                if title == nil {
                    logger.debug("Title parse failed for \(url.host ?? "unknown", privacy: .private)")
                }
                completion(title)
            } catch {
                logger.debug("Title fetch error for \(url.host ?? "unknown", privacy: .private)")
                completion(nil)
            }
        }
    }

    /// Streams the body and stops reading at `limit` bytes, cancelling the rest of
    /// the transfer. A non-2xx response's body isn't read.
    nonisolated static func download(_ request: URLRequest, limit: Int, session: URLSession) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return (Data(), response)
        }
        return (try await readPrefix(of: bytes, limit: limit), response)
    }

    /// The first `limit` bytes of `bytes`; never reads further.
    nonisolated static func readPrefix<Bytes: AsyncSequence>(of bytes: Bytes, limit: Int) async throws -> Data
    where Bytes.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        guard limit > 0 else { return data }
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    /// The page title, whitespace collapsed, entities decoded, at most
    /// `maxTitleLength` characters; nil when there's none.
    nonisolated static func title(fromHTML data: Data, textEncodingName: String?) -> String? {
        guard let raw = extractTitle(from: decodeHTML(data, textEncodingName: textEncodingName)) else { return nil }
        let collapsed = HTMLEntities.decode(raw)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxTitleLength else { return collapsed }
        return String(collapsed.prefix(maxTitleLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The header's charset, else UTF-8. UTF-8 is decoded leniently: the byte cap
    /// can cut a multi-byte character, which would otherwise fail the whole page.
    private nonisolated static func decodeHTML(_ data: Data, textEncodingName: String?) -> String {
        if let encoding = stringEncoding(named: textEncodingName), encoding != .utf8,
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func stringEncoding(named name: String?) -> String.Encoding? {
        guard let name else { return nil }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// The text of the first `<title>` element. The search is caseless on `html`
    /// itself: offsets from `html.lowercased()` don't map back (`İ` lowercases to
    /// two scalars).
    nonisolated static func extractTitle(from html: String) -> String? {
        var searchStart = html.startIndex
        while let open = html.range(of: "<title", options: .caseInsensitive, range: searchStart..<html.endIndex) {
            searchStart = open.upperBound
            // `<titlebar>` isn't a title.
            guard let next = html[open.upperBound...].first, next == ">" || next == "/" || next.isWhitespace else { continue }
            guard let tagEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
                  let close = html.range(of: "</title", options: .caseInsensitive, range: tagEnd.upperBound..<html.endIndex) else {
                return nil
            }
            return String(html[tagEnd.upperBound..<close.lowerBound])
        }
        return nil
    }
}
