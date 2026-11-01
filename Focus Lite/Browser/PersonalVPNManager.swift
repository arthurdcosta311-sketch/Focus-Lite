//
//  PersonalVPNManager.swift
//  Focus Lite
//

import Combine
import NetworkExtension
import Security

/// Configures an iOS-managed IKEv2 Personal VPN using the user's own server.
/// The system owns the tunnel and its status; this app does not provide a VPN
/// server or claim a connection until iOS reports the tunnel as connected.
final class PersonalVPNManager: ObservableObject {
    static let shared = PersonalVPNManager()

    @Published var serverAddress = ""
    @Published var remoteIdentifier = ""
    @Published var username = ""
    @Published private(set) var connectionStatus: NEVPNStatus = .invalid
    @Published private(set) var isReady = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?

    private let manager = NEVPNManager.shared()
    private var statusObserver: NSObjectProtocol?

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.connectionStatus = self.manager.connection.status
        }
        loadConfiguration()
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    var statusDescription: String {
        switch connectionStatus {
        case .invalid: return "Unavailable"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .reasserting: return "Reconnecting"
        case .disconnecting: return "Disconnecting"
        @unknown default: return "Unknown"
        }
    }

    var isActiveOrConnecting: Bool {
        switch connectionStatus {
        case .connecting, .connected, .reasserting, .disconnecting: return true
        default: return false
        }
    }

    func loadConfiguration() {
        manager.loadFromPreferences { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectionStatus = self.manager.connection.status
                if let error {
                    self.errorMessage = error.localizedDescription
                    self.isReady = true
                    return
                }
                if let configuration = self.manager.protocolConfiguration as? NEVPNProtocolIKEv2 {
                    self.serverAddress = configuration.serverAddress ?? ""
                    self.remoteIdentifier = configuration.remoteIdentifier ?? configuration.serverAddress ?? ""
                    self.username = configuration.username ?? ""
                }
                self.isReady = true
            }
        }
    }

    /// Saves the IKEv2 profile, then asks iOS to start its managed tunnel.
    /// Password bytes are stored in the keychain and referenced by the VPN
    /// profile rather than written to app preferences or source files.
    func connect(password: String) {
        guard isReady, !isWorking else { return }
        errorMessage = nil

        let server = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteIDInput = remoteIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteID = remoteIDInput.isEmpty ? server : remoteIDInput

        guard !server.isEmpty, !server.contains("://"), !server.contains("/"), !server.contains(" ") else {
            errorMessage = "Enter a VPN server host name or IP address without a URL scheme."
            return
        }
        guard !user.isEmpty else {
            errorMessage = "Enter the username supplied by your VPN provider."
            return
        }

        let existing = manager.protocolConfiguration as? NEVPNProtocolIKEv2
        let passwordReference: Data
        if !password.isEmpty {
            guard let savedReference = VPNPasswordStore.save(password) else {
                errorMessage = "The VPN password could not be saved securely in the keychain."
                return
            }
            passwordReference = savedReference
        } else if let existing,
                  existing.serverAddress == server,
                  existing.remoteIdentifier == remoteID,
                  existing.username == user,
                  let savedReference = existing.passwordReference {
            passwordReference = savedReference
        } else {
            errorMessage = "Enter the VPN password the first time you connect or when changing credentials."
            return
        }

        let configuration = NEVPNProtocolIKEv2()
        configuration.serverAddress = server
        configuration.remoteIdentifier = remoteID
        configuration.username = user
        configuration.authenticationMethod = .none
        configuration.useExtendedAuthentication = true
        configuration.passwordReference = passwordReference
        configuration.disconnectOnSleep = false

        manager.localizedDescription = "Focus Lite"
        manager.protocolConfiguration = configuration
        manager.isEnabled = true
        isWorking = true

        manager.saveToPreferences { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.finishWithError(error)
                    return
                }
                self.manager.loadFromPreferences { loadError in
                    DispatchQueue.main.async {
                        if let loadError {
                            self.finishWithError(loadError)
                            return
                        }
                        do {
                            try self.manager.connection.startVPNTunnel()
                            self.errorMessage = nil
                        } catch {
                            self.errorMessage = error.localizedDescription
                        }
                        self.connectionStatus = self.manager.connection.status
                        self.isWorking = false
                    }
                }
            }
        }
    }

    func disconnect() {
        manager.connection.stopVPNTunnel()
        connectionStatus = manager.connection.status
    }

    private func finishWithError(_ error: Error) {
        errorMessage = error.localizedDescription
        connectionStatus = manager.connection.status
        isWorking = false
    }
}

private enum VPNPasswordStore {
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "FocusLite") + ".personal-vpn"
    }

    private static let account = "ikev2-password"

    static func save(_ password: String) -> Data? {
        guard let passwordData = password.data(using: .utf8) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: passwordData]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = passwordData
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return nil }

        var referenceQuery = query
        referenceQuery[kSecReturnPersistentRef as String] = true
        referenceQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(referenceQuery as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }
}
