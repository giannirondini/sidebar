import Foundation

/// Decodes the HTML character references found in page titles and bookmark files:
/// decimal and hex numeric references, and the named ones those files use. One
/// pass, so `&amp;lt;` becomes `&lt;`, never `<`. Unknown or malformed references
/// stay as written.
enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "middot": "\u{00B7}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "laquo": "\u{00AB}", "raquo": "\u{00BB}", "bull": "\u{2022}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "euro": "\u{20AC}", "pound": "\u{00A3}",
        "yen": "\u{00A5}", "sect": "\u{00A7}", "deg": "\u{00B0}", "times": "\u{00D7}"
    ]

    /// The longest reference body worth looking at (`#x10FFFF`, `hellip`).
    private static let maxBodyLength = 10

    static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = ""
        result.reserveCapacity(string.utf8.count)
        var index = string.startIndex
        while let ampersand = string[index...].firstIndex(of: "&") {
            result += string[index..<ampersand]
            let bodyStart = string.index(after: ampersand)
            let window = string[bodyStart...].prefix(maxBodyLength + 1)
            if let semicolon = window.firstIndex(of: ";"),
               let decoded = decodeReference(String(string[bodyStart..<semicolon])) {
                result += decoded
                index = string.index(after: semicolon)
            } else {
                result += "&"
                index = bodyStart
            }
        }
        result += string[index...]
        return result
    }

    private static func decodeReference(_ body: String) -> String? {
        guard body.hasPrefix("#") else { return named[body] }
        let digits = body.dropFirst()
        let value: UInt32?
        if let first = digits.first, first == "x" || first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        // NUL and surrogates aren't characters; leave them as written.
        guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }
}
