import AppKit
import Foundation

extension Notification.Name {
    static let defaultBrowserChanged = Notification.Name("defaultBrowserChanged")
    static let alwaysOnTopSettingChanged = Notification.Name("alwaysOnTopSettingChanged")
    static let attachmentSettingChanged = Notification.Name("attachmentSettingChanged")
    static let sidebarPositionChanged = Notification.Name("sidebarPositionChanged")
    static let toggleSidebarShortcutChanged = Notification.Name("toggleSidebarShortcutChanged")
    static let tooltipsSettingChanged = Notification.Name("tooltipsSettingChanged")
    static let swipeToSwitchSettingChanged = Notification.Name("swipeToSwitchSettingChanged")
}

enum UserDefaultsKeys {
    static let defaultBrowserBundleId = "defaultBrowserBundleId"
    static let alwaysOnTopEnabled = "alwaysOnTopEnabled"
    static let lastSelectedWorkspaceId = "lastSelectedWorkspaceId"
    static let mainWindowSize = "mainWindowSize"
    static let sidebarAttachmentEnabled = "sidebarAttachmentEnabled"
    static let sidebarPosition = "sidebarPosition"
    static let lastArcImportDate = "lastArcImportDate"
    static let arcImportCount = "arcImportCount"
    static let toggleSidebarShortcut = "toggleSidebarShortcut"
    static let tooltipsEnabled = "tooltipsEnabled"
    static let swipeToSwitchEnabled = "swipeToSwitchEnabled"
    /// Bundle id of the browser whose Automation permission was missing when a click
    /// looked for an open tab; Settings › Permissions shows a hint until it's resolved.
    static let tabFocusPermissionHintBundleId = "tabFocusPermissionHintBundleId"
}

/// Fork identity. `bundleIdentifier` must match `identifier` in Bundler.toml
/// (the build scripts read it from there; `AppIdentityTests` checks they agree).
/// Deliberately not `Bundle.main.bundleIdentifier`: under `swift test` / `swift run`
/// that is the xctest bundle or nil, and the data directory would silently move.
enum AppIdentity {
    static let bundleIdentifier = "io.github.giannirondini.sidebarc"
    /// Folder under `~/Library/Application Support`, named after the bundle id.
    static let dataDirectoryName = bundleIdentifier
    /// `os.Logger` subsystem for every category in the app.
    static let logSubsystem = bundleIdentifier
    /// User-facing product name. Must match the `[apps.<name>]` key in Bundler.toml.
    static let displayName = "SidebArc"
    /// Target of "Check for Updates…" (menu and Settings); there is no in-app updater.
    static let releasesURL = URL(string: "https://github.com/giannirondini/sidebarc/releases")!
}

let nodePasteboardType = NSPasteboard.PasteboardType("\(AppIdentity.bundleIdentifier).node")
let workspacePasteboardType = NSPasteboard.PasteboardType("\(AppIdentity.bundleIdentifier).workspace")

struct TooltipConstants {
    static let showDelay: TimeInterval = 1.2
}

struct LayoutConstants {
    static let windowPadding: CGFloat = 8
}

struct ListMetrics {
    let rowHeight: CGFloat = 40
    let verticalGap: CGFloat = 4
    let overscrollBottom: CGFloat = 150
    let leftPadding: CGFloat = 8
    let iconSize: CGFloat = 20
    let indentWidth: CGFloat = 16
    let rowCornerRadius: CGFloat = 12
    let iconCornerRadius: CGFloat = 4
    let linkTitleFont: NSFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    let folderTitleFont: NSFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    let titleColor: NSColor = NSColor.black.withAlphaComponent(0.8)
    let hoverBackgroundColor: NSColor = NSColor.black.withAlphaComponent(0.1)
    let selectedBackgroundColor: NSColor = NSColor.black.withAlphaComponent(0.2)
    let deleteTintColor: NSColor = NSColor.black.withAlphaComponent(0.5)
    let iconTintColor: NSColor = NSColor.black.withAlphaComponent(0.7)
}
