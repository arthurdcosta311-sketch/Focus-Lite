//
//  PopupBlocker.swift
//  Focus Lite
//

import Foundation
import WebKit

enum PopupBlocker {
    static let enabledPreferenceKey = "focusLite.popupBlocker.enabled"

    private static let blockedHosts = [
        "doubleclick.net", "googlesyndication.com", "popads.net", "popcash.net",
        "propellerads.com", "onclickads.net", "adsterra.com", "adcash.com",
        "zedo.com", "adnxs.com", "popmyads.com", "exoclick.com", "juicyads.com"
    ]

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledPreferenceKey) as? Bool ?? true
    }

    static func isEnabled() -> Bool {
        isEnabled(in: .standard)
    }

    static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledPreferenceKey)
    }

    static func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }

    /// Keeps ordinary tapped links in the current tab. Other new-window
    /// requests are refused unless blocking is disabled or the source site is
    /// in the in-memory session allowlist.
    static func shouldBlock(sourceHost: String?, destinationURL: URL?,
                            navigationType: WKNavigationType, isEnabled: Bool,
                            allowedSites: Set<String>) -> Bool {
        guard isEnabled else { return false }
        if isBlockedHost(destinationURL) { return true }
        guard navigationType != .linkActivated else { return false }
        guard let sourceHost = normalizedHost(sourceHost) else { return true }
        return !allowedSites.contains(sourceHost)
    }

    static func shouldBlock(url: URL?, navigationType: WKNavigationType, enabled: Bool,
                            sourceHost: String? = nil, allowedSites: Set<String> = []) -> Bool {
        shouldBlock(
            sourceHost: sourceHost,
            destinationURL: url,
            navigationType: navigationType,
            isEnabled: enabled,
            allowedSites: allowedSites
        )
    }

    static func isBlockedHost(_ url: URL?) -> Bool {
        guard let host = normalizedHost(url?.host) else { return false }
        return blockedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
