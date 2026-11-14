import Foundation
import Testing
@testable import SidebArcCore

/// `BrowserManager.resolveTarget`: link override → profile's browser → global default.
@Suite struct BrowserResolverTests {
    private let chrome = "com.google.Chrome"
    private let firefox = "org.mozilla.firefox"
    private let safari = "com.apple.Safari"

    /// Every bundle id counts as installed unless `missing` lists it.
    private func resolve(link: Link?, profile: Profile, globalDefault: String?, missing: Set<String> = []) -> BrowserTarget {
        BrowserManager.resolveTarget(link: link, profile: profile, globalDefault: globalDefault, installed: { !missing.contains($0) })
    }

    private func link(override: String? = nil) -> Link {
        var link = Link(id: UUID(), title: "L", url: "https://example.com", faviconPath: nil)
        link.browserBundleId = override
        return link
    }

    @Test func noOverridesUsesGlobalDefaultWithProfileDir() {
        let profile = Profile(name: "P", browserProfiles: [chrome: "Profile 1", firefox: "work"])
        let target = resolve(link: link(), profile: profile, globalDefault: chrome)
        #expect(target == BrowserTarget(bundleId: chrome, profileDir: "Profile 1"))
    }

    @Test func profileBrowserBeatsGlobalDefault() {
        let profile = Profile(name: "P", browserBundleId: firefox, browserProfiles: [chrome: "Profile 1", firefox: "work"])
        let target = resolve(link: link(), profile: profile, globalDefault: chrome)
        #expect(target == BrowserTarget(bundleId: firefox, profileDir: "work"))
    }

    @Test func linkOverrideToAnotherBrowserDropsProfileDir() {
        let profile = Profile(name: "P", browserBundleId: firefox, browserProfiles: [chrome: "Profile 1", firefox: "work"])
        let target = resolve(link: link(override: chrome), profile: profile, globalDefault: safari)
        #expect(target == BrowserTarget(bundleId: chrome, profileDir: nil))
    }

    @Test func linkOverrideToTheProfileBrowserKeepsProfileDir() {
        let profile = Profile(name: "P", browserBundleId: firefox, browserProfiles: [firefox: "work"])
        let target = resolve(link: link(override: firefox), profile: profile, globalDefault: chrome)
        #expect(target == BrowserTarget(bundleId: firefox, profileDir: "work"))
    }

    @Test func linkOverrideMatchingInheritedGlobalDefaultKeepsProfileDir() {
        // The profile inherits the global browser; overriding to that same browser is a no-op.
        let profile = Profile(name: "P", browserProfiles: [chrome: "Profile 1"])
        let target = resolve(link: link(override: chrome), profile: profile, globalDefault: chrome)
        #expect(target == BrowserTarget(bundleId: chrome, profileDir: "Profile 1"))
    }

    @Test func bundleIdComparisonIsCaseInsensitive() {
        let profile = Profile(name: "P", browserBundleId: chrome, browserProfiles: [chrome: "Profile 1"])
        let target = resolve(link: link(override: chrome.lowercased()), profile: profile, globalDefault: nil)
        #expect(target.profileDir == "Profile 1")
    }

    @Test func nothingConfiguredFallsBackToSystemHandler() {
        let target = resolve(link: nil, profile: Profile(name: "P"), globalDefault: nil)
        #expect(target == BrowserTarget(bundleId: nil, profileDir: nil))
    }

    @Test func noLinkResolvesTheProfileItself() {
        let profile = Profile(name: "P", browserBundleId: firefox, browserProfiles: [firefox: "work"])
        let target = resolve(link: nil, profile: profile, globalDefault: chrome)
        #expect(target == BrowserTarget(bundleId: firefox, profileDir: "work"))
    }

    // MARK: - Missing browsers (not installed on this Mac)

    @Test func missingLinkOverrideFallsBackToProfileBrowser() {
        let profile = Profile(name: "P", browserBundleId: firefox, browserProfiles: [firefox: "work"])
        let target = resolve(link: link(override: chrome), profile: profile, globalDefault: safari, missing: [chrome])
        #expect(target == BrowserTarget(bundleId: firefox, profileDir: "work"))
    }

    @Test func missingProfileBrowserFallsBackToGlobalDefaultWithItsDir() {
        let profile = Profile(name: "P", browserBundleId: firefox, browserProfiles: [firefox: "work", chrome: "Profile 1"])
        let target = resolve(link: link(), profile: profile, globalDefault: chrome, missing: [firefox])
        #expect(target == BrowserTarget(bundleId: chrome, profileDir: "Profile 1"))
    }

    @Test func missingOverrideAndProfileBrowserEndAtGlobalDefault() {
        let profile = Profile(name: "P", browserBundleId: firefox)
        let target = resolve(link: link(override: chrome), profile: profile, globalDefault: safari, missing: [chrome, firefox])
        #expect(target == BrowserTarget(bundleId: safari, profileDir: nil))
    }
}
