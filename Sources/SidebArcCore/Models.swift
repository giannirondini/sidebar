import Foundation

/// Root of `data.json`. Older schemas are decoded by `SchemaV1` and upgraded by
/// `SchemaMigration` in `DataStore.load()`; this type only ever reads the current one.
struct AppState: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var profiles: [Profile]
    var workspaces: [Workspace]
    var selectedWorkspaceId: UUID?
    // Whether Settings is shown is runtime state (`AppModel.isSettingsShown`), not saved.
    // Files written when Settings was a saved selection still carry an `isSettingsSelected` key; it is ignored.

    init(
        schemaVersion: Int = AppState.currentSchemaVersion,
        profiles: [Profile],
        workspaces: [Workspace],
        selectedWorkspaceId: UUID?
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.workspaces = workspaces
        self.selectedWorkspaceId = selectedWorkspaceId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // Missing `profiles` is repaired by `repaired()`, not rejected.
        profiles = try container.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        selectedWorkspaceId = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceId)
    }

    /// Restores the invariants the rest of the app relies on: there is at least
    /// one profile, and every workspace's `profileId` names an existing profile
    /// (dangling ids fall back to the first profile).
    func repaired() -> AppState {
        var state = self
        if state.profiles.isEmpty {
            state.profiles = [Profile.makeDefault()]
        }
        let known = Set(state.profiles.map(\.id))
        let fallback = state.profiles[0].id
        for index in state.workspaces.indices where !known.contains(state.workspaces[index].profileId) {
            state.workspaces[index].profileId = fallback
        }
        return state
    }
}

/// A group of spaces that share a browser setup and the Favorites grid
/// (Arc's "profile"). Every workspace belongs to exactly one profile.
struct Profile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Browser that opens this profile's links; `nil` inherits the global default.
    var browserBundleId: String?
    /// Browser profile directory per browser bundle id (e.g. Chrome's "Profile 1").
    var browserProfiles: [String: String]
    /// The Favorites tile grid, shared by every space in this profile.
    var favorites: [Link]
    /// Whether clicks look for an already open browser tab to focus (`TabFocus`).
    /// `nil` = automatic: on, unless the browser is ambiguous (another profile uses
    /// a different browser profile of the same browser; see `TabFocus.isAmbiguous`).
    /// Optional so existing v2 files decode (synthesized Codable has no defaults).
    var focusesOpenTabs: Bool?

    static let defaultName = "Default"
    /// A product limit, independent of the grid's layout: the grid adapts its
    /// columns to the sidebar width and grows rows to fit. Lowering it would
    /// need an overflow pass for profiles that already hold more.
    static let maxFavorites = 12

    init(
        id: UUID = UUID(),
        name: String,
        browserBundleId: String? = nil,
        browserProfiles: [String: String] = [:],
        favorites: [Link] = [],
        focusesOpenTabs: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.browserBundleId = browserBundleId
        self.browserProfiles = browserProfiles
        self.favorites = favorites
        self.focusesOpenTabs = focusesOpenTabs
    }

    static func makeDefault() -> Profile {
        Profile(name: defaultName)
    }

    /// Appends `links` to `favorites` in order, skipping any whose normalised URL
    /// is already a favorite and stopping at `maxFavorites`. Returns the links
    /// that did not fit (duplicates and overflow), in order, so callers can put
    /// them somewhere visible instead of dropping them.
    mutating func appendFavorites(_ links: [Link]) -> [Link] {
        var seen = Set(favorites.map { URLNormalization.key(for: $0.url) })
        var leftovers: [Link] = []
        for link in links {
            let key = URLNormalization.key(for: link.url)
            if seen.contains(key) || favorites.count >= Self.maxFavorites {
                leftovers.append(link)
            } else {
                favorites.append(link)
                seen.insert(key)
            }
        }
        return leftovers
    }
}

struct Workspace: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var colorId: WorkspaceColorId
    var items: [Node]
    var profileId: UUID
    /// Emoji or SF Symbol shown in the space bar and the space header; `nil` shows
    /// the colour dot. Optional so v2 files decode (synthesized Codable has no defaults).
    var icon: CustomIcon?
    /// A colour picked in the colour panel; wins over `colorId` while set. Picking a
    /// preset clears it. Optional so existing files decode. Read through
    /// `Workspace.color` / `Workspace.backgroundColor`.
    var customColor: SpaceColor?
}

enum CustomIcon: Codable, Equatable, Sendable {
    case emoji(String)
    case sfSymbol(String)
    case cachedFavicon(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum IconType: String, Codable {
        case emoji
        case sfSymbol
        case cachedFavicon
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(IconType.self, forKey: .type)
        let value = try container.decode(String.self, forKey: .value)
        switch type {
        case .emoji:
            self = .emoji(value)
        case .sfSymbol:
            self = .sfSymbol(value)
        case .cachedFavicon:
            self = .cachedFavicon(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .emoji(let value):
            try container.encode(IconType.emoji, forKey: .type)
            try container.encode(value, forKey: .value)
        case .sfSymbol(let value):
            try container.encode(IconType.sfSymbol, forKey: .type)
            try container.encode(value, forKey: .value)
        case .cachedFavicon(let value):
            try container.encode(IconType.cachedFavicon, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

struct Link: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var url: String
    var faviconPath: String?
    var customIcon: CustomIcon?
    var scheduledOpenAt: Date?
    /// Per-link browser override ("Always open in ▸"); `nil` follows the space's profile.
    var browserBundleId: String?
    /// Focus an open tab only when its URL equals this link's (`TabURLMatcher`), not
    /// when it is merely below it. `nil` = false; optional so v2 files decode.
    var exactTabMatch: Bool?
}

struct Folder: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var children: [Node]
    var isExpanded: Bool
}

struct Note: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var customIcon: CustomIcon?
}

enum Node: Codable, Identifiable, Equatable, Hashable, Sendable {
    case folder(Folder)
    case link(Link)
    case note(Note)

    enum CodingKeys: String, CodingKey {
        case type
        case folder
        case link
        case note
    }

    enum NodeType: String, Codable {
        case folder
        case link
        case note
    }

    var id: UUID {
        switch self {
        case .folder(let folder):
            return folder.id
        case .link(let link):
            return link.id
        case .note(let note):
            return note.id
        }
    }

    var displayName: String {
        switch self {
        case .folder(let folder):
            return folder.name
        case .link(let link):
            return link.title
        case .note(let note):
            return note.title
        }
    }

    static func == (lhs: Node, rhs: Node) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(NodeType.self, forKey: .type)
        switch type {
        case .folder:
            let folder = try container.decode(Folder.self, forKey: .folder)
            self = .folder(folder)
        case .link:
            let link = try container.decode(Link.self, forKey: .link)
            self = .link(link)
        case .note:
            let note = try container.decode(Note.self, forKey: .note)
            self = .note(note)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let folder):
            try container.encode(NodeType.folder, forKey: .type)
            try container.encode(folder, forKey: .folder)
        case .link(let link):
            try container.encode(NodeType.link, forKey: .type)
            try container.encode(link, forKey: .link)
        case .note(let note):
            try container.encode(NodeType.note, forKey: .type)
            try container.encode(note, forKey: .note)
        }
    }
}

struct NodeLocation: Equatable {
    var parentId: UUID?
    var index: Int
}

struct ScheduledLinkRef: Equatable, Sendable {
    let workspaceId: UUID
    let linkId: UUID
    let url: String
    let fireAt: Date
}

struct ScheduledLinkEntry: Equatable, Sendable {
    let link: Link
    let fireAt: Date
}

enum WorkspaceMoveDirection {
    case left
    case right
}
