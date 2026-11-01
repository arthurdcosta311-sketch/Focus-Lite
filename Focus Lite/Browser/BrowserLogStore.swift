//
//  BrowserLogStore.swift
//  Focus Lite
//

import Combine
import Foundation

enum BrowserLogLevel: String {
    case info
    case warning
    case error
}

struct BrowserLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: BrowserLogLevel
    let category: String
    let message: String

    var formattedLine: String {
        "\(timestamp.formatted(date: .omitted, time: .standard)) [\(level.rawValue.uppercased())] \(category): \(message)"
    }
}

/// A small, in-memory diagnostic log. Page URLs are recorded as host names only.
final class BrowserLogStore: ObservableObject {
    static let maximumEntries = 100
    static let shared = BrowserLogStore(limit: maximumEntries)

    @Published private(set) var entries: [BrowserLogEntry] = []

    private let limit: Int

    init(limit: Int = maximumEntries) {
        self.limit = max(1, limit)
    }

    var newestFirst: [BrowserLogEntry] {
        Array(entries.reversed())
    }

    var exportText: String {
        entries.map(\.formattedLine).joined(separator: "\n")
    }

    func record(_ message: String, category: String = "Browser", level: BrowserLogLevel = .info) {
        let entry = BrowserLogEntry(timestamp: Date(), level: level, category: category, message: message)
        if Thread.isMainThread {
            append(entry)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.append(entry)
            }
        }
    }

    func clear() {
        if Thread.isMainThread {
            entries.removeAll(keepingCapacity: true)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.entries.removeAll(keepingCapacity: true)
            }
        }
    }

    private func append(_ entry: BrowserLogEntry) {
        entries.append(entry)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }
}
