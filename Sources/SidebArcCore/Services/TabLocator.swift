import AppKit
import CoreServices

/// A tab found by a `TabLocator`: 1-based window index (front to back) and tab
/// index, as AppleScript counts them, plus the URL it showed when it was listed.
struct TabRef: Equatable, Sendable {
    let windowIndex: Int
    let tabIndex: Int
    let url: String
}

enum TabLocatorError: Error, Equatable {
    /// The Apple Event failed: timeout (-1712), not permitted (-1743), app gone (-600), …
    case appleEvent(Int)
    /// The reply was not what the dictionary promises.
    case unexpectedReply
}

/// Lists and focuses a browser's tabs over Apple Events (plan-v2 Phase 2.1–2.2).
///
/// Calls block until the reply or `timeout`, so call them off the main actor
/// (`TabFocusService` does). They target a running process by pid, so they never
/// launch the browser, and they never ask for Automation permission: the caller
/// checks `AutomationPermission` first.
protocol TabLocator: Sendable {
    /// Tab URLs per window, front window first, in **one** Apple Event. Windows
    /// whose tabs must never be focused (Chromium incognito) are returned empty,
    /// so the indices still line up with the browser's.
    func tabURLs(pid: pid_t, timeout: TimeInterval) throws -> [[String]]

    /// Selects `tab` and brings its window to the front of the browser's windows.
    /// The window is addressed by its id, not its index: restoring a minimised
    /// window or raising it renumbers the windows.
    /// Returns false, changing nothing, when that tab no longer shows `tab.url`
    /// (closed, moved or navigated since it was listed). The caller activates the app.
    func activate(_ tab: TabRef, pid: pid_t, timeout: TimeInterval) throws -> Bool
}

enum TabLocators {
    /// Locator for a browser, or nil when tabs can't be scripted (Firefox has no
    /// dictionary) or the browser isn't verified: those always open normally.
    /// Bundle ids are matched case-insensitively (`com.google.Chrome`).
    static func locator(for bundleId: String) -> TabLocator? {
        switch bundleId.lowercased() {
        case "com.google.chrome", "com.brave.browser":
            return ChromiumTabLocator()
        case "com.apple.safari":
            return SafariTabLocator()
        default:
            // Not verified on a Mac with SidebArc (plan-v2 decisions): Dia and Arc ship
            // their own dictionaries; Edge, Vivaldi, Canary and Helium aren't installed.
            return nil
        }
    }

    static func isSupported(bundleId: String) -> Bool {
        locator(for: bundleId) != nil
    }
}

// MARK: - Chromium (Chrome, Brave)

/// Chromium's `scripting.sdef`: `window` (`cwin`) › `tab` (`CrTb`) › `URL`;
/// `active tab index` (`acTI`) and `mode` ("normal" / "incognito") on the window.
struct ChromiumTabLocator: TabLocator {
    func tabURLs(pid: pid_t, timeout: TimeInterval) throws -> [[String]] {
        let windows = AE.every(AE.window)
        var urls = try AE.nestedStrings(AE.get(AE.property("URL ", of: AE.every("CrTb", of: windows)), pid: pid, timeout: timeout))
        // Never focus an incognito tab for a sidebar link. Best effort: if the modes
        // can't be read or don't line up, the URLs are used as they are.
        if let modes = try? AE.strings(AE.get(AE.property("mode", of: windows), pid: pid, timeout: timeout)),
           modes.count == urls.count {
            for (index, mode) in modes.enumerated() where mode == "incognito" {
                urls[index] = []
            }
        }
        return urls
    }

