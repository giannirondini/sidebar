import AppKit

enum WorkspaceColorId: String, Codable {
    case ember
    case ruby
    case coral
    case tangerine
    case moss
    case ocean
    case indigo
    case graphite
    // Added 2026-11-15; raw values are the display names.
    case rose
    case peach
    case sand
    case sage
    case seafoam
    case cornflower
    case orchid
    case stone
    case settingsBackground

    /// Unknown names (written by a newer version) decode as the default colour, so a
    /// colour added later can never make a whole `data.json` unreadable.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = WorkspaceColorId(rawValue: raw) ?? .defaultColor()
    }

    var name: String {
        switch self {
        case .ember: return "Blush"
        case .ruby: return "Apricot"
        case .coral: return "Butter"
        case .tangerine: return "Leaf"
        case .moss: return "Mint"
        case .ocean: return "Sky"
        case .indigo: return "Periwinkle"
        case .graphite: return "Lavender"
        case .rose: return "Rose"
        case .peach: return "Peach"
        case .sand: return "Sand"
        case .sage: return "Sage"
        case .seafoam: return "Seafoam"
        case .cornflower: return "Cornflower"
        case .orchid: return "Orchid"
        case .stone: return "Stone"
        case .settingsBackground: return "Settings"
        }
    }

    var color: NSColor {
        switch self {
        case .ember: return NSColor(calibratedRed: 1.00, green: 0.635, blue: 0.635, alpha: 1.0) // #FFA2A2
        case .ruby: return NSColor(calibratedRed: 1.00, green: 0.722, blue: 0.416, alpha: 1.0) // #FFB86A
        case .coral: return NSColor(calibratedRed: 1.00, green: 0.941, blue: 0.522, alpha: 1.0) // #FFF085
        case .tangerine: return NSColor(calibratedRed: 0.847, green: 0.976, blue: 0.600, alpha: 1.0) // #D8F999
        case .moss: return NSColor(calibratedRed: 0.369, green: 0.914, blue: 0.710, alpha: 1.0) // #5EE9B5
        case .ocean: return NSColor(calibratedRed: 0.325, green: 0.918, blue: 0.992, alpha: 1.0) // #53EAFD
        case .indigo: return NSColor(calibratedRed: 0.639, green: 0.702, blue: 1.00, alpha: 1.0) // #A3B3FF
        case .graphite: return NSColor(calibratedRed: 0.855, green: 0.698, blue: 1.00, alpha: 1.0) // #DAB2FF
        case .rose: return NSColor(calibratedRed: 0.992, green: 0.643, blue: 0.812, alpha: 1.0) // #FDA4CF
        case .peach: return NSColor(calibratedRed: 0.996, green: 0.843, blue: 0.667, alpha: 1.0) // #FED7AA
        case .sand: return NSColor(calibratedRed: 0.906, green: 0.851, blue: 0.725, alpha: 1.0) // #E7D9B9
        case .sage: return NSColor(calibratedRed: 0.765, green: 0.851, blue: 0.690, alpha: 1.0) // #C3D9B0
        case .seafoam: return NSColor(calibratedRed: 0.600, green: 0.965, blue: 0.894, alpha: 1.0) // #99F6E4
        case .cornflower: return NSColor(calibratedRed: 0.576, green: 0.773, blue: 0.992, alpha: 1.0) // #93C5FD
        case .orchid: return NSColor(calibratedRed: 0.941, green: 0.671, blue: 0.988, alpha: 1.0) // #F0ABFC
        case .stone: return NSColor(calibratedRed: 0.839, green: 0.827, blue: 0.820, alpha: 1.0) // #D6D3D1
        case .settingsBackground: return NSColor(calibratedRed: 0.898, green: 0.906, blue: 0.922, alpha: 1.0) // #E5E7EB
        }
    }

    var backgroundColor: NSColor {
        if self == .settingsBackground {
            return color
        }
        return color.withAlphaComponent(Self.presetBackgroundAlpha)
    }

    /// Opacity of the sidebar background for a preset colour: opaque, as presets
    /// always looked (0.92 was painted twice, which showed as 0.99). Lower it, or pick
    /// a custom colour, for the frosted look.
    static let presetBackgroundAlpha: CGFloat = 1.0
}

extension WorkspaceColorId {
    static var allCases: [WorkspaceColorId] {
        [.ember, .ruby, .coral, .tangerine, .moss, .ocean, .indigo, .graphite,
         .rose, .peach, .sand, .sage, .seafoam, .cornflower, .orchid, .stone]
    }

    static func defaultColor() -> WorkspaceColorId { .ember }

    static func randomColor() -> WorkspaceColorId {
        WorkspaceColorId.allCases.randomElement() ?? .defaultColor()
    }
}

/// A custom space colour (sRGB components, 0…1), picked in the colour panel.
/// `alpha` is the opacity of the sidebar background; icons and dots always use the
/// colour opaque. Dark colours aren't adapted for: text stays dark (accepted limit).
struct SpaceColor: Codable, Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    /// nil for colours without sRGB components (patterns, some catalog colours).
    init?(_ color: NSColor) {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }

    /// The colour with its opacity (the sidebar background).
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// The colour, fully opaque (icons, dots, swatches).
    var opaqueColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

extension Workspace {
    /// The space's colour, opaque: icons, dots, swatches, the header.
    var color: NSColor {
        customColor?.opaqueColor ?? colorId.color
    }

    /// The sidebar background: the custom colour with its opacity, or the preset at
    /// `WorkspaceColorId.presetBackgroundAlpha`.
    var backgroundColor: NSColor {
        customColor?.nsColor ?? colorId.backgroundColor
    }
}
