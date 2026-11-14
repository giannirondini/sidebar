import Foundation

/// Decides whether an open browser tab shows a sidebar link, for focusing that tab
/// instead of opening a duplicate (`TabFocus`).
///
/// Both modes need the same scheme, host (case-insensitive) and port (an explicit
/// default port is dropped). The fragment is always ignored.
/// - **Prefix** (default): the tab's path is the link's path or below it, on a
///   segment boundary (`/docs` matches `/docs/a`, not `/docs2`); a trailing `/` is
///   ignored, so a link to the site root matches every page on that host. Every
///   query item of the link must be in the tab's query; the tab may have more
///   (`watch?v=abc` matches `watch?v=abc&t=10`, not `watch?v=xyz`).
/// - **Exact** (`Link.exactTabMatch`): same path and the same query items, in any order.
///
/// `www.` and http/https are **not** treated as equal: they can serve different
/// pages, and a weaker match must never focus a tab. This is separate from
/// `URLNormalization` (favorites dedupe), whose rules stay as they are.
enum TabURLMatcher {
    /// How close `tab` is to `item`: 0 = same page (path and query), higher =
    /// further (extra query items, then each extra path segment). nil = no match.
    static func distance(item: String, tab: String, exact: Bool) -> Int? {
        guard let item = Parts(item), let tab = Parts(tab),
              item.scheme == tab.scheme, item.host == tab.host, item.port == tab.port else {
            return nil
        }
        let samePath = item.segments == tab.segments
        let sameQuery = item.query == tab.query
        if samePath && sameQuery { return 0 }
        if exact { return nil }
        guard tab.segments.starts(with: item.segments), isSubset(item.query, of: tab.query) else {
            return nil
        }
        return 1 + tab.segments.count - item.segments.count
    }

    /// Index of the candidate URL closest to `item`, or nil when none matches.
    /// `candidates` are in preference order (front window first, then tab order);
    /// ties go to the earliest.
    static func bestMatch(item: String, exact: Bool, candidates: [String]) -> Int? {
        var best: (index: Int, distance: Int)?
        for (index, candidate) in candidates.enumerated() {
            guard let distance = distance(item: item, tab: candidate, exact: exact) else { continue }
            if best == nil || distance < best!.distance {
                best = (index, distance)
                if distance == 0 { break }
            }
        }
        return best?.index
    }

    /// The parts of a URL that matching compares.
    private struct Parts {
        let scheme: String
        let host: String
        let port: Int?
        /// Path segments; empty segments (a trailing `/`) are dropped.
        let segments: [String]
        /// `name=value` per query item, sorted.
        let query: [String]

        init?(_ string: String) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: trimmed),
                  let scheme = components.scheme?.lowercased(),
                  let host = components.host?.lowercased(), !host.isEmpty else {
                return nil
            }
            self.scheme = scheme
            self.host = host
            let defaultPort = ["http": 80, "https": 443][scheme]
            self.port = components.port == defaultPort ? nil : components.port
            self.segments = components.path.split(separator: "/").map(String.init)
            self.query = (components.queryItems ?? [])
                .map { "\($0.name)=\($0.value ?? "")" }
                .sorted()
        }
    }

    /// Multiset inclusion of two sorted arrays (repeated query items count).
    private static func isSubset(_ small: [String], of large: [String]) -> Bool {
        var counts: [String: Int] = [:]
        for item in large { counts[item, default: 0] += 1 }
        for item in small {
            guard let count = counts[item], count > 0 else { return false }
            counts[item] = count - 1
        }
        return true
    }
}
