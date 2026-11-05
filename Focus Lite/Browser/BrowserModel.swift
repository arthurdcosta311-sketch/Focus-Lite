//
//  BrowserModel.swift
//  Focus Lite
//

import Combine
import SwiftUI
import UIKit
import WebKit

final class BrowserModel: NSObject, ObservableObject {
    @Published var addressText = ""
    @Published var displayedURL: URL?
    @Published var progress = 0.0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var trackersSeen = 0
    @Published var isStart = true
    /// Just-in-time snapshot of the current page, taken when the tab switcher
    /// or sidebar asks and refreshed after each load; nil on the start screen.
    @Published var previewImage: UIImage?
    /// Called on the main thread each time a page finishes loading, so the
    /// tab manager can keep session-wide stats.
    var onPageLoaded: (() -> Void)?

    /// Called on the main thread when the popup blocker refuses a popup, so
    /// the tab manager can offer a session-only exception for the source site.
    var onPopupBlocked: ((String?) -> Void)?
    var shouldBlockPopup: ((String?, URL?, WKNavigationType) -> Bool)?

    let webView: WKWebView

    private let bridge = ExtensionBridge()
    private var backgroundWebView: WKWebView?
    private var registeredExtensionWorldNames: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    private var previewGeneration = 0
    /// Set around the model's own loads. Those are the user's address-bar
    /// choices, not redirects, so the redirect rule lets them through.
    private var isUserInitiatedNavigation = false

    init(dataStore: WKWebsiteDataStore = .nonPersistent()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        // Videos play inline with the page's own controls instead of jumping
        // into WebKit's native fullscreen player (the one with AirPlay).
        // Fullscreen only happens when the site asks for it through the
        // HTML5 fullscreen API.
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.isElementFullscreenEnabled = true
        // Picture-in-picture is available from the video's own PiP button;
        // nothing enters PiP automatically.
        configuration.allowsPictureInPictureMediaPlayback = true
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.pageZoom = CGFloat(CustomizationStore.shared.pageZoom)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        bridge.pageWebView = webView
        TrackerBlocker.install(into: controller)
        refreshExtensions()
        observeWebView()
    }

    // MARK: - Extension wiring

    /// (Re)installs each enabled extension's isolated-world API and content
    /// scripts. Changes take effect on the next page load.
    func refreshExtensions() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for worldName in registeredExtensionWorldNames {
            controller.removeScriptMessageHandler(
                forName: ExtensionBridge.handlerName,
                contentWorld: .world(name: worldName)
            )
        }
        registeredExtensionWorldNames.removeAll()

        for ext in ExtensionManager.shared.extensions where ExtensionManager.shared.isEnabled(ext.id) {
            let world = ExtensionBridge.contentWorld(for: ext.id)
            controller.add(bridge, contentWorld: world, name: ExtensionBridge.handlerName)
            registeredExtensionWorldNames.insert(ExtensionBridge.contentWorldName(for: ext.id))
            controller.addUserScript(WKUserScript(
                source: ExtensionBridge.factoryScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: world
            ))

            let hasLua = ext.contentScripts.contains { spec in
                spec.scripts.contains { $0.hasPrefix(LuaBridge.luaBootstrapMarker) }
            }
            if hasLua {
                controller.addUserScript(WKUserScript(
                    source: LuaBridge.preloadScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: world
                ))
            }

            for spec in ext.contentScripts {
                for source in spec.scripts {
                    controller.addUserScript(WKUserScript(
                        source: ExtensionBridge.wrapped(source: source, extId: ext.id, patterns: spec.matches),
                        injectionTime: spec.runAtDocumentStart ? .atDocumentStart : .atDocumentEnd,
                        forMainFrameOnly: true,
                        in: world
                    ))
                }
                for css in spec.cssSources {
                    controller.addUserScript(WKUserScript(
                        source: ExtensionBridge.wrappedCSS(source: css, extId: ext.id, patterns: spec.matches),
                        injectionTime: spec.runAtDocumentStart ? .atDocumentStart : .atDocumentEnd,
                        forMainFrameOnly: true,
                        in: world
                    ))
                }
            }
        }

