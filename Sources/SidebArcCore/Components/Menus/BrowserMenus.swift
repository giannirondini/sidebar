import AppKit

/// Builders for the browser and profile submenus shared by the link list, the
/// Favorites grid and the space menus. They only build items; every action is a
/// closure supplied by the caller, which does the `AppModel` call.
enum BrowserMenus {
    private static let menuIconSize = NSSize(width: 16, height: 16)

    private static func browserItem(_ browser: BrowserInfo, state: NSControl.StateValue = .off, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: browser.name, state: state, action: action)
        if let icon = browser.icon?.copy() as? NSImage {
            icon.size = menuIconSize
            item.image = icon
        }
        return item
    }

    /// "Open in ▸": a one-off open in another browser; the link is not changed.
    static func openInItem(browsers: [BrowserInfo], open: @escaping (String) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: "Open in", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for browser in browsers {
            submenu.addItem(browserItem(browser) { open(browser.bundleId) })
        }
        item.submenu = submenu
        item.isEnabled = !browsers.isEmpty
        return item
    }

    /// "Always open in ▸": sets the link's browser override. The first entry
    /// clears it, so the link follows its space's profile again.
    /// A configured browser that is no longer installed is listed (checked) so
    /// the user can see and clear it.
    static func alwaysOpenInItem(
        browsers: [BrowserInfo],
        current: String?,
        profileBrowserName: String?,
        set: @escaping (String?) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Always open in", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let inheritTitle = profileBrowserName.map { "Space Profile’s Browser (\($0))" } ?? "Space Profile’s Browser"
        submenu.addItem(ClosureMenuItem(title: inheritTitle, state: current == nil ? .on : .off) { set(nil) })
        submenu.addItem(.separator())
        for browser in browsers {
            let isCurrent = current.map { $0.caseInsensitiveCompare(browser.bundleId) == .orderedSame } ?? false
            submenu.addItem(browserItem(browser, state: isCurrent ? .on : .off) { set(browser.bundleId) })
        }
        if let current, !browsers.contains(where: { $0.bundleId.caseInsensitiveCompare(current) == .orderedSame }) {
            submenu.addItem(ClosureMenuItem(title: "\(current) (not installed)", state: .on) { set(current) })
        }
        item.submenu = submenu
        return item
    }

    /// "Match Exact URL" (checked when on): focus an open tab only when its URL equals
    /// the link's, not when it is a page below it (`TabURLMatcher`). Toggles.
    static func exactMatchItem(isOn: Bool, set: @escaping (Bool) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: "Match Exact URL", state: isOn ? .on : .off) { set(!isOn) }
        item.toolTip = "Switch to an open tab only when it shows exactly this page, not a page below it."
        return item
    }

    /// "Profile ▸": assigns a space to a profile, or creates a new one for it.
    static func profileItem(
        profiles: [Profile],
        currentProfileId: UUID,
        assign: @escaping (UUID) -> Void,
        newProfile: @escaping () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for profile in profiles {
            submenu.addItem(ClosureMenuItem(title: profile.name, state: profile.id == currentProfileId ? .on : .off) {
                assign(profile.id)
            })
        }
        submenu.addItem(.separator())
        submenu.addItem(ClosureMenuItem(title: "New Profile…", action: newProfile))
        item.submenu = submenu
        return item
    }
}

/// Modal text prompt used for naming profiles and entering browser profile ids.
enum TextPrompt {
    @MainActor
    static func run(message: String, informative: String? = nil, initial: String = "", placeholder: String? = nil, confirmTitle: String) -> String? {
        let alert = NSAlert()
        alert.messageText = message
        if let informative { alert.informativeText = informative }
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = initial
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
