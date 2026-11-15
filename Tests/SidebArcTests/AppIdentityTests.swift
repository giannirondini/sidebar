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

    private func bundlerValue(_ key: String) throws -> String {
        let toml = try String(contentsOf: repoRoot.appendingPathComponent("Bundler.toml"), encoding: .utf8)
        let line = try #require(toml.split(separator: "\n").first { $0.hasPrefix("\(key) = ") }, "No `\(key) = ` line in Bundler.toml")
        return String(line.dropFirst("\(key) = ".count)).trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
    }

    /// `build.sh` writes both; a release built from a stale one carries the wrong version.
    @Test func bundlerVersionMatchesVersionFile() throws {
        let version = try String(contentsOf: repoRoot.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(try bundlerValue("version") == version)
        #expect(version.split(separator: ".").count == 3 && version.split(separator: ".").allSatisfy { Int($0) != nil })
    }

    /// `app-config.sh` reads the usage text with a one-line, single-quoted `sed`; the
    /// text must stay in that shape, and say what the Apple Events are for.
    @Test func appleEventsUsageDescriptionIsReadableByTheScripts() throws {
        let toml = try String(contentsOf: repoRoot.appendingPathComponent("Bundler.toml"), encoding: .utf8)
        let lines = toml.split(separator: "\n").filter { $0.hasPrefix("NSAppleEventsUsageDescription = ") }
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        let value = line.dropFirst("NSAppleEventsUsageDescription = ".count)
        #expect(value.hasPrefix("'") && value.hasSuffix("'") && value.dropFirst().dropLast().allSatisfy { $0 != "'" })
        #expect(value.contains(AppIdentity.displayName))
        #expect(value.localizedCaseInsensitiveContains("tab"))
    }

    /// The release instructions (`create-dmg.sh`) and "Check for Updates…" must
    /// point at the same repository.
    @Test func releaseScriptRepositoryMatchesReleasesURL() throws {
        let script = try String(contentsOf: repoRoot.appendingPathComponent("scripts/create-dmg.sh"), encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.hasPrefix("REPO_URL=") })
        let repo = line.dropFirst("REPO_URL=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        #expect("\(repo)/releases" == AppIdentity.releasesURL.absoluteString)
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