        releaseBackgroundHost()
        if hasEnabledBackgroundScripts {
            prepareBackgroundHost()
        }
    }

    private var hasEnabledBackgroundScripts: Bool {
        ExtensionManager.shared.extensions.contains {
            ExtensionManager.shared.isEnabled($0.id) && !$0.backgroundScripts.isEmpty
        }
    }

    private func prepareBackgroundHost() {
        guard backgroundWebView == nil, hasEnabledBackgroundScripts else { return }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webView.configuration.websiteDataStore
        let controller = WKUserContentController()
        for ext in ExtensionManager.shared.extensions
        where ExtensionManager.shared.isEnabled(ext.id) && !ext.backgroundScripts.isEmpty {
            controller.add(bridge, contentWorld: ExtensionBridge.contentWorld(for: ext.id),
                           name: ExtensionBridge.handlerName)
        }
        configuration.userContentController = controller
        let host = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        host.navigationDelegate = self
        bridge.backgroundWebView = host
        backgroundWebView = host
        host.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    private func releaseBackgroundHost() {
        guard let backgroundWebView else { return }
        backgroundWebView.stopLoading()
        backgroundWebView.navigationDelegate = nil
        bridge.backgroundWebView = nil
        self.backgroundWebView = nil
    }

    private func installBackgroundScripts(in host: WKWebView) {
        for ext in ExtensionManager.shared.extensions
        where ExtensionManager.shared.isEnabled(ext.id) && !ext.backgroundScripts.isEmpty {
            var sources = [ExtensionBridge.factoryScript]
            if ext.backgroundScripts.contains(where: { $0.hasPrefix(LuaBridge.luaBootstrapMarker) }) {
                sources.append(LuaBridge.preloadScript)
            }
            sources.append(contentsOf: ext.backgroundScripts.map {
                ExtensionBridge.wrapped(source: $0, extId: ext.id, patterns: ["<all_urls>"])
            })
            host.evaluateJavaScript(
                sources.joined(separator: "\n"),
                in: nil,
                in: ExtensionBridge.contentWorld(for: ext.id),
                completionHandler: nil
            )
        }
    }

    // MARK: - Navigation

    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // An explicit scheme navigates exactly as typed.
        if let candidate = URL(string: trimmed),
           let scheme = candidate.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            navigate(to: candidate)
            return
        }

        // Domain-shaped input — "anything.com", "news.site.org", an IP, or a
        // domain with a path — is a site candidate: it gets resolved first,
        // so real sites launch and dead addresses fall back to a search
        // instead of dead-ending on a host that cannot resolve.
        if let candidate = Self.siteURL(for: trimmed) {
            let host = candidate.host ?? ""
            if Self.isIPv4(host) {
                navigate(to: candidate)
                return
            }
            addressText = trimmed
            BrowserLogStore.shared.record("Checking address · \(host)")
            Task { [weak self] in
                let resolves = await FocusSearchService.shared.hostResolves(host)
                await MainActor.run {
                    guard let self else { return }
                    if resolves {
                        self.navigate(to: candidate)
                    } else {
                        self.performSearch(for: trimmed)
                    }
                }
            }
            return
        }

        performSearch(for: trimmed)
    }

    /// The site address the term points to, when it looks like one: bare
    /// domains and IPs ("example.com", "1.2.3.4") or a domain with a path
    /// ("example.com/shop"). Sentences and single words aren't site addresses.
    static func siteURL(for text: String) -> URL? {
        guard !text.contains(" ") else { return nil }
        if let domain = FocusSearchService.domainCandidate(for: text) {
            return URL(string: "https://" + domain)
        }
        guard let url = URL(string: "https://" + text),
              let host = url.host,
              FocusSearchService.domainCandidate(for: host) != nil else { return nil }
        return url
    }

    private static func isIPv4(_ host: String) -> Bool {
        let labels = host.split(separator: ".")
        return labels.count == 4 && labels.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    /// Whether two URLs belong to the same site or related domains:
    /// identical hosts, or hosts sharing a base domain — one a subdomain of
    /// the other (www.example.com and login.example.com, or example.com and
    /// either). The redirect rule allows only these.
    static func isSameOrRelatedSite(_ a: URL, _ b: URL) -> Bool {
        guard let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased(),
              !hostA.isEmpty, !hostB.isEmpty else { return true }
        if hostA == hostB { return true }
        return baseDomain(for: hostA) == baseDomain(for: hostB)
    }

    /// Common second-level suffixes, where the site's base domain needs three
    /// labels (example.co.uk, not co.uk).
    private static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk",
        "com.au", "net.au", "co.jp", "ne.jp", "or.jp",
        "com.br", "com.mx", "co.in", "co.nz", "co.za",
        "com.sg", "com.tr", "com.cn", "com.hk", "co.il",
    ]

    /// The host's base domain: the last two labels, three for hosts under a
    /// common second-level suffix.
    private static func baseDomain(for host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiLabelSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// Words scam pages' own URLs give away: scareware ("10 viruses found —
    /// clean now") and prize pages announce themselves in the host, path or
    /// query. Matching is on the whole URL, so a redirect into any of these
    /// is refused; a user-tapped link to one is not.
    private static let fishyPhrases: Set<String> = [
        "virus", "malware", "scan-now", "virus-scan", "quickscan",
        "cleannow", "clean-now", "cleanmy", "device-clean",
        "battery-damaged", "batterylow", "battery-drain",
        "prize", "winner", "youwon", "you-won", "congratulations",
        "congrats", "luckydraw", "lucky-draw", "giveaway",
        "hacked", "device-damaged", "phone-damaged", "iphone-damaged",
        "iplogged", "you-have-been-selected", "claimyourprize", "claim-now",
    ]

    /// Whether a destination URL looks like a scareware or prize-scam page.
    static func looksFishy(_ url: URL) -> Bool {
        let text = url.absoluteString.lowercased()
        // "coronavirus" contains "virus": public-health pages are not scams.
        guard !text.contains("coronavirus") else { return false }
        return fishyPhrases.contains { text.contains($0) }
    }

    /// Base domains of known scam and malvertising chains: fake-VPN player
    /// pre-landers and the click-fraud redirectors they bounce through.
    /// Campaign keys and IDs in their URLs rotate constantly, so matching is
    /// on the domain, never on the query.
    private static let blacklistedScamDomains: Set<String> = [
        "freedomnetvpn.com",
        "topsecureflow.com",
    ]

    /// Whether a URL's host is, or sits under, a blacklisted scam domain.
    static func isBlacklistedScamDomain(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        return blacklistedScamDomains.contains { domain in
            host == domain || host.hasSuffix("." + domain)
        }
    }

    private func navigate(to url: URL) {
        // The address bar shows the full URL of the page being opened.
        addressText = url.absoluteString
        BrowserLogStore.shared.record("Navigation requested · \(url.host ?? "unknown host")")
        isUserInitiatedNavigation = true
        webView.load(URLRequest(url: url))
    }

    /// Whatever the engine choice dictates for non-address input: Focus
    /// Search renders its own results page; other engines open their site.
    private func performSearch(for text: String) {
        if CustomizationStore.shared.searchEngine == .focus {
            renderFocusSearch(query: text, offset: 0, tab: "web")
            return
        }
        guard let url = CustomizationStore.shared.searchURL(for: text) else { return }
        navigate(to: url)
    }

    /// Focus Search renders its results as an HTML page loaded straight into
    /// this tab's web view — a real search-engine results page, with the
    /// page's own search box and "More results" link navigating back into the
    /// engine through the focussearch:// scheme (intercepted in
    /// decidePolicyFor), so searching, paging and back all work in the tab.
    func renderFocusSearch(query: String, offset: Int, tab: String = "web") {
        // HTML-string loads have no URL, so the start screen is retired here
        // and the address bar shows the query itself.
        isStart = false
        displayedURL = nil
        addressText = query
        isLoading = false
        webView.loadHTMLString(FocusSearchPage.searchingPage(query: query, tab: tab), baseURL: nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if tab == "images" {
                if offset == 0 {
                    let fetched = await FocusSearchService.shared.imageResults(for: query, offset: 0)
                    guard !Task.isCancelled else { return }
                    let shown = Array(fetched.prefix(FocusSearchService.pageSize))
                    let hasMore = fetched.count >= FocusSearchService.pageSize
                    self.webView.loadHTMLString(
                        FocusSearchPage.imagesPage(query: query, images: shown, offset: offset, hasMore: hasMore),
                        baseURL: nil
                    )
                    BrowserLogStore.shared.record("Focus search · \(shown.count) image results")
                } else {
                    // "Search for more" re-renders with every image loaded so
                    // far: the earlier tiles stay in the grid, the new batch
                    // is appended to it.
                    let target = offset + FocusSearchService.pageSize
                    let fetched = await FocusSearchService.shared.accumulatedImageResults(for: query, upTo: target)
                    guard !Task.isCancelled else { return }
                    let hasMore = fetched.count >= target
                    self.webView.loadHTMLString(
                        FocusSearchPage.imagesPage(query: query, images: fetched, offset: offset, hasMore: hasMore),
                        baseURL: nil
                    )
                    BrowserLogStore.shared.record("Focus search · \(fetched.count) image results total")
                }
            } else if offset == 0 {
                let response = await FocusSearchService.shared.search(query)
                guard !Task.isCancelled else { return }
                var pageResponse = response
                pageResponse.results = Array(response.results.prefix(FocusSearchService.pageSize))
                let hasMore = response.results.count >= FocusSearchService.pageSize
                self.webView.loadHTMLString(
                    FocusSearchPage.resultsPage(query: query, response: pageResponse, offset: offset, hasMore: hasMore),
                    baseURL: nil
                )
                let dnsNote: String
                if response.directSite == nil {
                    dnsNote = ""
                } else if CustomizationStore.shared.verifyDomains {
                    dnsNote = " · DNS check via \(EncryptedDNSManager.shared.resolver.rawValue)"
                } else {
                    dnsNote = " · direct link"
                }
                BrowserLogStore.shared.record("Focus search · \(pageResponse.results.count) results\(dnsNote)")
            } else {
                // "Search for more" re-renders with every result loaded so
                // far: the earlier results stay on the page, the new batch
                // is appended below them.
                let target = offset + FocusSearchService.pageSize
                let fetched = await FocusSearchService.shared.accumulatedWebResults(for: query, upTo: target)
                guard !Task.isCancelled else { return }
                var pageResponse = FocusSearchResponse()
                pageResponse.results = fetched
                let hasMore = fetched.count >= target
                self.webView.loadHTMLString(
                    FocusSearchPage.resultsPage(query: query, response: pageResponse, offset: offset, hasMore: hasMore),
                    baseURL: nil
                )
                BrowserLogStore.shared.record("Focus search · \(fetched.count) results total")
            }
        }
    }

    func toggleReload() {
        if isLoading {
            webView.stopLoading()
        } else if displayedURL != nil {
            webView.reload()
        }
    }

    func goBack() {
        guard canGoBack else { return }
        webView.goBack()
    }

    /// Reset this tab: stop loading, drop everything the data store holds and
    /// return to the start screen. The tab manager calls this when the session
    /// is erased or incognito mode switches.
    func wipeSession() {
        webView.stopLoading()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast,
            completionHandler: {}
        )
        isStart = true
        displayedURL = nil
        addressText = ""
        trackersSeen = 0
        progress = 0
        isLoading = false
        clearPreview()
    }

    // MARK: - Observation

    private func observeWebView() {
        webView.publisher(for: \.estimatedProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in
                guard let self, self.displayedURL != nil else { return }
                self.progress = value
                self.isLoading = value > 0 && value < 1
            }
            .store(in: &cancellables)
        webView.publisher(for: \.canGoBack)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canGoBack = value }
            .store(in: &cancellables)
    }

    /// Captures a small thumbnail on demand. The manager serializes captures
    /// and keeps only a bounded number of these reduced-size images.
    func capturePreview(completion: (() -> Void)? = nil) {
        guard !isStart, displayedURL != nil else {
            clearPreview()
            completion?()
            return
        }

        previewGeneration += 1
        let generation = previewGeneration
        webView.takeSnapshot(with: nil) { [weak self] image, _ in
            DispatchQueue.main.async {
                defer { completion?() }
                guard let self,
                      self.previewGeneration == generation,
                      !self.isStart,
                      let image else { return }
                self.previewImage = Self.thumbnail(from: image)
            }
        }
    }

    func clearPreview() {
        previewGeneration += 1
        previewImage = nil
    }

    private static func thumbnail(from image: UIImage) -> UIImage {
        let size = CGSize(width: 320, height: 180)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let drawnSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let origin = CGPoint(x: (size.width - drawnSize.width) / 2,
                                 y: (size.height - drawnSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawnSize))
        }
    }

    private func auditTrackers() {
        webView.evaluateJavaScript(TrackerBlocker.auditScript, in: nil, in: .page) { [weak self] result in
            if case .success(let value) = result {
                if let number = value as? Double { self?.trackersSeen = Int(number) }
                else if let number = value as? Int { self?.trackersSeen = number }
            }
        }
    }

    private func recordNavigationFailure(_ error: Error, in webView: WKWebView) {
        let details = error as NSError
        guard details.domain != NSURLErrorDomain || details.code != NSURLErrorCancelled else { return }
        let host = webView.url?.host ?? displayedURL?.host ?? "unknown site"
        BrowserLogStore.shared.record("Load failed · \(host) · \(details.domain) (\(details.code))")
    }
}

