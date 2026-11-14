import Foundation
import Testing
@testable import SidebArcCore

/// `BrowserManager.resolveTarget`: link override → profile's browser → global default.
@Suite struct BrowserResolverTests {
    private let chrome = "com.google.Chrome"
    private let firefox = "org.mozilla.firefox"
    private let safari = "com.apple.Safari"

    private func link(override: String? = nil) -> Link {
        var link = Link(id: UUID(), title: "L", url: "https://example.com", faviconPath: nil)
        link.browserBundleId = override
        return link
    }

    @Test func noOverridesUsesGlobalDefaultWithProfileDir() {
        let profile = Profile(name: "P", browserProfiles: [chrome: "Profile 1", firefox: "work"])
        let target = BrowserManager.resolveTarget(link: link(), profile: profile, globalDefault: chrome)
        #expect(target == BrowserTarget(bundleId: chrome, profileDir: "Profile 1"))
    }

    @Test func profileBrowserBeatsGlobalDefault() {
        let profile = Profile(name: "P", browserBundleId: firefox, browserProfiles: [chrome: "Profile 1", firefox: "work"])
        let target = BrowserManager.resolveTarget(link: link(), profile: profile, globalDefault: chrome)
        #expect(target == BrowserTarget(bundleId: firefox, profileDir: "work"))
    }

    @Test func linkOverrideToAnotherBrowserDropsProfileDir() {
        let profile = Profile(name: "P", browserBundleId: firefox, browserProfiles: [chrome: "Profile 1", firefox: "work"])
        let target = BrowserManager.resolveTarget(link: link(override: chrome), profile: profile, globalDefault: safari)
        #expect(target == BrowserTarget(bundleId: chrome, profileDir: nil))
    }

    @Test func linkOverrideToTheProfileBrowserKeepsProfileDir() {
        let profile = Profile(name: "P", browserBundleId: firefox, browserProfiles: [firefox: "work"])
        let target = BrowserManager.resolveTarget(link: link(override: firefox), profile: profile, globalDefault: chrome)
        #expect(target == BrowserTarget(bundleId: firefox, profileDir: "work"))
    }

    @Test func linkOverrideMatchingInheritedGlobalDefaultKeepsProfileDir() {
        // The profile inherits the global browser; overriding to that same browser is a no-op.
        let profile = Profile(name: "P", browserProfiles: [chrome: "Profile 1"])
        let target = BrowserManager.resolveTarget(link: link(override: chrome), profile: profile, globalDefault: chrome)
        #expect(target == BrowserTarget(bundleId: chrome, profileDir: "Profile 1"))
    }

    @Test func bundleIdComparisonIsCaseInsensitive() {
        let profile = Profile(name: "P", browserBundleId: chrome, browserProfiles: [chrome: "Profile 1"])
        let target = BrowserManager.resolveTarget(link: link(override: chrome.lowercased()), profile: profile, globalDefault: nil)
        #expect(target.profileDir == "Profile 1")
    }

    @Test func nothingConfiguredFallsBackToSystemHandler() {
        let target = BrowserManager.resolveTarget(link: nil, profile: Profile(name: "P"), globalDefault: nil)
        #expect(target == BrowserTarget(bundleId: nil, profileDir: nil))
    }

    @Test func noLinkResolvesTheProfileItself() {
        let profile = Profile(name: "P", browserBundleId: firefox, browserProfiles: [firefox: "work"])
        let target = BrowserManager.resolveTarget(link: nil, profile: profile, globalDefault: chrome)
        #expect(target == BrowserTarget(bundleId: firefox, profileDir: "work"))
    }
}
