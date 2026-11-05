//
//  TabManager.swift
//  Focus Lite
//

import Combine
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

/// Owns the open tabs, the shared data store they browse with, and
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
    /// Raised when an erase is requested while cookies are set to stay: the
    /// user decides whether they are cleared along with the history.
    @Published var showEraseConfirmation = false

    /// All tabs browse with one shared store: the persistent default outside
    /// incognito — history, sign-ins and site data survive relaunches — and an
    /// ephemeral store in incognito, where nothing is saved.
    private var dataStore: WKWebsiteDataStore = .default()
    private var confirmEraseFromSwitcher = false
    private let defaults = UserDefaults.standard
    private var cancellables: Set<AnyCancellable> = []
    private var toastWorkItem: DispatchWorkItem?
    private var toastActionHost: String?
    private var previewCaptureGeneration = 0
    private static let maxCachedTabPreviews = 4

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabID }
    }

    init() {
        popupBlockerEnabled = PopupBlocker.isEnabled()
        dataStore = freshDataStore()
        observeCustomization()
        restoreSession()
    }

    /// With "Keep cookies and sign-ins" on (the default), normal browsing
    /// uses the persistent store, so history, sign-ins and site data survive
    /// relaunches; with it off, and always in incognito, browsing uses a
    /// throwaway store nothing is saved to.
    private func freshDataStore() -> WKWebsiteDataStore {
        if CustomizationStore.shared.keepCookies && !isIncognito {
            return .default()
        }
        return .nonPersistent()
    }

    /// Keeps every view that reads Theme.accent in step with customization
    /// changes and applies the zoom setting to all open tabs live.
    private func observeCustomization() {
        CustomizationStore.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        CustomizationStore.shared.$pageZoom
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] zoom in
                self?.tabs.forEach { $0.model.webView.pageZoom = CGFloat(zoom) }
            }
            .store(in: &cancellables)
        CustomizationStore.shared.$keepCookies
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resetSessionForStoreChange() }
            .store(in: &cancellables)
    }

    // MARK: - Tabs

    @discardableResult
    func addTab(url: URL? = nil) -> Tab {
        let tab = Tab(model: BrowserModel(dataStore: dataStore))
        tab.model.onPageLoaded = { [weak self] in
            self?.pagesVisited += 1
            self?.saveSession()
        }
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
        if let url {
            tab.model.load(url.absoluteString)
        } else if let homepage = CustomizationStore.shared.homepageURL() {
            tab.model.load(homepage.absoluteString)
        }
        BrowserLogStore.shared.record("New tab opened")
        saveSession()
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
        saveSession()
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

    /// Closes every tab and continues in one fresh one. Unlike an erase,
    /// this keeps the browsing data — cookies, caches and site storage stay,
    /// so the session itself is not wiped; only the tabs and their page
    /// history go.
    func closeAll() {
        BrowserLogStore.shared.record("All tabs closed")
        clearTabPreviews()
        tabs.removeAll()
        addTab()
        saveSession()
        showToast("All tabs closed", symbol: "xmark.square")
    }

    func refreshAllExtensions() {
        tabs.forEach { $0.model.refreshExtensions() }
    }

    // MARK: - Session

    /// Entry point for every erase button. Erasing always asks first, since
    /// it wipes saved browsing data along with the open tabs.
    func requestErase() {
        confirmEraseFromSwitcher = showTabSwitcher
        showEraseConfirmation = true
    }

    /// Focus-style erase: drop every tab and wipe the shared data store,
    /// sparing the persistent cookies and sign-ins when asked to.
    func erase(clearCookies: Bool = true) {
        dataStore.removeData(
            ofTypes: Self.dataTypesToErase(clearCookies: clearCookies),
            modifiedSince: .distantPast,
            completionHandler: {}
        )
        clearTabPreviews()
        tabs.removeAll()
        resetBrowserSession()
        addTab()
        erasures += 1
        if confirmEraseFromSwitcher {
            confirmEraseFromSwitcher = false
            showTabSwitcher = false
        }
        showToast(clearCookies || !CustomizationStore.shared.keepCookies
                  ? "Browsing data erased"
                  : "History erased — cookies kept",
                  symbol: "checkmark.circle.fill")
    }

    /// The website data types an erase removes. Keeping cookies means only
    /// clearing everything else — caches, storages, disk data — not sign-ins.
    static func dataTypesToErase(clearCookies: Bool) -> Set<String> {
        if clearCookies {
            return WKWebsiteDataStore.allWebsiteDataTypes()
        }
        return WKWebsiteDataStore.allWebsiteDataTypes()
            .subtracting([WKWebsiteDataTypeCookies])
    }

    /// Toggles incognito mode. Either way the session is wiped: every tab is
    /// dropped and browsing continues in one fresh tab with a fresh store.
    /// Incognito never keeps cookies, whatever the setting says.
    func toggleIncognito() {
        isIncognito.toggle()
        dataStore = freshDataStore()
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

    /// Swapping between the ephemeral and persistent stores needs a fresh
    /// session: every tab drops, and browsing continues in one new tab.
    private func resetSessionForStoreChange() {
        dataStore = freshDataStore()
        clearTabPreviews()
        tabs.removeAll()
        resetBrowserSession()
        addTab()
        showToast(CustomizationStore.shared.keepCookies
                  ? "Cookies and sign-ins now stay on this device"
                  : "Cookies now die with every session",
                  symbol: "lock.shield")
    }

    // MARK: - Session restore

    /// Restores the tabs of the last normal session at launch, so browsing
    /// never starts fresh. The saved tab list is stored sealed by SecureVault;
    /// lists written by older builds in plain text are read once, re-saved
    /// encrypted and removed. Incognito never saves: nothing is written while
    /// it is on, so it cannot change what gets restored.
    private func restoreSession() {
        var savedURLStrings: [String] = []
        if let sealed = defaults.data(forKey: Keys.savedTabsVault),
           let opened = SecureVault.openJSON(sealed) as? [String] {
            savedURLStrings = opened
        } else if let legacy = defaults.stringArray(forKey: Keys.savedTabs) {
            savedURLStrings = legacy
        }
        // The plain-text list is never kept: whatever was found is rewritten
        // under the vault key by saveSession on the next page load, and the
        // legacy entry is dropped here.
        defaults.removeObject(forKey: Keys.savedTabs)
        let urls = savedURLStrings
            .compactMap(URL.init(string:))
            .filter { $0.scheme == "http" || $0.scheme == "https" }
        guard !urls.isEmpty else {
            addTab()
            return
        }
        for url in urls { addTab(url: url) }
        if !savedURLStrings.isEmpty { saveSession() }
    }

    /// Remembers the current tabs so the next launch can restore them. Only
    /// the encrypted form is written: SecureVault seals the URL list with the
    /// app's Keychain key, so nothing on disk names the sites. Never called
    /// while incognito is on — that session saves nothing.
    private func saveSession() {
        guard !isIncognito, CustomizationStore.shared.keepCookies else { return }
        let urls = tabs.compactMap { $0.model.displayedURL?.absoluteString }
        guard let sealed = SecureVault.sealJSON(urls) else { return }
        defaults.set(sealed, forKey: Keys.savedTabsVault)
        defaults.removeObject(forKey: Keys.savedTabs)
    }

    private enum Keys {
        static let savedTabsVault = "session.savedTabs.vault"
        static let savedTabs = "session.savedTabs"
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
