//
//  BrowserModel.swift
//  Focus Lite
//

import Combine
import SwiftUI
import WebKit

final class BrowserModel: NSObject, ObservableObject {
    @Published var addressText = ""
    @Published var displayedURL: URL?
    @Published var progress = 0.0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var trackersSeen = 0
    @Published var isStart = true

    /// Called on the main thread each time a page finishes loading, so the
    /// tab manager can keep session-wide stats.
    var onPageLoaded: (() -> Void)?

    let webView: WKWebView

    private let bridge = ExtensionBridge()
    private var backgroundWebView: WKWebView?
    private var cancellables: Set<AnyCancellable> = []

    init(dataStore: WKWebsiteDataStore = .nonPersistent()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let controller = WKUserContentController()
        controller.add(bridge, contentWorld: .page, name: ExtensionBridge.handlerName)
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        webView.navigationDelegate = self
        bridge.pageWebView = webView
        TrackerBlocker.install(into: controller)
        refreshExtensions()
        observeWebView()
        prepareBackgroundHost()
    }

    // MARK: - Extension wiring

    /// (Re)installs the shared API factory and every enabled extension's
    /// content scripts. Takes effect on the next page load.
    func refreshExtensions() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: ExtensionBridge.factoryScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        for ext in ExtensionManager.shared.extensions where ExtensionManager.shared.isEnabled(ext.id) {
            for spec in ext.contentScripts {
                for source in spec.scripts {
                    controller.addUserScript(WKUserScript(
                        source: ExtensionBridge.wrapped(source: source, extId: ext.id, patterns: spec.matches),
                        injectionTime: spec.runAtDocumentStart ? .atDocumentStart : .atDocumentEnd,
                        forMainFrameOnly: true,
                        in: .page
                    ))
                }
            }
        }
        if let background = backgroundWebView {
            installBackgroundScripts(in: background)
        } else {
            prepareBackgroundHost()
        }
    }

    private func prepareBackgroundHost() {
        guard backgroundWebView == nil else { return }
        let needsBackground = ExtensionManager.shared.extensions.contains {
            ExtensionManager.shared.isEnabled($0.id) && !$0.backgroundScripts.isEmpty
        }
        guard needsBackground else { return }

        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(bridge, contentWorld: .page, name: ExtensionBridge.handlerName)
        configuration.userContentController = controller
        let host = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        host.navigationDelegate = self
        bridge.backgroundWebView = host
        backgroundWebView = host
        host.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }

    private func installBackgroundScripts(in host: WKWebView) {
        var sources = [ExtensionBridge.factoryScript]
        for ext in ExtensionManager.shared.extensions where ExtensionManager.shared.isEnabled(ext.id) {
            for source in ext.backgroundScripts {
                sources.append(ExtensionBridge.wrapped(source: source, extId: ext.id, patterns: ["<all_urls>"]))
            }
        }
        host.evaluateJavaScript(sources.joined(separator: "\n"), in: nil, in: .page, completionHandler: nil)
    }

    // MARK: - Navigation

    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var url: URL?
        if let candidate = URL(string: trimmed),
           let scheme = candidate.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            url = candidate
        } else if !trimmed.contains(" "), let candidate = URL(string: "https://" + trimmed), candidate.host != nil {
            url = candidate
        } else {
            var components = URLComponents(string: "https://duckduckgo.com/")
            components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            url = components?.url
        }
        guard let url else { return }
        addressText = url.host ?? trimmed
        webView.load(URLRequest(url: url))
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

    private func auditTrackers() {
        webView.evaluateJavaScript(TrackerBlocker.auditScript, in: nil, in: .page) { [weak self] result in
            if case .success(let value) = result {
                if let number = value as? Double { self?.trackersSeen = Int(number) }
                else if let number = value as? Int { self?.trackersSeen = number }
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView,
              let url = webView.url,
              url.absoluteString != "about:blank" else { return }
        isStart = false
        displayedURL = url
        addressText = url.host ?? url.absoluteString
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
        onPageLoaded?()
        auditTrackers()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        isLoading = false
    }

    /// Keep popups and target=_blank links inside the tab that opened them.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            self.webView.load(navigationAction.request)
        }
        return nil
    }
}