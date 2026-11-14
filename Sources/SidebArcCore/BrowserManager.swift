import AppKit
import os

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
    /// A configured browser that isn't installed is skipped, so the next level
    /// applies (an uninstalled global default ends at the system handler in `open`).
    /// The profile directory is `profile.browserProfiles[browser]` when the browser
    /// is the profile's own; a per-link override to a *different* browser opens
    /// without a browser profile.
    static func resolveTarget(
        link: Link?,
        profile: Profile,
        globalDefault: String? = resolveDefaultBrowserBundleId(),
        installed: (String) -> Bool = { BrowserManager.isInstalled(bundleId: $0) }
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
        guard let url = URL(string: link.url) else { return }
        open(url: url, target: resolveTarget(link: link, profile: profile))
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
    /// symbol when that browser isn't installed (the link then falls back, see
    /// `resolveTarget`). nil when there is no override.
    static func overrideBadge(for bundleId: String?) -> NSImage? {
        guard let bundleId else { return nil }
        if let icon = appIcon(bundleId: bundleId) { return icon }
        let config = NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
        return NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Browser not installed")?
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
        guard let bundleId = target.bundleId,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            NSWorkspace.shared.open(url)
            return
        }

        // No profile: use existing NSWorkspace approach
        guard let profile = target.profileDir, !profile.isEmpty else {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: nil)
            return
        }

        // With profile: execute browser binary directly (works even when browser is already running)
        guard let bundle = Bundle(url: appURL),
              let executablePath = bundle.executablePath else {
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: nil)
            return
        }

        let args = profileArguments(for: bundleId, profile: profile)
        guard !args.isEmpty else {
            // Browser doesn't support profiles, open normally
            let config = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config, completionHandler: nil)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = args + [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    static func isRunning(bundleId: String) -> Bool {
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleId }
    }

    static func frontmostApp() -> NSRunningApplication? {
        return NSWorkspace.shared.frontmostApplication
    }

    // MARK: - Browser Profile Support

    static func supportsProfiles(bundleId: String) -> Bool {
        let supported = [
            "com.google.chrome",
            "com.google.chrome.canary",
            "net.imput.helium"
        ]
        return supported.contains(bundleId.lowercased())
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

    static func detectProfiles(bundleId: String) -> [BrowserProfile] {
        detectProfileList(bundleId: bundleId).profiles
    }

    /// `supportRoot` is `~/Library/Application Support`; tests pass a temp directory.
    static func detectProfileList(bundleId: String, supportRoot: URL? = nil) -> ProfileDetection {
        let root = supportRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let result: ProfileDetection
        switch bundleId.lowercased() {
        case "com.google.chrome":
            result = detectChromeProfiles(dir: root.appendingPathComponent("Google/Chrome"))
        case "com.google.chrome.canary":
            result = detectChromeProfiles(dir: root.appendingPathComponent("Google/Chrome Canary"))
        case "net.imput.helium":
            result = detectChromeProfiles(dir: root.appendingPathComponent("net.imput.helium"))
        default:
            return .unavailable
        }
        switch result {
        case .found(let profiles):
            logger.info("\(bundleId, privacy: .public): \(profiles.count) browser profile(s) detected")
        case .accessDenied:
            logger.error("\(bundleId, privacy: .public): reading the browser profile list was denied (macOS privacy protection or file permissions)")
        case .unavailable:
            logger.info("\(bundleId, privacy: .public): no browser profile list found")
        }
        return result
    }

    /// Hint for the manual "Other…" entry.
    static func manualProfileHint(bundleId: String) -> String {
        "Enter the browser profile directory name, e.g. “Profile 1”."
    }

    static func profileArguments(for bundleId: String, profile: String) -> [String] {
        let lowered = bundleId.lowercased()
        switch lowered {
        case "com.google.chrome", "com.google.chrome.canary", "net.imput.helium":
            return ["--profile-directory=\(profile)"]
        default:
            return []
        }
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
