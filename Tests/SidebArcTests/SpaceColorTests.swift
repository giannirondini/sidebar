import AppKit
import Foundation
import Testing
@testable import SidebArcCore

/// Space colours: presets, custom colours with opacity, lenient decoding.
@Suite struct SpaceColorTests {
    private let scratch = TempDir()
    private let testDefaults = TestDefaults()
    private var directory: URL { scratch.url }

    @Test func presetsAreSixteenDistinctColoursWithoutSettings() {
        let presets = WorkspaceColorId.allCases
        #expect(presets.count == 16)
        #expect(!presets.contains(.settingsBackground))
        #expect(Set(presets.map(\.name)).count == presets.count)
        #expect(Set(presets.map { SpaceColor($0.color) }).count == presets.count)
    }

    @Test func unknownColourNameDecodesAsTheDefault() throws {
        let decoded = try JSONDecoder().decode([WorkspaceColorId].self, from: Data(#"["moss", "ultraviolet"]"#.utf8))
        #expect(decoded == [.moss, .defaultColor()])
    }

    @Test func workspaceWithoutCustomColorDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"S","colorId":"ocean","items":[],"profileId":"\#(UUID().uuidString)"}"#
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(workspace.customColor == nil)
        #expect(workspace.color == WorkspaceColorId.ocean.color)
    }

    @Test func customColorWinsAndCarriesTheBackgroundOpacity() {
        var workspace = Workspace(id: UUID(), name: "S", colorId: .ocean, items: [], profileId: UUID())
        #expect(workspace.backgroundColor.alphaComponent == WorkspaceColorId.presetBackgroundAlpha)

        workspace.customColor = SpaceColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.5)
        let background = workspace.backgroundColor.usingColorSpace(.sRGB)!
        #expect(abs(background.redComponent - 0.2) < 0.001)
        #expect(abs(background.alphaComponent - 0.5) < 0.001)
        #expect(workspace.color.alphaComponent == 1)
    }

    @Test func spaceColorClampsAndConvertsFromNSColor() throws {
        let clamped = SpaceColor(red: -1, green: 2, blue: 0.5, alpha: 3)
        #expect(clamped == SpaceColor(red: 0, green: 1, blue: 0.5, alpha: 1))

        let converted = try #require(SpaceColor(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)))
        #expect(abs(converted.blue - 0.3) < 0.001)
        #expect(abs(converted.alpha - 0.4) < 0.001)
        #expect(SpaceColor(NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))) == nil)
    }

    @Test func customColorPersistsAndAPresetClearsIt() throws {
        let model = AppModel(store: DataStore(baseDirectory: directory), defaults: testDefaults.suite)
        let id = model.currentWorkspace.id
        let custom = SpaceColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 0.6)

        var changes = 0
        model.onChange = { changes += 1 }
        model.setWorkspaceCustomColor(id: id, color: custom)
        model.setWorkspaceCustomColor(id: id, color: custom)   // unchanged: no save, no reload
        #expect(changes == 1)
        #expect(DataStore(baseDirectory: directory).load().workspaces.first { $0.id == id }?.customColor == custom)

        model.updateWorkspaceColor(id: id, colorId: .sage)
        let reloaded = DataStore(baseDirectory: directory).load().workspaces.first { $0.id == id }
        #expect(reloaded?.customColor == nil)
        #expect(reloaded?.colorId == .sage)
    }
}
