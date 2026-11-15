import Foundation

/// A URL string from an imported file (Chrome/Firefox bookmarks HTML, Arc's
/// sidebar), ready to store. `URL(string:)` is strict on macOS 13 and lenient from
/// macOS 14, so anything one would reject and the other repair is fixed here, as
/// plain string work, before parsing: after the scheme and host, every character
/// outside RFC 3986's unreserved and reserved sets is percent-encoded (spaces, `"`,
/// `<`, `|`, `[`, non-ASCII text, …), a `%` that doesn't start an `%XX` escape
/// becomes `%25`, and a second `#` becomes `%23`. Existing escapes are kept. The
/// host is left alone (a non-ASCII host needs IDNA, not percent-encoding); one
/// with a space or other invalid ASCII is refused.
enum ImportedURL {
    /// What may follow the authority as written: unreserved, sub-delims, `:@/?`.
    /// `%` and `#` are handled on their own; `[` `]` only belong in a host.
    private static let allowedAfterAuthority = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?")

    /// What an authority may hold in ASCII (`user:pass@host:port`, `[v6]`, `%XX`).
    private static let allowedInAuthority = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@[]%")

    /// The encoded string when it parses as a URL, else nil. A relative string is
    /// kept too (imports never drop links; `BrowserManager.validatedLinkURL` refuses
    /// to open it).
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let (head, rest) = splitAfterAuthority(trimmed)
        if let authorityStart = head.range(of: "://")?.upperBound {
            let invalidASCII = head[authorityStart...].unicodeScalars.contains {
                $0.isASCII && !allowedInAuthority.contains($0)
            }
            guard !invalidASCII else { return nil }
        }
        let encoded = head + encode(rest)
        return URL(string: encoded) == nil ? nil : encoded
    }

    /// `string` with everything after the scheme and authority encoded as
    /// `normalized` does. Doesn't parse or validate anything.
    static func percentEncodingAfterAuthority(_ string: String) -> String {
        let (head, rest) = splitAfterAuthority(string)
        return head + encode(rest)
    }

    /// `scheme://authority` and the rest; for a string without `://` (`mailto:`, a
    /// relative string) everything is the rest.
    private static func splitAfterAuthority(_ string: String) -> (String, Substring) {
        guard let schemeEnd = string.range(of: "://") else { return ("", string[...]) }
        let split = string[schemeEnd.upperBound...].firstIndex(where: { "/?#".contains($0) }) ?? string.endIndex
        return (String(string[..<split]), string[split...])
    }

    private static func encode(_ rest: Substring) -> String {
        let scalars = Array(rest.unicodeScalars)
        var output = String.UnicodeScalarView()
        var seenFragment = false
        func append(_ text: String) { output.append(contentsOf: text.unicodeScalars) }
        for (index, scalar) in scalars.enumerated() {
            switch scalar {
            case "%":
                let isEscape = index + 2 < scalars.count
                    && isHexDigit(scalars[index + 1]) && isHexDigit(scalars[index + 2])
                append(isEscape ? "%" : "%25")
            case "#":
                append(seenFragment ? "%23" : "#")
                seenFragment = true
            case _ where allowedAfterAuthority.contains(scalar):
                output.append(scalar)
            default:
                for byte in String(scalar).utf8 {
                    append(String(format: "%%%02X", byte))
                }
            }
        }
        return String(output)
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && Character(scalar).isHexDigit
    }
}
