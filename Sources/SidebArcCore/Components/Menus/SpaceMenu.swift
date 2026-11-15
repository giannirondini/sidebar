import AppKit

/// Builds the context menu of a space (the space bar's icons and the space header).
/// Every action is a closure that already knows which space it acts on, so opening
/// the menu never switches the current space.
enum SpaceMenu {
    struct Actions {
        var rename: () -> Void
        var changeIcon: () -> Void
        var setColor: (WorkspaceColorId) -> Void
        /// "Custom Color…": opens the colour panel for this space.
        var customColor: () -> Void
        /// `nil` when the space is already first.
        var moveLeft: (() -> Void)?
        /// `nil` when the space is already last.
        var moveRight: (() -> Void)?
        var delete: () -> Void
    }

    private static let colorSwatchSize: CGFloat = ThemeConstants.Sizing.iconSmall - 2
    private static let colorSwatchBorderWidth: CGFloat = 1.5
    private static let colorSwatchBorderOpacity: CGFloat = 0.20

    /// - Parameters:
    ///   - profileItem: the "Profile ▸" item (`BrowserMenus.profileItem`).
    ///   - canDelete: false for the last space; the item is shown disabled.
    static func build(
        workspace: Workspace,
        canDelete: Bool,
        profileItem: NSMenuItem,
        actions: Actions
    ) -> NSMenu {
        let menu = NSMenu()
        // Otherwise AppKit re-enables every item whose target responds to its action,
        // and the disabled Delete item would still be clickable.
        menu.autoenablesItems = false

        menu.addItem(ClosureMenuItem(title: "Rename Space…", action: actions.rename))
        menu.addItem(ClosureMenuItem(title: "Change Icon…", action: actions.changeIcon))

        menu.addItem(colorItem(for: workspace, setColor: actions.setColor, customColor: actions.customColor))

        menu.addItem(profileItem)

        if actions.moveLeft != nil || actions.moveRight != nil {
            menu.addItem(.separator())
            if let moveLeft = actions.moveLeft {
                menu.addItem(ClosureMenuItem(title: "Move Left", action: moveLeft))
            }
            if let moveRight = actions.moveRight {
                menu.addItem(ClosureMenuItem(title: "Move Right", action: moveRight))
            }
        }

        menu.addItem(.separator())
        let deleteItem = ClosureMenuItem(title: "Delete Space…", action: actions.delete)
        deleteItem.isEnabled = canDelete
        menu.addItem(deleteItem)

        return menu
    }

    /// "Change Color ▸": the presets (checked when no custom colour is set), then
    /// "Custom Color…" (checked, with its swatch, when one is). Shared by the space
    /// menu and Settings › Spaces.
    static func colorItem(
        for workspace: Workspace,
        setColor: @escaping (WorkspaceColorId) -> Void,
        customColor: @escaping () -> Void
    ) -> NSMenuItem {
        let submenu = NSMenu()
        for colorId in WorkspaceColorId.allCases {
            let isCurrent = workspace.customColor == nil && colorId == workspace.colorId
            let item = ClosureMenuItem(title: colorId.name, state: isCurrent ? .on : .off) {
                setColor(colorId)
            }
            item.image = colorSwatch(colorId.color)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let custom = ClosureMenuItem(title: "Custom Color…", state: workspace.customColor != nil ? .on : .off, action: customColor)
        if let color = workspace.customColor {
            custom.image = colorSwatch(color.opaqueColor)
        }
        submenu.addItem(custom)

        let item = NSMenuItem(title: "Change Color", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func colorSwatch(_ color: NSColor) -> NSImage {
        let size = colorSwatchSize
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size))
        color.setFill()
        path.fill()
        ThemeConstants.Colors.darkGray.withAlphaComponent(colorSwatchBorderOpacity).setStroke()
        path.lineWidth = colorSwatchBorderWidth
        path.stroke()
        image.unlockFocus()
        return image
    }
}
