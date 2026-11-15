import Foundation
import Testing
@testable import SidebArcCore

/// Entity decoding (page titles, bookmark files) and the URL clean-up applied to
/// imported links. Every expectation is on strings, so the result is the same on
/// macOS 13 (strict `URL(string:)`) and later (lenient).
@Suite struct ImportedURLTests {
    @Test(arguments: [
        ("Tom &amp; Jerry", "Tom & Jerry"),
        ("a=1&amp;b=2", "a=1&b=2"),
        ("&lt;b&gt; &quot;q&quot; &apos;s&apos; &#39;n&#39;", "<b> \"q\" 's' 'n'"),
        ("caf&#233; &#xE9; &#XE9;", "café é é"),
        ("dash &ndash; &mdash; &hellip;", "dash – — …"),
        ("&amp;lt; stays one level", "&lt; stays one level"),
        ("AT&T & co; &unknown; &#0; &#xD800; &", "AT&T & co; &unknown; &#0; &#xD800; &"),
        ("&#128512;", "😀"),
        ("no entities", "no entities")
    ])
    func decodesHTMLEntities(_ input: String, _ expected: String) {
        #expect(HTMLEntities.decode(input) == expected)
    }

    @Test(arguments: [
        ("https://example.com/a b?q=c d#e f", "https://example.com/a%20b?q=c%20d#e%20f"),
        ("https://example.com/already%20encoded?a=1&b=2", "https://example.com/already%20encoded?a=1&b=2"),
        ("https://example.com/x|y\"z<w>{}^`", "https://example.com/x%7Cy%22z%3Cw%3E%7B%7D%5E%60"),
        ("https://de.example.org/wiki/Straße", "https://de.example.org/wiki/Stra%C3%9Fe"),
        ("  https://example.com/trimmed  ", "https://example.com/trimmed"),
        ("mailto:someone@example.com?subject=Hello there", "mailto:someone@example.com?subject=Hello%20there"),
        ("file:///Users/me/My Documents/a.pdf", "file:///Users/me/My%20Documents/a.pdf"),
        ("--renderer-cmd-prefix=/tmp/x", "--renderer-cmd-prefix=/tmp/x"),
        ("https://example.com/list?filter[a]=1", "https://example.com/list?filter%5Ba%5D=1"),
        ("https://example.com/100%off?x=%zz&y=%4", "https://example.com/100%25off?x=%25zz&y=%254"),
        ("https://example.com/a#one#two", "https://example.com/a#one%23two"),
        ("https://[2001:db8::1]:8080/p q", "https://[2001:db8::1]:8080/p%20q")
    ])
    func importedURLsAreEncodedBeforeParsing(_ input: String, _ expected: String) {
        #expect(ImportedURL.normalized(input) == expected)
    }

    @Test func emptyURLsAndInvalidHostsAreSkipped() {
        #expect(ImportedURL.normalized("") == nil)
        #expect(ImportedURL.normalized("   ") == nil)
        #expect(ImportedURL.normalized("https://exa mple.com/") == nil)
        #expect(ImportedURL.normalized("https://exa\"mple.com/") == nil)
    }

    /// Whatever goes in, what follows the host is valid RFC 3986 as a string: only
    /// unreserved and reserved characters, every `%` starting an `%XX` escape, at most
    /// one `#`, no `[` `]`. A strict parser (macOS 13) and a lenient one (later) then
    /// read the same URL, without having to run on macOS 13 to know it.
    @Test(arguments: [
        "https://example.com/a b/ç/日本?q=\"x\"&r=<y>|{z}^`\\ #f g#h",
        "https://example.com/%%41%4%G1%e9%E9%",
        "https://example.com/[]?[a]=[b]#[c]",
        "mailto:a b@example.com?subject=Ça va",
        "relative path/with spaces?and=%",
        "file:///Users/me/a%20b c/%zz.pdf"
    ])
    func encodedTailIsValidRFC3986(_ input: String) throws {
        let output = ImportedURL.percentEncodingAfterAuthority(input)
        var tail = Substring(output)
        if let schemeEnd = output.range(of: "://") {
            tail = output[schemeEnd.upperBound...].drop { !"/?#".contains($0) }
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?#%")
        #expect(tail.allSatisfy { allowed.contains($0) }, "\(output)")
        #expect(tail.filter { $0 == "#" }.count <= 1, "\(output)")
        let characters = Array(tail)
        for (index, character) in characters.enumerated() where character == "%" {
            let isEscape = index + 2 < characters.count
                && characters[index + 1].isHexDigit && characters[index + 2].isHexDigit
            #expect(isEscape, "lone % at \(index) in \(output)")
        }
    }

    @Test func theHostIsNeverPercentEncoded() {
        // A non-ASCII host needs IDNA; percent-encoding it would point elsewhere.
        #expect(ImportedURL.percentEncodingAfterAuthority("https://bücher.example/ä ö")
                == "https://bücher.example/%C3%A4%20%C3%B6")
        #expect(ImportedURL.percentEncodingAfterAuthority("https://user@host.example:8443?q=a b")
                == "https://user@host.example:8443?q=a%20b")
    }
}
