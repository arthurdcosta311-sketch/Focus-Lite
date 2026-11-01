//
//  EncryptedDNSManager.swift
//  Focus Lite
//

import Combine
import NetworkExtension

/// VPN-grade network privacy without a VPN server: routes every DNS lookup on
/// the device over DNS-over-HTTPS to a public resolver run by an open-source
/// project (Cloudflare's 1.1.1.1, Quad9 or Google), so networks and ISPs can't
/// see or log which sites are visited, and DNS-based tracking fails. Built on
/// Apple's NEDNSSettingsManager, so it covers WebKit's browsing too — no VPN
/// app, account or tunnel server required. A full encrypted tunnel (WireGuard
/// and friends) needs a packet-tunnel extension and server infrastructure,
/// which a lightweight browser can't ship.
final class EncryptedDNSManager: ObservableObject {
    static let shared = EncryptedDNSManager()

    @Published private(set) var isEnabled = false
    @Published var resolver: Resolver = .cloudflare {
        didSet {
            if isEnabled { enable() }
        }
    }

    enum Resolver: String, CaseIterable, Identifiable {
        case cloudflare = "Cloudflare (1.1.1.1)"
        case quad9 = "Quad9 (9.9.9.9)"
        case google = "Google (8.8.8.8)"

        var id: String { rawValue }

        var serverURL: URL {
            switch self {
            case .cloudflare: return URL(string: "https://cloudflare-dns.com/dns-query")!
            case .quad9: return URL(string: "https://dns.quad9.net/dns-query")!
            case .google: return URL(string: "https://dns.google/dns-query")!
            }
        }

        var servers: [String] {
            switch self {
            case .cloudflare: return ["1.1.1.1", "1.0.0.1"]
            case .quad9: return ["9.9.9.9", "149.112.112.112"]
            case .google: return ["8.8.8.8", "8.8.4.4"]
            }
        }
    }

    private let manager = NEDNSSettingsManager.shared()
    private let resolverKey = "focusLite.encryptedDNS.resolver"

    private init() {
        // Follow the system's real state in case it was changed outside the app.
        manager.loadFromPreferences { [weak self] _ in
            guard let self else { return }
            self.isEnabled = self.manager.dnsSettings != nil
            if let raw = UserDefaults.standard.string(forKey: self.resolverKey),
               let stored = Resolver(rawValue: raw) {
                self.resolver = stored
            }
        }
    }

    /// Toggles encrypted DNS. iOS shows its own system prompt the first time
    /// DNS settings are saved.
    func toggle() {
        isEnabled ? disable() : enable()
    }

    private func enable() {
        let settings = NEDNSOverHTTPSSettings(servers: resolver.servers)
        settings.serverURL = resolver.serverURL
        manager.dnsSettings = settings
        save(resultingIn: true)
    }

    private func disable() {
        manager.dnsSettings = nil
        save(resultingIn: false)
    }

    private func save(resultingIn enabled: Bool) {
        manager.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if error == nil {
                    self.isEnabled = enabled
                    UserDefaults.standard.set(self.resolver.rawValue, forKey: self.resolverKey)
                } else {
                    // Re-read what the system actually applied.
                    self.manager.loadFromPreferences { _ in
                        DispatchQueue.main.async {
                            self.isEnabled = self.manager.dnsSettings != nil
                        }
                    }
                }
            }
        }
    }
}
