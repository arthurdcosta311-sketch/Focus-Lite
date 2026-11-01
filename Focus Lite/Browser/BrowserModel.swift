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

    init(dataStore: WKWebsiteDataStore = .nonPersistent()) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let controller = WKUserContentController()
        configuration.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

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
        BrowserLogStore.shared.record("Navigation requested · \(url.host ?? "unknown host")")
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