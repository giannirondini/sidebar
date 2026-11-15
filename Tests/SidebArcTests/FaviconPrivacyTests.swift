import Foundation
import Testing
@testable import SidebArcCore

@MainActor
@Suite struct FaviconPrivacyTests {
    @Test(arguments: [
        "http://nas.local/page",
        "https://192.168.1.1/page",
        "https://wiki.corp.internal/page",
        "https://example.com/page"
    ])
    func fallbackRequiresOptIn(_ input: String) throws {
        let url = try #require(URL(string: input))
        let (primary, fallback) = FaviconService.faviconURLs(for: url, googleFallbackEnabled: false)
        #expect(primary?.path == "/favicon.ico")
        #expect(fallback == nil)
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