    func activate(_ tab: TabRef, pid: pid_t, timeout: TimeInterval) throws -> Bool {
        let window = try AE.windowById(index: tab.windowIndex, pid: pid, timeout: timeout)
        let tabSpec = AE.item(tab.tabIndex, of: "CrTb", in: window)
        let current = try AE.get(AE.property("URL ", of: tabSpec), pid: pid, timeout: timeout).stringValue
        guard current == tab.url else { return false }
        // Restore a minimised window (harmless when it isn't).
        try? AE.set(AE.property("pmnd", of: window), to: NSAppleEventDescriptor(boolean: false), pid: pid, timeout: timeout)
        try AE.set(AE.property("acTI", of: window), to: NSAppleEventDescriptor(int32: Int32(tab.tabIndex)), pid: pid, timeout: timeout)
        try AE.set(AE.property("pidx", of: window), to: NSAppleEventDescriptor(int32: 1), pid: pid, timeout: timeout)
        return true
    }
}

// MARK: - Safari

/// Safari's `Safari.sdef`: `window` (`cwin`) › `tab` (`bTab`) › `URL` (`pURL`);
/// `current tab` (`cTab`) on the window.
struct SafariTabLocator: TabLocator {
    func tabURLs(pid: pid_t, timeout: TimeInterval) throws -> [[String]] {
        try AE.nestedStrings(AE.get(AE.property("pURL", of: AE.every("bTab", of: AE.every(AE.window))), pid: pid, timeout: timeout))
    }

    func activate(_ tab: TabRef, pid: pid_t, timeout: TimeInterval) throws -> Bool {
        let window = try AE.windowById(index: tab.windowIndex, pid: pid, timeout: timeout)
        let tabSpec = AE.item(tab.tabIndex, of: "bTab", in: window)
        let current = try AE.get(AE.property("pURL", of: tabSpec), pid: pid, timeout: timeout).stringValue
        guard current == tab.url else { return false }
        try? AE.set(AE.property("pmnd", of: window), to: NSAppleEventDescriptor(boolean: false), pid: pid, timeout: timeout)
        try AE.set(AE.property("cTab", of: window), to: tabSpec, pid: pid, timeout: timeout)
        try AE.set(AE.property("pidx", of: window), to: NSAppleEventDescriptor(int32: 1), pid: pid, timeout: timeout)
        return true
    }
}

// MARK: - Automation permission

/// Whether SidebArc may send Apple Events to a running browser (TCC "Automation").
enum AutomationPermission: Equatable {
    case granted
    case denied
    /// Never asked, or the grant no longer matches this build.
    case notDetermined
    case notRunning
    case other(Int)

    init(status: OSStatus) {
        switch status {
        case noErr: self = .granted
        case OSStatus(errAEEventNotPermitted): self = .denied
        case OSStatus(errAEEventWouldRequireUserConsent): self = .notDetermined
        case OSStatus(procNotFound): self = .notRunning
        default: self = .other(Int(status))
        }
    }

    /// Checks (and with `ask`, requests) permission for `pid`. Blocks, and with
    /// `ask` it waits for the user's answer, so never call it on the main actor.
    /// The click path passes `ask: false`; only Settings asks.
    static func check(pid: pid_t, ask: Bool) -> AutomationPermission {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let address = target.aeDesc else { return .other(Int(paramErr)) }
        let status = AEDeterminePermissionToAutomateTarget(address, typeWildCard, typeWildCard, ask)
        return AutomationPermission(status: status)
    }
}

// MARK: - Apple Event building

/// Builds and sends the few Apple Events the locators need, from four-char codes
/// in each browser's dictionary. Raw events, not `NSAppleScript` (main-thread only)
/// or `osascript` (a child process: privacy checks are attributed to SidebArc).
enum AE {
    static let window = "cwin"

    static func code(_ string: String) -> FourCharCode {
        string.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    /// `every <cls> of <container>`; the application when `container` is nil.
    static func every(_ cls: String, of container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        var all = code("all ")
        let selector = NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: MemoryLayout<FourCharCode>.size)!
        return specifier(want: cls, from: container, form: "indx", selector: selector)
    }

