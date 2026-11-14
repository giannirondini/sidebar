import Foundation

/// Reads only the `schemaVersion` of a `data.json`, so `DataStore` can pick the decoder.
struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int
}

/// Read-only mirror of the schema v1 `data.json` (Arcmark 0.1.x layout).
/// Used only to feed `SchemaMigration.v1ToV2`; never encoded.
enum SchemaV1 {
    struct AppState: Decodable {
        var schemaVersion: Int
        var workspaces: [Workspace]
        var selectedWorkspaceId: UUID?
        var isSettingsSelected: Bool

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, workspaces, selectedWorkspaceId, isSettingsSelected
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            workspaces = try container.decode([Workspace].self, forKey: .workspaces)
            selectedWorkspaceId = try container.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceId)
            isSettingsSelected = try container.decodeIfPresent(Bool.self, forKey: .isSettingsSelected) ?? false
        }
    }

    struct Workspace: Decodable {
        var id: UUID
        var name: String
        var colorId: WorkspaceColorId
        var items: [Node]
        var pinnedLinks: [Link]
        var browserProfiles: [String: String]

        private enum CodingKeys: String, CodingKey {
            case id, name, colorId, items, pinnedLinks, browserProfiles
            // Pre-dictionary layout: one profile for one browser.
            case browserProfile, browserProfileBundleId
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            colorId = try container.decode(WorkspaceColorId.self, forKey: .colorId)
            items = try container.decode([Node].self, forKey: .items)
            pinnedLinks = try container.decodeIfPresent([Link].self, forKey: .pinnedLinks) ?? []
            if let profiles = try container.decodeIfPresent([String: String].self, forKey: .browserProfiles) {
                browserProfiles = profiles
            } else if let profile = try container.decodeIfPresent(String.self, forKey: .browserProfile),
                      let bundleId = try container.decodeIfPresent(String.self, forKey: .browserProfileBundleId) {
                browserProfiles = [bundleId: profile]
            } else {
                browserProfiles = [:]
            }
        }
    }
}

enum SchemaMigration {
    /// Name of the folder that receives favorites that did not fit (duplicates or over the cap).
    static let migratedFavoritesFolderName = "Favorites (migrated)"

    /// Upgrades a v1 state to v2. Pure: no I/O, no `UserDefaults`.
    ///
    /// - Spaces with an identical `browserProfiles` dictionary share one `Profile`,
    ///   created in order of first appearance ("Default", "Profile 2", …).
    /// - Each profile's favorites are its spaces' `pinnedLinks`, in space order,
    ///   deduplicated by `URLNormalization.key` and capped at `Profile.maxFavorites`.
    /// - Links that don't make it go into a "Favorites (migrated)" folder at the top
    ///   of the space they came from. Nothing is dropped.
    /// - `browserBundleId` stays `nil` and the dictionary is copied unchanged, so every
    ///   space opens links exactly where it did in v1, whatever the global browser is.
    static func v1ToV2(_ old: SchemaV1.AppState) -> AppState {
        var profiles: [Profile] = []
        var profileIndexByBrowserProfiles: [[String: String]: Int] = [:]
        var workspaces: [Workspace] = []

        for oldWorkspace in old.workspaces {
            let profileIndex: Int
            if let existing = profileIndexByBrowserProfiles[oldWorkspace.browserProfiles] {
                profileIndex = existing
            } else {
                let name = profiles.isEmpty ? Profile.defaultName : "Profile \(profiles.count + 1)"
                profiles.append(Profile(name: name, browserProfiles: oldWorkspace.browserProfiles))
                profileIndex = profiles.count - 1
                profileIndexByBrowserProfiles[oldWorkspace.browserProfiles] = profileIndex
            }

            let leftovers = profiles[profileIndex].appendFavorites(oldWorkspace.pinnedLinks)
            var items = oldWorkspace.items
            if !leftovers.isEmpty {
                let folder = Folder(
                    id: UUID(),
                    name: migratedFavoritesFolderName,
                    children: leftovers.map { .link($0) },
                    isExpanded: true
                )
                items.insert(.folder(folder), at: 0)
            }

            workspaces.append(Workspace(
                id: oldWorkspace.id,
                name: oldWorkspace.name,
                colorId: oldWorkspace.colorId,
                items: items,
                profileId: profiles[profileIndex].id
            ))
        }

        return AppState(
            schemaVersion: 2,
            profiles: profiles,
            workspaces: workspaces,
            selectedWorkspaceId: old.selectedWorkspaceId,
            isSettingsSelected: old.isSettingsSelected
        ).repaired()
    }
}
