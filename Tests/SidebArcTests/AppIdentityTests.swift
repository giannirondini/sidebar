import AppKit
import Foundation
import Testing
@testable import SidebArcCore

/// Guards the fork's runtime isolation from Arcmark.
@Suite struct AppIdentityTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SidebArcTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    /// The build scripts read the id from Bundler.toml; Swift can't, so it keeps a copy.
    @Test func swiftBundleIdentifierMatchesBundlerToml() throws {
        let toml = try String(contentsOf: repoRoot.appendingPathComponent("Bundler.toml"), encoding: .utf8)
        let line = try #require(
            toml.split(separator: "\n").first { $0.hasPrefix("identifier = ") },
            "No `identifier = ` line in Bundler.toml"
        )
        let value = line
            .dropFirst("identifier = ".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
        #expect(value == AppIdentity.bundleIdentifier)
    }

    /// `[apps.<name>]` names the .app and its executable; the window and menus use `displayName`.
    @Test func displayNameMatchesBundlerTomlAppName() throws {
        let toml = try String(contentsOf: repoRoot.appendingPathComponent("Bundler.toml"), encoding: .utf8)
        let appTables = toml
            .split(separator: "\n")
            .filter { $0.hasPrefix("[apps.") && $0.hasSuffix("]") && !$0.dropFirst("[apps.".count).contains(".") }
            .map { String($0.dropFirst("[apps.".count).dropLast()) }
        #expect(appTables == [AppIdentity.displayName])
    }

    @Test func identityIsNotArcmark() {
        #expect(!AppIdentity.bundleIdentifier.lowercased().contains("arcmark"))
        #expect(!AppIdentity.dataDirectoryName.lowercased().contains("arcmark"))
        #expect(!AppIdentity.logSubsystem.lowercased().contains("arcmark"))
        #expect(!AppIdentity.displayName.lowercased().contains("arcmark"))
        #expect(!AppIdentity.releasesURL.absoluteString.lowercased().contains("arcmark"))
    }

    /// Only computes a path; nothing is written to the real Application Support.
    @Test func defaultDataDirectoryIsNamedAfterBundleIdentifier() throws {
        let appSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let endpointDir = DataStore().agentEndpointFileURL().deletingLastPathComponent()
        let expected = appSupport.appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
        #expect(endpointDir.standardizedFileURL.path == expected.standardizedFileURL.path)
    }

    /// The agent skill CLI finds the running app through `agent-endpoint.json` in the data dir.
    @Test func agentSkillCLIReadsEndpointFromForkDataDirectory() throws {
        let cli = try String(
            contentsOf: repoRoot.appendingPathComponent("skills/sidebarc/scripts/sidebarc.js"),
            encoding: .utf8
        )
        #expect(cli.contains("'\(AppIdentity.dataDirectoryName)',\n  'agent-endpoint.json'"))
        #expect(!cli.lowercased().contains("arcmark"))
    }

    /// Distinct pasteboard types stop drag-and-drop crossing between the two apps.
    @Test func pasteboardTypesUseForkIdentifier() {
        #expect(nodePasteboardType.rawValue == "\(AppIdentity.bundleIdentifier).node")
        #expect(workspacePasteboardType.rawValue == "\(AppIdentity.bundleIdentifier).workspace")
    }
}
