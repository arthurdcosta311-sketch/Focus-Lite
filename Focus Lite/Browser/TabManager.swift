//
//  TabManager.swift
//  Focus Lite
//

import SwiftUI
import WebKit

/// One browser tab: its own web view and model, kept alive for as long as the
/// tab exists so pages keep their state across switches.
final class Tab: Identifiable {
    let id = UUID()
    let model: BrowserModel

    init(model: BrowserModel) {
        self.model = model
    }
}

/// Owns the open tabs, the shared ephemeral data store they browse with, and
/// the session-level state: incognito mode, stats and toasts.
final class TabManager: ObservableObject {
    @Published private(set) var tabs: [Tab] = []
    @Published var activeTabID: UUID?
    @Published var isIncognito = false
    @Published var showTabSwitcher = false
    @Published var showSettings = false
    @Published var toastText: String?
    @Published var toastSymbol = "checkmark.circle.fill"
    @Published private(set) var pagesVisited = 0
    @Published private(set) var erasures = 0

    /// All tabs browse with one ephemeral store, like a normal browser's
    /// private window. Switching modes swaps in a fresh store so nothing
    /// carries over.
    private var dataStore: WKWebsiteDataStore = .nonPersistent()
    private var toastWorkItem: DispatchWorkItem?

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    init() {
        addTab()
    }

    // MARK: - Tabs

    @discardableResult
    func addTab() -> Tab {
        let tab = Tab(model: BrowserModel(dataStore: dataStore))
        tab.model.onPageLoaded = { [weak self] in self?.pagesVisited += 1 }
        tabs.append(tab)
        activeTabID = tab.id
        return tab
    }

    func select(_ id: Tab.ID) {
        activeTabID = id
    }

    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            addTab()
        } else if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    func refreshAllExtensions() {
        tabs.forEach { $0.model.refreshExtensions() }
    }

    // MARK: - Session

    /// Focus-style erase: drop every tab and wipe the shared data store.
    func erase() {
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast,
            completionHandler: {}
        )
        tabs.removeAll()
        addTab()
        erasures += 1
        showToast("Browsing data erased", symbol: "checkmark.circle.fill")
    }

    /// Toggles incognito mode. Either way the session is wiped: every tab is
    /// dropped and browsing continues in one fresh tab with a fresh store.
    func toggleIncognito() {
        isIncognito.toggle()
        dataStore = .nonPersistent()
        tabs.removeAll()
        addTab()
        showToast(isIncognito ? "Incognito on — nothing is saved" : "Incognito off",
                  symbol: "eyeglasses")
    }

    private func showToast(_ text: String, symbol: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toastText = text
            toastSymbol = symbol
        }
        toastWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.toastText = nil }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: work)
    }
}
