//
//  SettingsSheet.swift
//  Focus Lite
//

import NetworkExtension
import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var manager: TabManager
    @ObservedObject private var extManager = ExtensionManager.shared
    @ObservedObject private var dnsManager = EncryptedDNSManager.shared
    @ObservedObject private var vpnManager = PersonalVPNManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var vpnPassword = ""

    private var vpnFieldsLocked: Bool {
        switch vpnManager.connectionStatus {
        case .connecting, .connected, .reasserting, .disconnecting: return true
        default: return false
        }
    }

    private var vpnStatusColor: Color {
        switch vpnManager.connectionStatus {
        case .connected: return Theme.accent
        case .connecting, .reasserting, .disconnecting: return .orange
        case .invalid: return .red
        default: return .secondary
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(extManager.extensions) { ext in
                        extensionRow(ext)
                    }
                    Button {
                        extManager.reload()
                        manager.refreshAllExtensions()
                    } label: {
                        Label("Rescan extensions folder", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Chrome-style extensions")
                } footer: {
                    Text("Add your own: create a folder in Files → Focus Lite → Extensions containing a Chrome manifest.json (MV2 or MV3) with content scripts or a background script written in JavaScript or Lua (.lua files run on an embedded Lua VM and use the global focus table), then rescan. Toggles apply to the next page load.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { manager.isIncognito },
                        set: { _ in manager.toggleIncognito() }
                    )) {
                        Label("Incognito mode", systemImage: "eyeglasses")
                            .foregroundStyle(manager.isIncognito ? Theme.incognito : .primary)
                    }

                    Toggle(isOn: $manager.popupBlockerEnabled) {
                        Label("Block pop-ups", systemImage: "hand.raised")
                    }

                    Toggle(isOn: Binding(
                        get: { dnsManager.isEnabled },
                        set: { _ in dnsManager.toggle() }
                    )) {
                        Label("Encrypted DNS", systemImage: "lock.shield")
                            .foregroundStyle(dnsManager.isEnabled ? Theme.accent : .primary)
                    }
                    if dnsManager.isEnabled {
                        Picker("Resolver", selection: $dnsManager.resolver) {
                            ForEach(EncryptedDNSManager.Resolver.allCases) { resolver in
                                Text(resolver.rawValue).tag(resolver)
                            }
                        }
                    }
                    if let host = manager.activeTab?.model.displayedURL?.host {
                        Button {
                            manager.togglePopupAllowance(for: host)
                        } label: {
                            Label(
                                manager.isPopupSiteAllowed(host)
                                    ? "Stop allowing pop-ups for \(host)"
                                    : "Allow pop-ups for \(host)",
                                systemImage: manager.isPopupSiteAllowed(host) ? "xmark.circle" : "checkmark.circle"
                            )
                        }
                        .disabled(!manager.popupBlockerEnabled && !manager.isPopupSiteAllowed(host))
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Incognito tints the interface and hides page content in the app switcher; switching modes wipes the session. Pop-ups from script-opened windows are blocked by default, while tapped links stay in the current tab. Encrypted DNS protects lookups from the local network, but the resolver can see them; it is not a VPN.")
                }

                if !manager.allowedPopupSites.isEmpty {
                    Section {
                        ForEach(manager.allowedPopupSites.sorted(), id: \.self) { site in
                            HStack {
                                Label(site, systemImage: "globe")
                                    .lineLimit(1)
                                Spacer()
                                Button("Remove") {
                                    manager.togglePopupAllowance(for: site)
                                }
                                .font(.subheadline)
                            }
                        }
                    } header: {
                        Text("Allowed pop-up sites · this session")
                    } footer: {
                        Text("These exceptions are held in memory only and are cleared when browsing data is erased or incognito mode changes.")
                    }
                }

                Section {
                    HStack {
                        Text("Connection")
                        Spacer()
                        Circle()
                            .fill(vpnStatusColor)
                            .frame(width: 8, height: 8)
                        Text(vpnManager.statusDescription)
                            .foregroundStyle(vpnStatusColor)
                    }
                    TextField("VPN server host or IP", text: $vpnManager.serverAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(vpnFieldsLocked)
                    TextField("IKEv2 remote identifier", text: $vpnManager.remoteIdentifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(vpnFieldsLocked)
                    TextField("Username", text: $vpnManager.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(vpnFieldsLocked)
                    SecureField("VPN password (saved to Keychain)", text: $vpnPassword)
                        .disabled(vpnFieldsLocked)

                    if let error = vpnManager.errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    if vpnManager.isActiveOrConnecting {
                        Button(role: .destructive) {
                            vpnManager.disconnect()
                        } label: {
                            Label("Disconnect VPN", systemImage: "stop.circle")
                        }
                    } else {
                        Button {
                            vpnManager.connect(password: vpnPassword)
                            vpnPassword = ""
                        } label: {
                            if vpnManager.isWorking {
                                HStack {
                                    ProgressView()
                                    Text("Saving VPN settings…")
                                }
                            } else {
                                Label("Connect to my VPN", systemImage: "lock.shield")
                            }
                        }
                        .disabled(!vpnManager.isReady || vpnManager.isWorking)
                    }
                } header: {
                    Text("Personal VPN · IKEv2")
                } footer: {
                    Text("Use a compatible VPN server and credentials you already have. iOS may ask you to approve the VPN configuration. Focus Lite does not provide a VPN server; connection status reflects the actual iOS tunnel. Setup also requires the Personal VPN entitlement and matching signing.")
                }

                Section {
                    TrackerCountRow(manager: manager)
                    LabeledRow("Pop-ups blocked", "\(manager.popupsBlocked)")
                    LabeledRow("Pages loaded", "\(manager.pagesVisited)")
                    LabeledRow("Erasures", "\(manager.erasures)")
                    Button(role: .destructive) {
                        manager.erase()
                    } label: {
                        Label("Erase browsing data now", systemImage: "trash")
                    }
                } header: {
                    Text("This session")
                } footer: {
                    Text("Erasing browsing data also clears the pop-up count and site exceptions.")
                }

                BrowserLogSettingsSection()

                Section("About") {
                    LabeledRow("Version", "1.2")
                    Text("Focus Lite blocks known trackers with WebKit content rules, keeps the data store ephemeral, browses in tabs with a dedicated iPad layout, and runs Chrome-style extensions through a lightweight WebExtensions bridge.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func extensionRow(_ ext: BrowserExtension) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ext.name).font(.headline)
                    Text("v\(ext.version) · \(ext.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { extManager.isEnabled(ext.id) },
                    set: { enabled in
                        extManager.setEnabled(ext.id, enabled)
                        manager.refreshAllExtensions()
                    }
                ))
                .labelsHidden()
            }
            if !ext.descriptionText.isEmpty {
                Text(ext.descriptionText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TrackerCountRow: View {
    @ObservedObject var manager: TabManager

    var body: some View {
        if let model = manager.activeTab?.model {
            TrackerCount(model: model)
        }
    }
}

private struct TrackerCount: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        HStack {
            Text("Trackers seen")
            Spacer()
            Text("\(model.trackersSeen)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

private struct LabeledRow: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
