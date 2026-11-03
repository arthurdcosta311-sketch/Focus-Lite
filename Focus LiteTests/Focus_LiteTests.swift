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

        #expect(CustomizationStore(defaults: defaults).accent == .mint)
        #expect(CustomizationStore(defaults: defaults).pageZoom == 1.5)
    }

}
