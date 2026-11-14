import Foundation

/// Conservative URL identity used to deduplicate favorites.
///
/// Two URLs share a key when they differ only in: scheme/host case, an explicit
/// default port (80 for http, 443 for https), the fragment, or a single trailing
/// `/` on the path. The query is kept and `www.` is **not** stripped, since both
/// can change which page is served.
enum URLNormalization {
    static func key(for urlString: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            return trimmed
        }
        components.scheme = scheme
        components.host = components.host?.lowercased()
        if let port = components.port,
           (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            components.port = nil
        }
        components.fragment = nil
        if components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? trimmed
    }
}
