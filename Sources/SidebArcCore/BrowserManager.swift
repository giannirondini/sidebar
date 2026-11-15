import AppKit
import os
import UniformTypeIdentifiers

struct BrowserInfo: Equatable {
    let bundleId: String
    let name: String
    let icon: NSImage?
}

struct BrowserProfile: Equatable {
    let id: String          // Profile directory name (Chromium `--profile-directory`)
    let displayName: String // Human-readable name
}

/// Where a link opens: a browser (nil = system default handler) and an optional
/// browser profile directory for it.
struct BrowserTarget: Equatable {
    let bundleId: String?
    let profileDir: String?
}

enum BrowserManager {
    // MARK: - Resolution

    /// Resolves where `link` opens for a space in `profile`.
    ///
    /// Browser precedence: **link override → profile's browser → global default**.
    /// A configured app that isn't an installed browser is skipped, so the next
    /// level applies (an unavailable global default ends at the system handler in `open`).
    /// The profile directory is `profile.browserProfiles[browser]` when the browser
    /// is the profile's own; a per-link override to a *different* browser opens
    /// without a browser profile.
    static func resolveTarget(
        link: Link?,
        profile: Profile,
        globalDefault: String? = resolveDefaultBrowserBundleId(),
        installed: (String) -> Bool = { BrowserManager.isBrowser(bundleId: $0) }
    ) -> BrowserTarget {
        func available(_ id: String?) -> String? {
            guard let id, installed(id) else { return nil }
            return id
        }
        let profileBrowser = available(profile.browserBundleId) ?? globalDefault
        let browser = available(link?.browserBundleId) ?? profileBrowser
        guard let browser else { return BrowserTarget(bundleId: nil, profileDir: nil) }

        // Bundle ids are case-insensitive; look the dir up under the profile's spelling,
        // which is the key `browserProfiles` was written with.
        guard let profileBrowser, profileBrowser.caseInsensitiveCompare(browser) == .orderedSame else {
            return BrowserTarget(bundleId: browser, profileDir: nil)
        }
        return BrowserTarget(bundleId: browser, profileDir: profile.browserProfiles[profileBrowser])
    }

    /// Opens `link` where `resolveTarget` says. Notes use `resolveTarget(link: nil, profile:)`.
    static func open(link: Link, in profile: Profile) {
        guard let url = validatedLinkURL(from: link.url) else {
            NSSound.beep()
            return
        }
        open(url: url, target: resolveTarget(link: link, profile: profile))
    }

    /// Schemes a link may never use: they run code in a page or address browser
    /// internals. Links with them are kept (imports never drop links) but never opened.
    static let blockedLinkSchemes: Set<String> = [
        "javascript", "vbscript", "data", "blob", "about", "view-source",
        "chrome", "chrome-extension", "edge", "brave", "opera", "vivaldi", "arc",
        // Open Terminal with attacker-shaped arguments (past command-injection bugs).
        "x-man-page", "telnet"
    ]

