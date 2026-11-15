import Foundation
import Testing
@testable import SidebArcCore

@MainActor
@Suite struct FaviconPrivacyTests {
    @Test(arguments: [
        "http://nas.local/page",
        "https://192.168.1.1/page",
        "https://8.8.8.8/page",
        "http://[::1]:8080/page",
        "http://[fd00::1]/page",
        "https://wiki.corp.internal/page",
        "http://router/page",
        "http://printer.lan/",
        "http://box.home.arpa/"
    ])
    func privateHostsAreNeverSentToGoogle(_ input: String) throws {
        let url = try #require(URL(string: input))
        let (primary, fallback) = FaviconService.faviconURLs(for: url, googleFallbackEnabled: true)
        #expect(primary?.path == "/favicon.ico")
        #expect(fallback == nil)
    }

    @Test func publicHostsUseTheFallbackUnlessTurnedOff() throws {
        let url = try #require(URL(string: "https://news.example.co.uk/page"))
        #expect(FaviconService.faviconURLs(for: url, googleFallbackEnabled: true).1 != nil)
        #expect(FaviconService.faviconURLs(for: url, googleFallbackEnabled: false).1 == nil)
    }

    @Test func fallbackContainsOnlyTheSiteOrigin() throws {
        let url = try #require(URL(string: "https://user:password@example.com:8443/path?token=secret#fragment"))
        let (primary, fallback) = FaviconService.faviconURLs(for: url, googleFallbackEnabled: true)
        #expect(primary?.absoluteString == "https://example.com:8443/favicon.ico")
        let components = try #require(fallback.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        #expect(components.host == "www.google.com")
        #expect(components.queryItems?.first(where: { $0.name == "domain_url" })?.value == "https://example.com:8443")
    }

    @Test func cacheNamesCannotEscapeIconsDirectory() throws {
        let url = try #require(URL(string: "https://..%2F..%2Fescaped/p"))
        let host = try #require(url.host)
        let name = FaviconService.cacheFileName(for: host)
        let icons = URL(fileURLWithPath: "/tmp/Icons", isDirectory: true)
        #expect(icons.appendingPathComponent(name).standardizedFileURL.deletingLastPathComponent() == icons)
        #expect(name.hasSuffix(".ico"))
        #expect(name.count == 68)
        #expect(!name.contains("/"))
        #expect(name != FaviconService.cacheFileName(for: "escaped"))
        #expect(FaviconService.cacheFileName(for: "EXAMPLE.COM") == FaviconService.cacheFileName(for: "example.com"))
        #expect(FaviconService.cacheFileName(for: "example.com:8443") != FaviconService.cacheFileName(for: "example.com:9443"))
    }
}
