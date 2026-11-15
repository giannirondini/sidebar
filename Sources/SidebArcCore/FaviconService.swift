import AppKit
import CryptoKit
import os

@MainActor
final class FaviconService {
    static let shared = FaviconService()

    private let store = DataStore()
    private let session: URLSession
    private let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "favicon")
    private let failureCooldown: TimeInterval = 300
    private var cache: [String: NSImage] = [:]
    private var cachedPaths: [String: String] = [:]
    private var inFlight: Set<String> = []
    private var pendingCallbacks: [String: [(NSImage?, String?) -> Void]] = [:]
    private var failureTimestamps: [String: Date] = [:]

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        self.session = URLSession(configuration: config)
    }

    func favicon(for url: URL, cachedPath: String?, completion: @escaping (NSImage?, String?) -> Void) {
        guard let host = url.host else {
            completeAsync(completion, image: nil, path: nil)
            return
        }

        let hostname = host.lowercased()
        if hostname == "localhost" || hostname == "127.0.0.1" {
            completeAsync(completion, image: nil, path: nil)
            return
        }
        let key = hostname + (url.port.map { ":\($0)" } ?? "")

        if let lastFailure = failureTimestamps[key], Date().timeIntervalSince(lastFailure) < failureCooldown {
            logger.debug("Skipping favicon fetch for \(key, privacy: .public) due to cooldown")
            completeAsync(completion, image: nil, path: nil)
            return
        }

        if let image = cache[key] {
            let path = cachedPaths[key]
            completeAsync(completion, image: image, path: path)
            return
        }

        let iconsDir = store.iconsDirectory()
        let fileName = Self.cacheFileName(for: key)
        let fileURL = iconsDir.appendingPathComponent(fileName)

        if let cachedPath, FileManager.default.fileExists(atPath: cachedPath),
           let image = NSImage(contentsOfFile: cachedPath) {
            cache[key] = image
            cachedPaths[key] = cachedPath
            completeAsync(completion, image: image, path: cachedPath)
            return
        }

        if FileManager.default.fileExists(atPath: fileURL.path),
           let image = NSImage(contentsOf: fileURL) {
            cache[key] = image
            cachedPaths[key] = fileURL.path
            completeAsync(completion, image: image, path: fileURL.path)
            return
        }

        if inFlight.contains(key) {
            logger.debug("Queueing callback for in-flight request: \(key, privacy: .public)")
            pendingCallbacks[key, default: []].append(completion)
            return
        }
        inFlight.insert(key)
        logger.debug("Fetching favicon for \(key, privacy: .public)")

        Task {
            let (primaryURL, fallbackURL) = Self.faviconURLs(
                for: url,
                googleFallbackEnabled: Self.googleFallbackEnabled
            )

            let data = await fetchFaviconData(primary: primaryURL, fallback: fallbackURL)
            defer {
                inFlight.remove(key)
                pendingCallbacks.removeValue(forKey: key)
            }

            guard let data, let image = NSImage(data: data) else {
                failureTimestamps[key] = Date()
                logger.debug("Favicon fetch failed for \(key, privacy: .public)")
                completeAsync(completion, image: nil, path: nil)
                // Notify all pending callbacks of the failure
                let callbacks = pendingCallbacks[key] ?? []
                for callback in callbacks {
                    completeAsync(callback, image: nil, path: nil)
                }
                return
            }

            do {
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                logger.debug("Failed to write favicon for \(key, privacy: .public)")
            }

            cache[key] = image
            cachedPaths[key] = fileURL.path
            logger.debug("Favicon fetch succeeded for \(key, privacy: .public)")
            completeAsync(completion, image: image, path: fileURL.path)

            // Notify all pending callbacks of the success
            let callbacks = pendingCallbacks[key] ?? []
            logger.debug("Notifying \(callbacks.count, privacy: .public) pending callbacks for \(key, privacy: .public)")
            for callback in callbacks {
                completeAsync(callback, image: image, path: fileURL.path)
            }
        }
    }

    private func completeAsync(_ completion: @escaping (NSImage?, String?) -> Void, image: NSImage?, path: String?) {
        DispatchQueue.main.async {
            completion(image, path)
        }
    }

    /// A favicon cache file named the pre-1.0 way (`<host>.ico`, `<host>_<port>.ico`)
    /// rather than `cacheFileName`'s SHA-256 hex.
    nonisolated static func isLegacyCacheFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".ico") else { return false }
        let stem = name.dropLast(4)
        return !(stem.count == 64 && stem.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    nonisolated static func cacheFileName(for host: String) -> String {
        SHA256.hash(data: Data(host.lowercased().utf8)).map { String(format: "%02x", $0) }.joined() + ".ico"
    }

    /// The Settings switch; on unless the user turned it off.
    static var googleFallbackEnabled: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKeys.googleFaviconFallbackEnabled) as? Bool ?? true
    }

    /// Hosts that must never be sent to Google: single-label names, local and
    /// private suffixes, and IP literals (Google can't resolve them anyway).
    static func isPrivateHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard name.contains("."), !name.contains(":") else { return true }
        let privateSuffixes = [".local", ".localhost", ".localdomain", ".internal", ".intranet", ".corp",
                               ".lan", ".home", ".home.arpa", ".private", ".test", ".invalid", ".example"]
        if privateSuffixes.contains(where: { name.hasSuffix($0) }) { return true }
        let labels = name.split(separator: ".")
        return labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
    }

    /// The site's own `/favicon.ico`, and Google's service as a fallback only when
    /// enabled and the host is public. Both carry the origin only (no path, query,
    /// fragment or credentials).
    static func faviconURLs(for url: URL, googleFallbackEnabled: Bool) -> (URL?, URL?) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil, var site = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (nil, nil)
        }
        site.user = nil
        site.password = nil
        site.path = ""
        site.query = nil
        site.fragment = nil
        guard let siteURL = site.url else { return (nil, nil) }
        site.path = "/favicon.ico"

        var fallback: URL?
        if googleFallbackEnabled, let host = url.host, !isPrivateHost(host) {
            var components = URLComponents(string: "https://www.google.com/s2/favicons")
            components?.queryItems = [URLQueryItem(name: "sz", value: "64"),
                                      URLQueryItem(name: "domain_url", value: siteURL.absoluteString)]
            fallback = components?.url
        }
        return (site.url, fallback)
    }

    private func fetchFaviconData(primary: URL?, fallback: URL?) async -> Data? {
        if let primary {
            if let data = await fetchData(from: primary) {
                return data
            }
        }
        if let fallback {
            return await fetchData(from: fallback)
        }
        return nil
    }

    private func fetchData(from url: URL) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty {
                return data
            }
        } catch {
            logger.debug("Favicon fetch error for \(url.host ?? "unknown", privacy: .private)")
        }
        return nil
    }
}