    /// `<cls> <index> of <container>` (1-based); the application when `container` is nil.
    static func item(_ index: Int, of cls: String, in container: NSAppleEventDescriptor? = nil) -> NSAppleEventDescriptor {
        specifier(want: cls, from: container, form: "indx", selector: NSAppleEventDescriptor(int32: Int32(index)))
    }

    /// `<cls> id <id>`; `id` as the browser returned it (Chrome: text, Safari: integer).
    static func byId(_ id: NSAppleEventDescriptor, of cls: String) -> NSAppleEventDescriptor {
        specifier(want: cls, from: nil, form: "ID  ", selector: id)
    }

    /// Reads the id of `window <index>` and returns a specifier by that id, which
    /// stays valid when the windows are reordered (un-minimise, raise).
    static func windowById(index: Int, pid: pid_t, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        let id = try get(property("ID  ", of: item(index, of: window)), pid: pid, timeout: timeout)
        guard id.descriptorType != typeNull else { throw TabLocatorError.unexpectedReply }
        return byId(id, of: window)
    }

    static func property(_ property: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: "prop", from: container, form: "prop", selector: NSAppleEventDescriptor(typeCode: code(property)))
    }

    static func specifier(want: String, from container: NSAppleEventDescriptor?, form: String, selector: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        record.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(selector, forKeyword: code("seld"))
        return record.coerce(toDescriptorType: code("obj ")) ?? record
    }

    /// `core/getd`: the value of `specifier`.
    static func get(_ specifier: NSAppleEventDescriptor, pid: pid_t, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        let event = makeEvent("core", "getd", pid: pid)
        event.setParam(specifier, forKeyword: code("----"))
        return try send(event, timeout: timeout)
    }

    /// `core/setd`: sets `specifier` to `value`.
    static func set(_ specifier: NSAppleEventDescriptor, to value: NSAppleEventDescriptor, pid: pid_t, timeout: TimeInterval) throws {
        let event = makeEvent("core", "setd", pid: pid)
        event.setParam(specifier, forKeyword: code("----"))
        event.setParam(value, forKeyword: code("data"))
        _ = try send(event, timeout: timeout)
    }

    static func makeEvent(_ eventClass: String, _ eventId: String, pid: pid_t) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(
            withEventClass: code(eventClass),
            eventID: code(eventId),
            // By pid: an event to a running process never launches the app.
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    /// Sends and returns the direct result. `timeout` is the event's own, so a
    /// busy or hung browser can't block the caller past it.
    static func send(_ event: NSAppleEventDescriptor, timeout: TimeInterval) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: timeout)
        } catch {
            throw TabLocatorError.appleEvent((error as NSError).code)
        }
        if let number = reply.paramDescriptor(forKeyword: code("errn")), number.int32Value != 0 {
            throw TabLocatorError.appleEvent(Int(number.int32Value))
        }
        return reply.paramDescriptor(forKeyword: code("----")) ?? NSAppleEventDescriptor.null()
    }

    /// A list of texts (missing values become ""). A single value is a one-item list.
    static func strings(_ descriptor: NSAppleEventDescriptor) throws -> [String] {
        guard descriptor.descriptorType == code("list") else {
            if descriptor.descriptorType == typeNull { return [] }
            return [descriptor.stringValue ?? ""]
        }
        guard descriptor.numberOfItems > 0 else { return [] }
        return (1...descriptor.numberOfItems).map { descriptor.atIndex($0)?.stringValue ?? "" }
    }

    /// A list of lists of texts (`URL of every tab of every window`).
    static func nestedStrings(_ descriptor: NSAppleEventDescriptor) throws -> [[String]] {
        if descriptor.descriptorType == typeNull { return [] }
        guard descriptor.descriptorType == code("list") else { throw TabLocatorError.unexpectedReply }
        guard descriptor.numberOfItems > 0 else { return [] }
        return try (1...descriptor.numberOfItems).map { index in
            guard let window = descriptor.atIndex(index) else { return [] }
            return try strings(window)
        }
    }
}
