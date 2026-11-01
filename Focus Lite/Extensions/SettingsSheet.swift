//
//  SettingsSheet.swift
//  Focus Lite
//

import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var model: BrowserModel
    @ObservedObject private var extManager = ExtensionManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(extManager.extensions) { ext in
                        extensionRow(ext)
                    }
                    Button {
                        extManager.reload()
                        model.refreshExtensions()
                    } label: {
                        Label("Rescan extensions folder", systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text("Chrome-style extensions")
                } footer: {
                    Text("Add your own: create a folder in Files → Focus Lite → Extensions containing a Chrome manifest.json (MV2 or MV3) with content scripts or a background script, then rescan. Toggles apply to the next page load.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { model.isIncognito },
                        set: { _ in model.toggleIncognito() }
                    )) {
                        Label("Incognito mode", systemImage: "eyeglasses")
                            .foregroundStyle(model.isIncognito ? Theme.incognito : .primary)
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Incognito tints the interface and hides page content in the app switcher. Turning it on or off wipes the current session.")
                }

                Section("This session") {
                    LabeledRow("Trackers seen", "\(model.trackersSeen)")
                    LabeledRow("Pages loaded", "\(model.pagesVisited)")
                    LabeledRow("Erasures", "\(model.erasures)")
                    Button(role: .destructive) {
                        model.erase()
                    } label: {
                        Label("Erase browsing data now", systemImage: "trash")
                    }
                }

                Section("About") {
                    LabeledRow("Version", "1.0")
                    Text("Focus Lite blocks known trackers with WebKit content rules, keeps the data store ephemeral, and runs Chrome-style extensions through a lightweight WebExtensions bridge.")
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
                        model.refreshExtensions()
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