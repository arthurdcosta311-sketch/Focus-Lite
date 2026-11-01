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

}
