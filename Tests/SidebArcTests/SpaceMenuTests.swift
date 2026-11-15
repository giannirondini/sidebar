import AppKit
import Testing
@testable import SidebArcCore

/// Menu dispatch for the space menu (`SpaceMenu`): every item must reach its
/// closure (see `ClosureMenuItemTests` for why that is not a given).
@MainActor
@Suite struct SpaceMenuTests {
    private let workspace = Workspace(id: UUID(), name: "Me", colorId: .ocean, items: [], profileId: UUID())

    init() {
        _ = NSApplication.shared
    }

    private final class Recorder {
        var calls: [String] = []
    }

    private func actions(_ recorder: Recorder, canMoveLeft: Bool = true, canMoveRight: Bool = true) -> SpaceMenu.Actions {
        SpaceMenu.Actions(
            rename: { recorder.calls.append("rename") },
            changeIcon: { recorder.calls.append("icon") },
            setColor: { recorder.calls.append("color:\($0.rawValue)") },
            customColor: { recorder.calls.append("custom") },
            moveLeft: canMoveLeft ? { recorder.calls.append("left") } : nil,
            moveRight: canMoveRight ? { recorder.calls.append("right") } : nil,
            delete: { recorder.calls.append("delete") }
        )
    }

    private func build(_ recorder: Recorder, workspace: Workspace? = nil, canDelete: Bool = true, canMoveLeft: Bool = true, canMoveRight: Bool = true) -> NSMenu {
        let profileItem = NSMenuItem(title: "Profile", action: nil, keyEquivalent: "")
        let menu = SpaceMenu.build(
            workspace: workspace ?? self.workspace,
            canDelete: canDelete,
            profileItem: profileItem,
            actions: actions(recorder, canMoveLeft: canMoveLeft, canMoveRight: canMoveRight)
        )
        menu.update()
        return menu
    }

    private func index(of title: String, in menu: NSMenu) throws -> Int {
        try #require(menu.items.firstIndex(where: { $0.title == title }))
    }

    @Test func itemsInOrder() {
        let menu = build(Recorder())
        #expect(menu.items.map(\.title) == [
            "Rename Space…", "Change Icon…", "Change Color", "Profile", "", "Move Left", "Move Right", "", "Delete Space…",
        ])
    }

    @Test func everyItemRunsItsClosure() throws {
        let recorder = Recorder()
        let menu = build(recorder)
        for title in ["Rename Space…", "Change Icon…", "Move Left", "Move Right", "Delete Space…"] {
            menu.performActionForItem(at: try index(of: title, in: menu))
        }
        #expect(recorder.calls == ["rename", "icon", "left", "right", "delete"])
    }

    @Test func colorSubmenuChecksCurrentAndSets() throws {
        let recorder = Recorder()
        let menu = build(recorder)
        let submenu = try #require(menu.items[try index(of: "Change Color", in: menu)].submenu)
        let sky = try index(of: WorkspaceColorId.ocean.name, in: submenu)
        #expect(submenu.items[sky].state == .on)
        #expect(submenu.items.filter { $0.state == .on }.count == 1)

        let mint = try index(of: WorkspaceColorId.moss.name, in: submenu)
        submenu.performActionForItem(at: mint)
        let custom = try index(of: "Custom Color…", in: submenu)
        #expect(submenu.items[custom].state == .off)
        submenu.performActionForItem(at: custom)
        #expect(recorder.calls == ["color:\(WorkspaceColorId.moss.rawValue)", "custom"])
    }

    @Test func colorSubmenuListsEveryPresetThenCustom() throws {
        let menu = build(Recorder())
        let submenu = try #require(menu.items[try index(of: "Change Color", in: menu)].submenu)
        #expect(submenu.items.map(\.title) == WorkspaceColorId.allCases.map(\.name) + ["", "Custom Color…"])
    }

    @Test func customColorIsCheckedInsteadOfThePreset() throws {
        var custom = workspace
        custom.customColor = SpaceColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.5)
        let menu = build(Recorder(), workspace: custom)
        let submenu = try #require(menu.items[try index(of: "Change Color", in: menu)].submenu)
        #expect(submenu.items.filter { $0.state == .on }.map(\.title) == ["Custom Color…"])
        #expect(submenu.items[try index(of: "Custom Color…", in: submenu)].image != nil)
    }

    @Test func moveItemsOnlyWhenPossible() {
        let first = build(Recorder(), canMoveLeft: false, canMoveRight: true)
        #expect(!first.items.contains { $0.title == "Move Left" })
        #expect(first.items.contains { $0.title == "Move Right" })

        let only = build(Recorder(), canMoveLeft: false, canMoveRight: false)
        #expect(!only.items.contains { $0.title.hasPrefix("Move") })
        #expect(only.items.map(\.title) == ["Rename Space…", "Change Icon…", "Change Color", "Profile", "", "Delete Space…"])
    }

    @Test func deleteIsDisabledForTheLastSpace() throws {
        let menu = build(Recorder(), canDelete: false)
        // `update()` must not re-enable it (auto-enabling is off).
        #expect(!menu.items[try index(of: "Delete Space…", in: menu)].isEnabled)
        #expect(menu.items[try index(of: "Rename Space…", in: menu)].isEnabled)
    }
}
