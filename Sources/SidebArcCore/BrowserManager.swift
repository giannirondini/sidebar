import AppKit
import SQLite3
import os

struct BrowserInfo: Equatable {
    let bundleId: String
    let name: String
    let icon: NSImage?
}

struct BrowserProfile: Equatable {
    let id: String          // Internal identifier (directory name for Chrome, relative path for Firefox selectable profiles, profile name for Firefox legacy)
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
            "net.imput.helium",
            "org.mozilla.firefox",
            "org.mozilla.firefoxdeveloperedition"
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
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition":
            result = detectFirefoxProfiles(firefoxDir: root.appendingPathComponent("Firefox"))
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
        switch bundleId.lowercased() {
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition":
            return "Enter the profile name or its Root Directory, both shown in Firefox at about:profiles."
        default:
            return "Enter the browser profile directory name, e.g. “Profile 1”."
        }
    }

    static func profileArguments(for bundleId: String, profile: String) -> [String] {
        let lowered = bundleId.lowercased()
        switch lowered {
        case "com.google.chrome", "com.google.chrome.canary", "net.imput.helium":
            return ["--profile-directory=\(profile)"]
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition":
            // Absolute path (e.g. the Root Directory from about:profiles, entered manually)
            if profile.hasPrefix("/") {
                return ["-profile", profile]
            }
            // Relative path inside the Firefox folder: selectable profiles, or
            // classic profiles.ini entries ("Profiles/xxxx.Name")
            if profile.hasPrefix("Profiles/") {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let absolutePath = home
                    .appendingPathComponent("Library/Application Support/Firefox")
                    .appendingPathComponent(profile)
                    .path
                return ["-profile", absolutePath]
            }
            // Classic profile name from profiles.ini
            return ["-P", profile]
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

    /// Firefox lists profiles in two places, and both can be in use at once:
    /// - classic profiles in `profiles.ini` (`[ProfileN]` with `Name`/`Path`),
    ///   created by about:profiles;
    /// - "selectable" profiles (Firefox's newer profile manager) in
    ///   `Profile Groups/<StoreID>.sqlite`, linked from `profiles.ini` by `StoreID`.
    /// Both are listed, deduplicated by profile path. Classic profiles keep their
    /// name as id (opened with `-P name`); selectable ones use their path.
    private static func detectFirefoxProfiles(firefoxDir: URL) -> ProfileDetection {
        let ini: String
        switch readFile(firefoxDir.appendingPathComponent("profiles.ini")) {
        case .failure: return .accessDenied
        case .success(nil): return .unavailable
        case .success(let data?): ini = String(decoding: data, as: UTF8.self)
        }

        let sections = parseINI(ini)
        var profiles: [BrowserProfile] = []
        var seenPaths: Set<String> = []

        let storeIds = Set(sections.compactMap { $0.values["storeid"] }.filter { !$0.isEmpty })
        let profileGroupsDir = firefoxDir.appendingPathComponent("Profile Groups")
        for storeId in storeIds.sorted() {
            let dbPath = profileGroupsDir.appendingPathComponent("\(storeId).sqlite").path
            for profile in readFirefoxProfileGroupDB(dbPath: dbPath) where seenPaths.insert(profile.id).inserted {
                profiles.append(profile)
            }
        }

        for section in sections where section.name.hasPrefix("Profile") {
            guard let name = section.values["name"], !name.isEmpty else { continue }
            if let path = section.values["path"], !seenPaths.insert(path).inserted { continue }
            profiles.append(BrowserProfile(id: name, displayName: name))
        }

        return profiles.isEmpty ? .unavailable : .found(sortedByName(profiles))
    }

    /// Minimal INI parser: sections with lower-cased keys, values as written.
    private static func parseINI(_ text: String) -> [(name: String, values: [String: String])] {
        var sections: [(name: String, values: [String: String])] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                sections.append((String(line.dropFirst().dropLast()), [:]))
            } else if let equals = line.firstIndex(of: "="), !sections.isEmpty {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].values[key] = value
            }
        }
        return sections
    }

    private static func sortedByName(_ profiles: [BrowserProfile]) -> [BrowserProfile] {
        profiles.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Reads the Profiles table from a Firefox Profile Groups SQLite database.
    /// Returns profiles with id = relative path (e.g. "Profiles/xxxx.Name") and displayName = human-readable name.
    private static func readFirefoxProfileGroupDB(dbPath: String) -> [BrowserProfile] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let query = "SELECT path, name FROM Profiles ORDER BY id"
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var profiles: [BrowserProfile] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pathCStr = sqlite3_column_text(stmt, 0),
                  let nameCStr = sqlite3_column_text(stmt, 1) else {
                continue
            }
            let path = String(cString: pathCStr)
            let name = String(cString: nameCStr)
            profiles.append(BrowserProfile(id: path, displayName: name))
        }

        return profiles
    }
}
