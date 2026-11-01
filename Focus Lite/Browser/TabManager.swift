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
    @Published private(set) var toastActionTitle: String?
    @Published private(set) var pagesVisited = 0
    @Published private(set) var erasures = 0
    @Published private(set) var popupsBlocked = 0
    @Published var popupBlockerEnabled: Bool {
        didSet { PopupBlocker.setEnabled(popupBlockerEnabled) }
    }
    @Published private(set) var allowedPopupSites: Set<String> = []

    /// All tabs browse with one ephemeral store, like a normal browser's
    /// private window. Switching modes swaps in a fresh store so nothing
    /// carries over.
    private var dataStore: WKWebsiteDataStore = .nonPersistent()
    private var toastWorkItem: DispatchWorkItem?
    private var toastActionHost: String?
    private var previewCaptureGeneration = 0
    private static let maxCachedTabPreviews = 4

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    init() {
        popupBlockerEnabled = PopupBlocker.isEnabled()
        addTab()
    }

    // MARK: - Tabs

    @discardableResult
    func addTab() -> Tab {
        let tab = Tab(model: BrowserModel(dataStore: dataStore))
        tab.model.onPageLoaded = { [weak self] in self?.pagesVisited += 1 }
        tab.model.onPopupBlocked = { [weak self] host in self?.notePopupBlocked(from: host) }
        tab.model.shouldBlockPopup = { [weak self] host, destinationURL, navigationType in
            guard let self else { return true }
            return PopupBlocker.shouldBlock(
                sourceHost: host,
                destinationURL: destinationURL,
                navigationType: navigationType,
                isEnabled: self.popupBlockerEnabled,
                allowedSites: self.allowedPopupSites
            )
        }
        tabs.append(tab)
        activeTabID = tab.id
        BrowserLogStore.shared.record("New tab opened")
        return tab
    }

    func select(_ id: Tab.ID) {
        activeTabID = id
        if !showTabSwitcher { captureTabPreviews() }
    }

    /// Opens the tab switcher, refreshing every tab's page preview just in
    /// time — no bitmaps are held the rest of the time.
    func openTabSwitcher() {
        captureTabPreviews()
        showTabSwitcher = true
    }

    private func notePopupBlocked(from host: String?) {
        popupsBlocked += 1
        let site = PopupBlocker.normalizedHost(host)
        BrowserLogStore.shared.record(site.map { "Pop-up blocked · \($0)" } ?? "Pop-up blocked")
        showToast(
            site.map { "Popup blocked from \($0)" } ?? "Popup blocked",
            symbol: "hand.raised.fill",
            actionTitle: site == nil ? nil : "Allow site",
            actionHost: site
        )
    }

    func isPopupSiteAllowed(_ host: String) -> Bool {
        guard let normalized = PopupBlocker.normalizedHost(host) else { return false }
        return allowedPopupSites.contains(normalized)
    }

    func togglePopupAllowance(for host: String) {
        guard let normalized = PopupBlocker.normalizedHost(host) else { return }
        if allowedPopupSites.contains(normalized) {
            allowedPopupSites.remove(normalized)
            showToast("Pop-ups blocked for \(normalized)", symbol: "hand.raised.fill")
        } else {
            allowedPopupSites.insert(normalized)
            showToast("Pop-ups allowed for \(normalized)", symbol: "checkmark.circle.fill")
        }
    }

    func allowPopupsForLastBlockedSite() {
        guard let host = toastActionHost else { return }
        allowedPopupSites.insert(host)
        showToast("Pop-ups allowed for \(host)", symbol: "checkmark.circle.fill")
    }

    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        BrowserLogStore.shared.record("Tab closed")
        tabs[index].model.clearPreview()
        tabs.remove(at: index)
        if tabs.isEmpty {
            addTab()
        } else if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        captureTabPreviews()
    }

    /// Captures small thumbnails for at most four loaded tabs, with one
    /// WebKit snapshot in flight at a time.
    func captureTabPreviews() {
        previewCaptureGeneration += 1
        let generation = previewCaptureGeneration
        let orderedTabs = tabs.filter { $0.id == activeTabID } + tabs.filter { $0.id != activeTabID }
        let candidates = Array(
            orderedTabs.filter { !$0.model.isStart && $0.model.displayedURL != nil }
                .prefix(Self.maxCachedTabPreviews)
        )
        let candidateIDs = Set(candidates.map(\.id))
        tabs.filter { !candidateIDs.contains($0.id) }.forEach { $0.model.clearPreview() }
        captureNextPreview(in: candidates, at: 0, generation: generation)
    }

    /// iPad refreshes just the visible tab after a page load, keeping the
    /// persistent sidebar to a single cached image in that case.
    func captureActiveTabPreview() {
        previewCaptureGeneration += 1
        tabs.filter { $0.id != activeTabID }.forEach { $0.model.clearPreview() }
        activeTab?.model.capturePreview()
    }

    func clearTabPreviews() {
        previewCaptureGeneration += 1
        tabs.forEach { $0.model.clearPreview() }
    }

    private func captureNextPreview(in candidates: [Tab], at index: Int, generation: Int) {
        guard generation == previewCaptureGeneration, index < candidates.count else { return }
        let tab = candidates[index]
        guard tabs.contains(where: { $0.id == tab.id }) else {
            captureNextPreview(in: candidates, at: index + 1, generation: generation)
            return
        }
        tab.model.capturePreview { [weak self] in
            self?.captureNextPreview(in: candidates, at: index + 1, generation: generation)
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
        clearTabPreviews()
        tabs.removeAll()
        resetBrowserSession()
        addTab()
        erasures += 1
        showToast("Browsing data erased", symbol: "checkmark.circle.fill")
    }

    /// Toggles incognito mode. Either way the session is wiped: every tab is
    /// dropped and browsing continues in one fresh tab with a fresh store.
    func toggleIncognito() {
        isIncognito.toggle()
        dataStore = .nonPersistent()
        clearTabPreviews()
        tabs.removeAll()
        resetBrowserSession()
        addTab()
        showToast(isIncognito ? "Incognito on — nothing is saved" : "Incognito off",
                  symbol: "eyeglasses")
    }

    private func resetBrowserSession() {
        popupsBlocked = 0
        allowedPopupSites.removeAll()
        BrowserLogStore.shared.clear()
        toastActionHost = nil
        toastActionTitle = nil
    }

    private func showToast(_ text: String, symbol: String, actionTitle: String? = nil,
                           actionHost: String? = nil) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            toastText = text
            toastSymbol = symbol
            toastActionTitle = actionTitle
        }
        toastActionHost = actionHost
        toastWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) {
                self?.toastText = nil
                self?.toastActionTitle = nil
                self?.toastActionHost = nil
            }
        }
        toastWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }
}