    /// A link's URL when it may be stored and opened: an absolute URL with a scheme
    /// (never a relative string, which Chromium could read as a `--switch`), not in
    /// `blockedLinkSchemes`. Web URLs need a host, `file:` URLs a path; any other
    /// scheme (`mailto:`, `obsidian://`, …) is handed to the system, never to a
    /// browser's command line (`open(url:target:)`).
    static func validatedLinkURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              !blockedLinkSchemes.contains(scheme),
              let url = components.url else { return nil }
        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty else { return nil }
        case "file":
            guard !components.path.isEmpty, components.path != "/" else { return nil }
        default:
            // Something after "scheme:".
            guard trimmed.count > scheme.count + 1 else { return nil }
        }
        return url
    }

    /// A URL the user typed (New Link…, Edit URL…): like `validatedLinkURL`, but a
    /// bare host gets a scheme: `example.com/x` → `https://example.com/x`,
    /// `localhost:3000` → `http://localhost:3000`. `name.example:8080` is a host and
    /// port, not a scheme (a "scheme" with a dot, or `localhost`, is read as a host).
    static func typedLinkURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if trimmed.contains("://") { return validatedLinkURL(from: trimmed) }
        let beforeColon = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? trimmed
        let lowerHost = beforeColon.split(separator: "/").first.map { $0.lowercased() } ?? ""
        let looksLikeHost = lowerHost == "localhost" || lowerHost.contains(".")
        if trimmed.contains(":"), !looksLikeHost {
            return validatedLinkURL(from: trimmed)  // mailto:, tel:, …
        }
        guard looksLikeHost else { return nil }
        // Local servers rarely have TLS: plain http for localhost and IPv4 addresses.
        let isIPv4 = lowerHost.split(separator: ".").count == 4
            && lowerHost.split(separator: ".").allSatisfy { UInt8($0.split(separator: ":").first ?? "") != nil }
        let scheme = lowerHost == "localhost" || isIPv4 ? "http" : "https"
        return validatedLinkURL(from: "\(scheme)://\(trimmed)")
    }

    /// http/https with a host: the only URLs that go to a browser (and its argv).
    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return false }
        return true
    }

    /// Opens a non-web link with the system handler (Mail, Obsidian, Finder, …).
    /// A `file:` URL to something that would run (an app, a script, an executable)
    /// is revealed in Finder instead, so a planted link can't launch code in one click.
    static func openOutsideBrowser(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), !blockedLinkSchemes.contains(scheme) else {
            NSSound.beep()
            return
        }
        if url.isFileURL, revealsInsteadOfOpening(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        if !NSWorkspace.shared.open(url) {
            logger.notice("No app opened a \(scheme, privacy: .public): link")
            NSSound.beep()
        }
    }

    /// Files that launch something when opened: apps and scripts, plus documents
    /// that run a command or open another file or URL (Terminal settings, Finder
    /// location files, Automator, installers).
    static let runnableFileExtensions: Set<String> = [
        "app", "command", "tool", "sh", "bash", "zsh", "csh", "ksh", "tcsh", "fish",
        "py", "rb", "pl", "php", "js", "scpt", "scptd", "applescript", "workflow", "action",
        "terminal", "fileloc", "inetloc", "webloc", "url", "jar", "pkg", "mpkg",
        "prefpane", "saver", "osax", "kext", "plugin", "shortcut", "service"
    ]

    /// Whether opening this file would run code rather than show a document. An
    /// alias or symlink counts as its target too (either being runnable is enough).
    static func revealsInsteadOfOpening(_ fileURL: URL) -> Bool {
        let resolved = ((try? URL(resolvingAliasFileAt: fileURL)) ?? fileURL).resolvingSymlinksInPath()
        return isRunnableFile(fileURL) || isRunnableFile(resolved)
    }

    private static func isRunnableFile(_ url: URL) -> Bool {
        if runnableFileExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isExecutableKey, .isAliasFileKey]) else {
            return false  // Missing: `open` fails and beeps.
        }
        if values.isAliasFile == true { return true }  // An alias that didn't resolve.
        if let type = values.contentType,
           [UTType.application, .applicationBundle, .executable, .unixExecutable, .script, .shellScript]
               .contains(where: { type.conforms(to: $0) }) {
            return true
        }
        return values.isDirectory != true && values.isExecutable == true
    }

    static func installedBrowsers() -> [BrowserInfo] {
        guard let probeURL = URL(string: "http://example.com") else { return [] }
        let urls = NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
        var seen: Set<String> = []
        return urls.compactMap { url in
            guard let bundle = Bundle(url: url) else { return nil }
            guard let bundleId = bundle.bundleIdentifier else { return nil }
            if seen.contains(bundleId) { return nil }
            seen.insert(bundleId)
            let name = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? bundleId
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return BrowserInfo(bundleId: bundleId, name: name, icon: icon)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func isInstalled(bundleId: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    /// Whether `bundleId` is an installed app registered for http(s). Called on every
    /// click and row badge, so the set of ids (not the icons) is cached briefly.
    static func isBrowser(bundleId: String) -> Bool {
        browserIdCache.ids().contains(bundleId.lowercased())
    }

    private static let browserIdCache = BrowserIdCache()

    /// Lowercased bundle ids of the http handlers, refreshed after `ttl`
    /// (installing or removing a browser is rare).
    private final class BrowserIdCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: (ids: Set<String>, at: Date)?
        private let ttl: TimeInterval = 10

        func ids(now: Date = Date()) -> Set<String> {
            lock.lock()
            defer { lock.unlock() }
            if let cached, now.timeIntervalSince(cached.at) < ttl { return cached.ids }
            guard let probeURL = URL(string: "http://example.com") else { return [] }
            let ids = Set(NSWorkspace.shared.urlsForApplications(toOpen: probeURL).compactMap {
                Bundle(url: $0)?.bundleIdentifier?.lowercased()
            })
            cached = (ids, now)
            return ids
        }
    }

    /// Display name of an installed app, or nil when it isn't installed.
    static func appName(bundleId: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let bundle = Bundle(url: url)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    nonisolated(unsafe) private static var iconCache: [String: NSImage] = [:]

    /// App icon of an installed browser (cached), or nil when it isn't installed.
    static func appIcon(bundleId: String) -> NSImage? {
        if let cached = iconCache[bundleId] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleId] = icon
        return icon
    }

    /// Badge for a link's browser override: the browser's icon, or a warning
    /// symbol when that browser isn't available (the link then falls back, see
    /// `resolveTarget`). nil when there is no override.
    static func overrideBadge(for bundleId: String?) -> NSImage? {
        guard let bundleId else { return nil }
        if isBrowser(bundleId: bundleId), let icon = appIcon(bundleId: bundleId) { return icon }
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Browser not available")?
            .withSymbolConfiguration(config)
    }

    static func defaultBrowserBundleId() -> String? {
        guard let probeURL = URL(string: "http://example.com") else { return nil }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else { return nil }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    static func resolveDefaultBrowserBundleId() -> String? {
        if let stored = UserDefaults.standard.string(forKey: UserDefaultsKeys.defaultBrowserBundleId) {
            return stored
        }
        return defaultBrowserBundleId()
    }

    static func open(url: URL, target: BrowserTarget) {
        guard isWebURL(url) else {
            openOutsideBrowser(url)
            return
        }
        guard let bundleId = target.bundleId,
              isBrowser(bundleId: bundleId),
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            NSWorkspace.shared.open(url)
            return
        }

        guard let arguments = launchArguments(url: url, target: target) else {
            // No browser profile: hand the URL to the browser through LaunchServices.
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    logger.error("Opening a link in \(bundleId, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            return
        }

        // With a browser profile: launch a new instance through LaunchServices with the
        // profile switch and the URL as arguments (like `open -na Browser --args …`).
        // - Browser closed: that instance is the browser, started in the right profile.
        // - Browser running: Chromium hands the URL to the running instance and exits.
        // Never spawn the executable as our child process: macOS then attributes its
        // privacy checks to SidebArc, which can't read the browser's data folder
        // (macOS 27 app-data protection), and a closed Chrome exits at once (status 21)
        // without a window, a crash report or a log line.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = arguments
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                logger.error("Launching \(bundleId, privacy: .public) with a browser profile failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Command-line arguments for opening `url` in `target`'s browser profile, or nil
    /// when the URL should simply be handed to the browser (no profile, or a browser
    /// without profile support).
    static func launchArguments(url: URL, target: BrowserTarget) -> [String]? {
        guard isWebURL(url) else { return nil }
        guard let bundleId = target.bundleId,
              let profile = target.profileDir, !profile.isEmpty else { return nil }
        let profileArgs = profileArguments(for: bundleId, profile: profile)
        guard !profileArgs.isEmpty else { return nil }
        return profileArgs + [url.absoluteString]
    }

    static func frontmostApp() -> NSRunningApplication? {
        return NSWorkspace.shared.frontmostApplication
    }

    // MARK: - Browser Profile Support

    /// Chromium browsers whose profiles SidebArc supports (lowercased bundle id), and
    /// their data folder under `~/Library/Application Support`.
    private static let chromiumProfileFolders: [String: String] = [
        "com.google.chrome": "Google/Chrome",
        "com.google.chrome.canary": "Google/Chrome Canary",
        "net.imput.helium": "net.imput.helium"
    ]

    static func supportsProfiles(bundleId: String) -> Bool {
        chromiumProfileFolders[bundleId.lowercased()] != nil
    }

    /// Result of reading a browser's profile list.
    enum ProfileDetection: Equatable {
        case found([BrowserProfile])
        /// macOS (app-data protection) or file permissions blocked reading the
        /// browser's profile list. Profiles can still be entered manually.
        case accessDenied
        /// Unsupported browser, browser data not present, or no profiles listed.
        case unavailable

        var profiles: [BrowserProfile] {
            if case .found(let profiles) = self { return profiles }
            return []
        }
    }

    /// `supportRoot` is `~/Library/Application Support`; tests pass a temp directory.
    static func detectProfileList(bundleId: String, supportRoot: URL? = nil) -> ProfileDetection {
        let root = supportRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        guard let folder = chromiumProfileFolders[bundleId.lowercased()] else { return .unavailable }
        let result = detectChromeProfiles(dir: root.appendingPathComponent(folder))
        switch result {
        case .found(let profiles):
            logger.info("\(bundleId, privacy: .public): \(profiles.count) browser profile(s) detected")
        case .accessDenied:
            logger.notice("\(bundleId, privacy: .public): reading the browser profile list was denied (macOS privacy protection or file permissions); profiles can be entered by hand")
        case .unavailable:
            logger.info("\(bundleId, privacy: .public): no browser profile list found")
        }
        return result
    }

    /// Hint for typing a browser profile by hand ("Enter Profile…"). macOS blocks
    /// reading other browsers' data folders, so this is the normal path.
    static func manualProfileHint(bundleId: String) -> String {
        let browser = appName(bundleId: bundleId) ?? "the browser"
        return "In \(browser), open chrome://version and copy the last part of “Profile Path”, for example “Default” or “Profile 1”."
    }

    static func profileArguments(for bundleId: String, profile: String) -> [String] {
        supportsProfiles(bundleId: bundleId) ? ["--profile-directory=\(profile)"] : []
    }

    // MARK: - Private Profile Detection

    private static let logger = Logger(subsystem: AppIdentity.logSubsystem, category: "browser")

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoPermissionError { return true }
        if nsError.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(nsError.code) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    /// Reads a file, mapping "not there" to nil and permission failures to `.accessDenied`.
    private static func readFile(_ url: URL) -> Result<Data?, ProfileDetectionFailure> {
        do {
            return .success(try Data(contentsOf: url))
        } catch {
            if isPermissionError(error) { return .failure(.accessDenied) }
            return .success(nil)
        }
    }

    private enum ProfileDetectionFailure: Error {
        case accessDenied
    }

    private static func detectChromeProfiles(dir: URL) -> ProfileDetection {
        let data: Data
        switch readFile(dir.appendingPathComponent("Local State")) {
        case .failure: return .accessDenied
        case .success(nil): return .unavailable
        case .success(let read?): data = read
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profileSection = json["profile"] as? [String: Any],
              let infoCache = profileSection["info_cache"] as? [String: Any] else {
            return .unavailable
        }

        var profiles: [BrowserProfile] = []
        for (dirName, value) in infoCache {
            if let profileInfo = value as? [String: Any],
               let name = profileInfo["name"] as? String {
                profiles.append(BrowserProfile(id: dirName, displayName: name))
            }
        }
        return profiles.isEmpty ? .unavailable : .found(sortedByName(profiles))
    }

    private static func sortedByName(_ profiles: [BrowserProfile]) -> [BrowserProfile] {
        profiles.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
