import AppKit
import Foundation
import Testing
@testable import SidebArcCore

/// Title and favicon fetching with injected fetches: nothing touches the network.
@MainActor
@Suite struct LinkTitleTests {
    private func title(_ html: String) -> String? {
        LinkTitleService.title(fromHTML: Data(html.utf8), textEncodingName: "utf-8")
    }

    @Test func caselessSearchKeepsOffsetsOnTheOriginalText() {
        // "İ" lowercases to two scalars: offsets from html.lowercased() used to
        // cut "lo World Page</t" out of this page.
        let html = "<html><head><meta name=\"x\" content=\"İİİİİİ\"><TITLE>Hello World Page</TITLE></head>"
        #expect(title(html) == "Hello World Page")
    }

    @Test(arguments: [
        ("<title>Plain</title>", "Plain"),
        ("<Title lang=\"en\">  Spaced\n\tout   title </Title>", "Spaced out title"),
        ("<titlebar>Not it</titlebar><title>Real</title>", "Real"),
        ("<title>Tom &amp; Jerry &#8211; &#x27;Cartoons&#x27; &amp;lt;3</title>", "Tom & Jerry – 'Cartoons' &lt;3"),
        ("<title>   </title>", nil),
        ("<title>Never closed", nil),
        ("<h1>No title</h1>", nil)
    ] as [(String, String?)])
    func extractsAndCleansTitles(_ html: String, _ expected: String?) {
        #expect(title(html) == expected)
    }

    @Test func longTitlesAreCut() throws {
        let long = String(repeating: "word ", count: 200)
        let result = try #require(title("<title>\(long)</title>"))
        #expect(result.count == LinkTitleService.maxTitleLength)
        #expect(result.hasSuffix("…"))
    }

    @Test func aMultiByteCharacterCutByTheCapStillDecodes() throws {
        var data = Data("<title>Café</title><p>".utf8)
        data.append(contentsOf: Array("é".utf8).prefix(1))  // half a character
        #expect(LinkTitleService.title(fromHTML: data, textEncodingName: nil) == "Café")
    }

    @Test func theDeclaredCharsetIsUsed() throws {
        let latin1 = try #require("<title>Caf\u{E9}</title>".data(using: .isoLatin1))
        #expect(LinkTitleService.title(fromHTML: latin1, textEncodingName: "iso-8859-1") == "Café")
    }

    @Test func readingStopsAtTheCap() async throws {
        // An endless body: only `limit` bytes may ever be pulled from it.
        let counter = Counter()
        let endless = AsyncStream<UInt8>(unfolding: { counter.increment(); return UInt8(ascii: "a") })
        let data = try await LinkTitleService.readPrefix(of: endless, limit: 1_000)
        #expect(data.count == 1_000)
        #expect(counter.value == 1_000)
    }

