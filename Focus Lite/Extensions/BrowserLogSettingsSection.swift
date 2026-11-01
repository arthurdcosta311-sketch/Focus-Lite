//
//  BrowserLogSettingsSection.swift
//  Focus Lite
//

import SwiftUI

struct BrowserLogSettingsSection: View {
    @ObservedObject private var logManager = BrowserLogStore.shared

    var body: some View {
        Section {
            HStack {
                Text("\(logManager.entries.count) recent events")
                    .foregroundStyle(.secondary)
                Spacer()
                if !logManager.entries.isEmpty {
                    ShareLink(item: logManager.entries.map {
                        "\($0.timestamp.formatted(date: .omitted, time: .standard)) \($0.message)"
                    }.joined(separator: "\n")) {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        logManager.clear()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Clear browser logs")
                }
            }

            if logManager.entries.isEmpty {
                Text("No recent browser activity.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logManager.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.message)
                            .font(.subheadline)
                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            Text("Browser logs · this session")
        } footer: {
            Text("Recent activity is kept in memory only. Logs contain site hostnames only, are capped at 100 events, and are cleared when the session is erased or incognito changes.")
        }
    }
}