// MARK: - WKNavigationDelegate

extension BrowserModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        let host = webView.url?.host ?? "unknown site"
        BrowserLogStore.shared.record("Loading · \(host)")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView,
              let url = webView.url,
              url.absoluteString != "about:blank" else { return }
        isStart = false
        displayedURL = url
        // The address bar keeps showing the full URL of the page you're on.
        addressText = url.absoluteString
        trackersSeen = 0
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === backgroundWebView {
            installBackgroundScripts(in: webView)
            return
        }
        guard let url = webView.url, url.absoluteString != "about:blank" else { return }
        displayedURL = url
        isLoading = false
        BrowserLogStore.shared.record("Page loaded · \(url.host ?? "unknown site")")
        onPageLoaded?()
        auditTrackers()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        isLoading = false
        recordNavigationFailure(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        isLoading = false
        recordNavigationFailure(error, in: webView)
    }

    /// Intercepts the Focus engine's own scheme — the in-page search box and
    /// its "More results" pagination link — and renders a fresh results page
    /// instead of navigating. Everything else loads normally.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // Over-the-air app installs and App Store links use custom schemes
        // WebKit will not load: hand them to iOS instead. Tapping an
        // itms-services:// link then brings up the system install prompt.
        if url.scheme == "itms-services" || url.scheme == "itms-apps" {
            decisionHandler(.cancel)
            guard webView === self.webView else { return }
            BrowserLogStore.shared.record(
                url.scheme == "itms-services" ? "Opening over-the-air install" : "Opening App Store link"
            )
            UIApplication.shared.open(url)
            return
        }
        // Blacklisted scam domains are refused outright, however the request
        // arrives: a redirect into them, a tapped link, or a page resource
        // loaded from them.
        if Self.isBlacklistedScamDomain(url) {
            decisionHandler(.cancel)
            guard webView === self.webView else { return }
            BrowserLogStore.shared.record("Scam domain blocked · \(url.host ?? "unknown host")")
            return
        }
        // Redirects — server hops, JavaScript or meta-refresh, anything that
        // navigates without a user tap — are refused when they leave the site
        // the tab is already on for a different domain whose URL smells like
        // a scam ("10 viruses found", prize and scareware pages). Redirects
        // within the same site or a related domain always pass, and the
        // page's own images and scripts are never touched.
        if webView === self.webView,
           navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.navigationType == .other {
            if isUserInitiatedNavigation {
                isUserInitiatedNavigation = false
            } else if let currentPage = webView.url ?? displayedURL,
                      !Self.isSameOrRelatedSite(currentPage, url),
                      Self.looksFishy(url) {
                decisionHandler(.cancel)
                BrowserLogStore.shared.record("Fishy redirect blocked · \(url.host ?? "unknown host")")
                return
            }
        }
        guard url.scheme == FocusSearchPage.scheme else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        guard webView === self.webView else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems?.first { $0.name == "q" }?.value ?? ""
        let offset = components?.queryItems?.first { $0.name == "offset" }?.value.flatMap(Int.init) ?? 0
        let tab = components?.queryItems?.first { $0.name == "tab" }?.value ?? "web"
        guard !query.isEmpty else { return }
        BrowserLogStore.shared.record("Focus search requested")
        renderFocusSearch(query: query, offset: offset, tab: tab)
    }

    /// Keep user-tapped links in this tab and refuse unsolicited windows.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView, navigationAction.targetFrame == nil else { return nil }
        let sourceHost = PopupBlocker.normalizedHost(self.webView.url?.host)
        let shouldBlock = shouldBlockPopup?(
            sourceHost,
            navigationAction.request.url,
            navigationAction.navigationType
        )
            ?? PopupBlocker.shouldBlock(
                sourceHost: sourceHost,
                destinationURL: navigationAction.request.url,
                navigationType: navigationAction.navigationType,
                isEnabled: PopupBlocker.isEnabled(),
                allowedSites: []
            )
        if shouldBlock {
            onPopupBlocked?(sourceHost)
            return nil
        }
        self.webView.load(navigationAction.request)
        return nil
    }
}