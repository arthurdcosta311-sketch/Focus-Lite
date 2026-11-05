//
//  Focus_LiteTests.swift
//  Focus LiteTests
//

import Foundation
import Testing
import WebKit
@testable import Focus_Lite

struct Focus_LiteTests {
    @Test func popupBlockerDefaultsToEnabledAndCanBeDisabled() {
        let suiteName = "FocusLiteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PopupBlocker.isEnabled(in: defaults))
        PopupBlocker.setEnabled(false, in: defaults)
        #expect(!PopupBlocker.isEnabled(in: defaults))
    }

    @Test func popupBlockerKeepsTappedLinksAndBlocksOtherWindows() {
        let allowedSites: Set<String> = []
        #expect(!PopupBlocker.shouldBlock(
            sourceHost: "example.com",
            destinationURL: URL(string: "https://example.net"),
            navigationType: .linkActivated,
            isEnabled: true,
            allowedSites: allowedSites
        ))
        #expect(PopupBlocker.shouldBlock(
            sourceHost: "example.com",
            destinationURL: URL(string: "https://popup.example.net"),
            navigationType: .other,
            isEnabled: true,
            allowedSites: allowedSites
        ))
        #expect(!PopupBlocker.shouldBlock(
            sourceHost: "example.com",
            destinationURL: URL(string: "https://popup.example.net"),
            navigationType: .other,
            isEnabled: false,
            allowedSites: allowedSites
        ))
    }

    @Test func trustedSiteCanBeAllowedForTheCurrentSession() {
        #expect(!PopupBlocker.shouldBlock(
            sourceHost: "example.com",
            destinationURL: URL(string: "https://popup.example.net"),
            navigationType: .other,
            isEnabled: true,
            allowedSites: ["example.com"]
        ))
        #expect(PopupBlocker.normalizedHost(" Example.COM. ") == "example.com")
        #expect(PopupBlocker.normalizedHost(nil) == nil)
    }

    @Test func knownPopupAdHostsAreBlocked() {
        #expect(PopupBlocker.shouldBlock(
            sourceHost: "example.com",
            destinationURL: URL(string: "https://ads.doubleclick.net"),
            navigationType: .linkActivated,
            isEnabled: true,
            allowedSites: []
        ))
        #expect(!PopupBlocker.shouldBlock(
            sourceHost: "example.com",
            destinationURL: URL(string: "https://ads.doubleclick.net"),
            navigationType: .linkActivated,
            isEnabled: false,
            allowedSites: []
        ))
    }

    @Test func trackerAuditUsesTheUniqueBlockingDomainList() {
        #expect(Set(TrackerBlocker.blockedTrackers).count == TrackerBlocker.blockedTrackers.count)
        for domain in TrackerBlocker.blockedTrackers {
            #expect(TrackerBlocker.auditScript.contains("\"\(domain)\""))
        }
    }

    @Test @MainActor func browserLogIsBoundedAndCanBeCleared() {
        let store = BrowserLogStore(limit: 3)
        for index in 0...3 {
            store.record("Event \(index)")
        }

        #expect(store.entries.count == 3)
        #expect(store.entries.last?.message == "Event 3")
        store.clear()
        #expect(store.entries.isEmpty)
    }

    private func makeTestDefaults() -> (UserDefaults, String) {
        let suiteName = "FocusLiteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    @Test func searchEngineChoicesPersistAndBuildQueryURLs() {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CustomizationStore(defaults: defaults)
        // Focus Search is the default engine now; URL building is pinned to
        // the classic engines explicitly.
        store.searchEngine = .duckduckgo
        #expect(store.searchURL(for: "privacy browser")?.host == "duckduckgo.com")
        #expect(store.searchURL(for: "privacy browser")?.query == "q=privacy%20browser")

        store.searchEngine = .custom
        store.customSearchTemplate = "https://search.example.com/find?term=%s"
        let url = store.searchURL(for: "cute cats & dogs")
        #expect(url?.host == "search.example.com")
        #expect(url?.query == "term=cute%20cats%20%26%20dogs")

        // A template without %s or an http(s) scheme is refused.
        store.customSearchTemplate = "search.example.com/%s"
        #expect(store.searchURL(for: "x") == nil)
    }

    @Test func homepageAcceptsSchemelessAddressesAndCanBeDisabled() {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CustomizationStore(defaults: defaults)
        #expect(store.homepageURL() == nil)

        store.homepageEnabled = true
        store.homepageText = "example.com/news"
        #expect(store.homepageURL()?.host == "example.com")

        store.homepageEnabled = false
        #expect(store.homepageURL() == nil)
    }

    @Test func customizationChoicesPersistAcrossInstances() {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = CustomizationStore(defaults: defaults)
        store.accent = .mint
        store.pageZoom = 1.5
        store.christmasMode = false

        #expect(CustomizationStore(defaults: defaults).accent == .mint)
        #expect(CustomizationStore(defaults: defaults).pageZoom == 1.5)
        #expect(!CustomizationStore(defaults: defaults).christmasMode)
    }

    /// Christmas mode is on by default: a fresh install has no stored choice
    /// yet and gets the festive look, while a stored opt-out is respected.
    @Test func christmasModeIsOnByDefault() {
        let (defaults, suiteName) = makeTestDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(CustomizationStore(defaults: defaults).christmasMode)

        let store = CustomizationStore(defaults: defaults)
        store.christmasMode = false
        #expect(!CustomizationStore(defaults: defaults).christmasMode)
    }

    /// Domain-shaped input is a site candidate that gets resolved before the
    /// browser decides between opening it and searching; sentences and
    /// non-domain dotted terms never become site addresses.
    @Test func domainShapedInputBecomesSiteAddresses() {
        #expect(BrowserModel.siteURL(for: "example.com")?.host == "example.com")
        #expect(BrowserModel.siteURL(for: "Example.COM")?.host == "example.com")
        #expect(BrowserModel.siteURL(for: "example.com/shop")?.host == "example.com")
        #expect(BrowserModel.siteURL(for: "1.2.3.4")?.host == "1.2.3.4")

        #expect(BrowserModel.siteURL(for: "hello world.com") == nil)
        #expect(BrowserModel.siteURL(for: "3.14") == nil)
        #expect(BrowserModel.siteURL(for: "cute cats") == nil)
        #expect(BrowserModel.siteURL(for: "localhost") == nil)
    }

    /// The alternate icon only works when the build declares it: the asset
    /// catalog compiler must include the Minimal set, or the car never
    /// contains it and setAlternateIconName fails at runtime.
    @Test func alternateAppIconIsDeclared() {
        let alternateIcons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any]
        let minimal = (alternateIcons?["CFBundleAlternateIcons"] as? [String: Any])?["Minimal"]
        #expect(minimal != nil)
    }

}
