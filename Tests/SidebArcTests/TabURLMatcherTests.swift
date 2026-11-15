import Testing
@testable import SidebArcCore

/// `TabURLMatcher`: which open tab a sidebar link may focus (plan-v2 2.3, 2.7).
@Suite struct TabURLMatcherTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let item: String
        let tab: String
        let prefix: Bool
        let exact: Bool
        let note: String
        var testDescription: String { note }
    }

    static let cases: [Case] = [
        // Host
        Case(item: "https://example.com/a", tab: "https://example.com/a", prefix: true, exact: true, note: "same URL"),
        Case(item: "https://Example.COM/a", tab: "https://example.com/a", prefix: true, exact: true, note: "host case"),
        Case(item: "https://example.com/a", tab: "https://other.com/a", prefix: false, exact: false, note: "other host"),
        Case(item: "https://example.com/", tab: "https://sub.example.com/", prefix: false, exact: false, note: "subdomain"),
        Case(item: "https://example.com/", tab: "https://www.example.com/", prefix: false, exact: false, note: "www. is not equal"),
        Case(item: "https://www.example.com/", tab: "https://example.com/", prefix: false, exact: false, note: "www. is not equal (reverse)"),
        // Scheme and port
        Case(item: "http://example.com/", tab: "https://example.com/", prefix: false, exact: false, note: "http vs https"),
        Case(item: "HTTPS://example.com/a", tab: "https://example.com/a", prefix: true, exact: true, note: "scheme case"),
        Case(item: "https://example.com:443/a", tab: "https://example.com/a", prefix: true, exact: true, note: "default port"),
        Case(item: "https://example.com:8443/a", tab: "https://example.com/a", prefix: false, exact: false, note: "other port"),
        Case(item: "http://localhost:3000/", tab: "http://localhost:3000/app", prefix: true, exact: false, note: "localhost with port"),
        // Path prefix
        Case(item: "https://example.com", tab: "https://example.com/any/page", prefix: true, exact: false, note: "root matches the host"),
        Case(item: "https://example.com/docs", tab: "https://example.com/docs/a/b", prefix: true, exact: false, note: "below the path"),
        Case(item: "https://example.com/docs", tab: "https://example.com/docs2", prefix: false, exact: false, note: "segment boundary"),
        Case(item: "https://example.com/docs/a", tab: "https://example.com/docs", prefix: false, exact: false, note: "tab above the path"),
        Case(item: "https://example.com/Docs", tab: "https://example.com/docs", prefix: false, exact: false, note: "path is case-sensitive"),
        // Trailing slash
        Case(item: "https://example.com/docs/", tab: "https://example.com/docs", prefix: true, exact: true, note: "trailing slash on item"),
        Case(item: "https://example.com/docs", tab: "https://example.com/docs/", prefix: true, exact: true, note: "trailing slash on tab"),
        Case(item: "https://example.com/docs//", tab: "https://example.com/docs/", prefix: false, exact: false, note: "only one trailing slash is ignored"),
        Case(item: "https://example.com/docs/", tab: "https://example.com/docs//", prefix: true, exact: false, note: "double trailing slash is below the path"),
        // Path encoding and empty segments
        Case(item: "https://example.com/a%2Fb", tab: "https://example.com/a/b", prefix: false, exact: false, note: "encoded slash is not a separator"),
        Case(item: "https://example.com/a/b", tab: "https://example.com/a%2Fb", prefix: false, exact: false, note: "encoded slash is not a separator (reverse)"),
        Case(item: "https://example.com/a//b", tab: "https://example.com/a/b", prefix: false, exact: false, note: "internal empty segment counts"),
        Case(item: "https://example.com/a/b", tab: "https://example.com/a//b", prefix: false, exact: false, note: "internal empty segment counts (reverse)"),
        Case(item: "https://example.com/a%7e", tab: "https://example.com/a~", prefix: true, exact: true, note: "encoded and literal character"),
        Case(item: "https://example.com/a%7E", tab: "https://example.com/a%7e", prefix: true, exact: true, note: "percent-encoding hex case"),
        // Query
        Case(item: "https://youtube.com/watch?v=abc", tab: "https://youtube.com/watch?v=abc&t=10", prefix: true, exact: false, note: "tab has extra query"),
        Case(item: "https://youtube.com/watch?v=abc", tab: "https://youtube.com/watch?v=xyz", prefix: false, exact: false, note: "different query value"),
        Case(item: "https://youtube.com/watch?v=abc", tab: "https://youtube.com/watch", prefix: false, exact: false, note: "tab misses the query"),
        Case(item: "https://example.com/s?a=1&b=2", tab: "https://example.com/s?b=2&a=1", prefix: true, exact: true, note: "query order"),
        Case(item: "https://example.com/docs", tab: "https://example.com/docs?tab=t.0", prefix: true, exact: false, note: "item without query"),
        Case(item: "https://example.com/s?a=1&a=1", tab: "https://example.com/s?a=1", prefix: false, exact: false, note: "repeated query item"),
        Case(item: "https://example.com/s?a=1", tab: "https://example.com/s?a=1&a=1", prefix: true, exact: false, note: "tab repeats the query item"),
        Case(item: "https://example.com/s?flag", tab: "https://example.com/s?flag=", prefix: false, exact: false, note: "no value is not an empty value"),
        Case(item: "https://example.com/s?flag=", tab: "https://example.com/s?flag", prefix: false, exact: false, note: "empty value is not no value"),
        Case(item: "https://example.com/s?a%3Db=c", tab: "https://example.com/s?a=b%3Dc", prefix: false, exact: false, note: "encoded = in name vs value"),
        Case(item: "https://example.com/s?a=b%3Dc", tab: "https://example.com/s?a%3Db=c", prefix: false, exact: false, note: "encoded = in value vs name"),
        Case(item: "https://example.com/s?q=%7e", tab: "https://example.com/s?q=~", prefix: true, exact: true, note: "query percent-encoding"),
        // Fragment
        Case(item: "https://example.com/a#one", tab: "https://example.com/a#two", prefix: true, exact: true, note: "fragment ignored"),
        Case(item: "https://mail.google.com/mail/u/0/", tab: "https://mail.google.com/mail/u/0/#inbox", prefix: true, exact: true, note: "mail with fragment"),
        // Not web pages
        Case(item: "mailto:a@b.com", tab: "mailto:a@b.com", prefix: false, exact: false, note: "no host"),
        Case(item: "not a url", tab: "not a url", prefix: false, exact: false, note: "garbage"),
        Case(item: "https://example.com/", tab: "", prefix: false, exact: false, note: "empty tab URL"),
    ]

    @Test(arguments: cases)
    func prefixMode(_ c: Case) {
        #expect((TabURLMatcher.distance(item: c.item, tab: c.tab, exact: false) != nil) == c.prefix)
    }

    @Test(arguments: cases)
    func exactMode(_ c: Case) {
        #expect((TabURLMatcher.distance(item: c.item, tab: c.tab, exact: true) != nil) == c.exact)
    }

    @Test func distanceRanksSamePageFirstThenExtraQueryThenDepth() throws {
        let item = "https://example.com/docs"
        let same = try #require(TabURLMatcher.distance(item: item, tab: "https://example.com/docs/", exact: false))
        let query = try #require(TabURLMatcher.distance(item: item, tab: "https://example.com/docs?x=1", exact: false))
        let deeper = try #require(TabURLMatcher.distance(item: item, tab: "https://example.com/docs/a", exact: false))
        let deepest = try #require(TabURLMatcher.distance(item: item, tab: "https://example.com/docs/a/b", exact: false))
        #expect(same == 0)
        #expect(same < query)
        #expect(query < deeper)
        #expect(deeper < deepest)
    }

    @Test func bestMatchPrefersClosestThenEarliest() {
        let item = "https://example.com/docs"
        let tabs = [
            "https://other.com/docs",
            "https://example.com/docs/a/b",
            "https://example.com/docs/a",   // closest, earliest of its kind
            "https://example.com/docs/b",
        ]
        #expect(TabURLMatcher.bestMatch(item: item, exact: false, candidates: tabs) == 2)

        let withSamePage = tabs + ["https://example.com/docs#x"]
        #expect(TabURLMatcher.bestMatch(item: item, exact: false, candidates: withSamePage) == 4)
        #expect(TabURLMatcher.bestMatch(item: item, exact: true, candidates: tabs) == nil)
        #expect(TabURLMatcher.bestMatch(item: item, exact: false, candidates: []) == nil)
    }
}