    @Test func fetchTitleUsesTheInjectedFetchWithTheCap() async throws {
        let html = "<title>From the stub</title>"
        let recorder = Recorder()
        let service = LinkTitleService { request, limit in
            recorder.record(request.url, limit: limit)
            return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                     headerFields: ["Content-Type": "text/html; charset=utf-8"])!)
        }
        let url = try #require(URL(string: "https://example.com/page"))
        let result = await withCheckedContinuation { continuation in
            service.fetchTitle(for: url, linkId: UUID()) { continuation.resume(returning: $0) }
        }
        #expect(result == "From the stub")
        #expect(recorder.urls == [url])
        #expect(recorder.limits == [LinkTitleService.maxHTMLBytes])
    }

    @Test func atMostFourFetchesRunAtOnceAndAllFinish() async throws {
        let gauge = Gauge()
        let service = LinkTitleService { request, _ in
            gauge.enter()
            try await Task.sleep(for: .milliseconds(30))
            gauge.leave()
            return (Data("<title>\(request.url!.lastPathComponent)</title>".utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let urls = try (0..<10).map { try #require(URL(string: "https://example.com/page\($0)")) }
        let collected = Collected()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            for url in urls {
                service.fetchTitle(for: url, linkId: UUID()) { title in
                    collected.titles.append(title)
                    if collected.titles.count == urls.count { continuation.resume() }
                }
            }
        }
        let titles = collected.titles
        #expect(Set(titles.compactMap { $0 }) == Set((0..<10).map { "page\($0)" }))
        #expect(gauge.peak == LinkTitleService.maxConcurrentFetches)
    }

    @Test func nonSuccessResponsesGiveNoTitle() async throws {
        let service = LinkTitleService { request, _ in
            (Data("<title>Not Found</title>".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let url = try #require(URL(string: "https://example.com/missing"))
        let result = await withCheckedContinuation { continuation in
            service.fetchTitle(for: url, linkId: UUID()) { continuation.resume(returning: $0) }
        }
        #expect(result == nil)
    }
}

@MainActor
@Suite struct FaviconFetchTests {
    private static let png: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }()

    private static let soft404 = Data("<!doctype html><html><head><title>Not found</title></head><body>Oops</body></html>".utf8)

    /// A fetch answering from `answers` by host (first match on `url.absoluteString`
    /// prefix), recording every requested URL.
    private func stub(_ answers: [(prefix: String, status: Int, type: String, body: Data)], recorder: Recorder) -> FaviconService.Fetch {
        { url in
            recorder.record(url, limit: 0)
            guard let answer = answers.first(where: { url.absoluteString.hasPrefix($0.prefix) }) else {
                throw URLError(.cannotConnectToHost)
            }
            let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: nil,
                                           headerFields: ["Content-Type": answer.type])!
            return (answer.body, response)
        }
    }

    @Test func aSoft404PageFallsBackToGoogle() async throws {
        let recorder = Recorder()
        let fetch = stub([("https://example.com/", 200, "text/html", Self.soft404),
                          ("https://www.google.com/", 200, "image/png", Self.png)], recorder: recorder)
        let url = try #require(URL(string: "https://example.com/page"))

        let data = await FaviconService.fetchFaviconData(for: url, googleFallbackEnabled: true, fetch: fetch)

        #expect(data == Self.png)
        #expect(recorder.urls.map { $0?.host } == ["example.com", "www.google.com"])
    }

    @Test func aSoft404OnAPrivateHostIsAFailureAndNeverReachesGoogle() async throws {
        let recorder = Recorder()
        let fetch = stub([("http://nas.local/", 200, "text/html", Self.soft404),
                          ("https://www.google.com/", 200, "image/png", Self.png)], recorder: recorder)
        let url = try #require(URL(string: "http://nas.local/admin"))

        let data = await FaviconService.fetchFaviconData(for: url, googleFallbackEnabled: true, fetch: fetch)

        #expect(data == nil)
        #expect(recorder.urls.map { $0?.host } == ["nas.local"])
    }

    @Test func theSitesOwnIconWinsWithoutAskingGoogle() async throws {
        let recorder = Recorder()
        let fetch = stub([("https://example.com/", 200, "image/x-icon", Self.png)], recorder: recorder)
        let url = try #require(URL(string: "https://example.com/"))

        #expect(await FaviconService.fetchFaviconData(for: url, googleFallbackEnabled: true, fetch: fetch) == Self.png)
        #expect(recorder.urls.count == 1)
    }

    @Test func errorsAndEmptyBodiesFallBackOrFail() async throws {
        let url = try #require(URL(string: "https://example.com/"))

        let notFound = Recorder()
        let fallback = stub([("https://example.com/", 404, "image/png", Self.png),
                             ("https://www.google.com/", 200, "image/png", Self.png)], recorder: notFound)
        #expect(await FaviconService.fetchFaviconData(for: url, googleFallbackEnabled: true, fetch: fallback) == Self.png)

        let empty = Recorder()
        let nothing = stub([("https://example.com/", 200, "image/png", Data()),
                            ("https://www.google.com/", 200, "text/html", Self.soft404)], recorder: empty)
        #expect(await FaviconService.fetchFaviconData(for: url, googleFallbackEnabled: true, fetch: nothing) == nil)
        #expect(empty.urls.count == 2)

        let offline = Recorder()
        let unreachable = stub([], recorder: offline)
        #expect(await FaviconService.fetchFaviconData(for: url, googleFallbackEnabled: false, fetch: unreachable) == nil)
        #expect(offline.urls.count == 1)
    }

    @Test func onlyDecodableImagesCount() {
        #expect(FaviconService.isDecodableImage(Self.png))
        #expect(!FaviconService.isDecodableImage(Self.soft404))
        #expect(!FaviconService.isDecodableImage(Data("not an image".utf8)))
        #expect(!FaviconService.isDecodableImage(Data()))
    }
}

/// Thread-safe call recorders for `@Sendable` stubs.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL?] = []
    private var _limits: [Int] = []

    func record(_ url: URL?, limit: Int) {
        lock.withLock {
            _urls.append(url)
            _limits.append(limit)
        }
    }

    var urls: [URL?] { lock.withLock { _urls } }
    var limits: [Int] { lock.withLock { _limits } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    func increment() { lock.withLock { _value += 1 } }
    var value: Int { lock.withLock { _value } }
}

/// The most concurrent callers seen between `enter` and `leave`.
final class Gauge: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var _peak = 0

    func enter() { lock.withLock { current += 1; _peak = max(_peak, current) } }
    func leave() { lock.withLock { current -= 1 } }
    var peak: Int { lock.withLock { _peak } }
}

@MainActor
final class Collected {
    var titles: [String?] = []
}
