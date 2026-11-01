//
//  BrowserView.swift
//  Focus Lite
//

import SwiftUI
import WebKit
import UIKit

enum Theme {
    static let accent = Color(red: 1.0, green: 0.545, blue: 0.235)
    static let deepIndigo = Color(red: 0.09, green: 0.09, blue: 0.24)
    static let incognito = Color(red: 0.66, green: 0.5, blue: 0.95)
    static let incognitoDeep = Color(red: 0.04, green: 0.02, blue: 0.10)
}

struct BrowserView: View {
    @StateObject private var manager = TabManager()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
                IPadBrowserLayout(manager: manager)
            } else {
                PhoneBrowserLayout(manager: manager)
            }
        }
        .background(
            (manager.isIncognito ? Theme.incognitoDeep : Theme.deepIndigo)
                .ignoresSafeArea()
        )
        .overlay {
            if manager.isIncognito && scenePhase != .active {
                IncognitoPrivacyScreen()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: manager.isIncognito)
        .sheet(isPresented: $manager.showSettings) {
            SettingsSheet(manager: manager)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
                    manager.captureTabPreviews()
                }
            } else {
                manager.clearTabPreviews()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Tab content

/// Every tab's web view stays mounted so pages keep their state across tab
/// switches; only the active tab is visible and interactive.
struct TabContentView: View {
    @ObservedObject var manager: TabManager

    var body: some View {
        ZStack {
            ForEach(manager.tabs) { tab in
                WebViewContainer(webView: tab.model.webView)
                    // Bottom edge runs under the home indicator, but the top
                    // stays below the status bar / Dynamic Island.
                    .ignoresSafeArea(edges: [.bottom])
                    .opacity(tab.id == manager.activeTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == manager.activeTabID)
            }
            if let active = manager.activeTab {
                StartOverlay(model: active.model, incognito: manager.isIncognito)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: manager.activeTabID)
    }
}

private struct StartOverlay: View {
    @ObservedObject var model: BrowserModel
    let incognito: Bool

    var body: some View {
        if model.isStart {
            ZStack {
                (incognito ? Theme.incognitoDeep : Theme.deepIndigo)
                    .ignoresSafeArea()
                StartScreen(model: model)
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Shared chrome pieces

struct ProgressBar: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.08))
                if model.isLoading {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(10, geo.size.width * model.progress))
                }
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.15), value: model.progress)
    }
}

struct TrackerTip: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        Text(model.trackersSeen > 0
             ? "\(model.trackersSeen) tracking resource\(model.trackersSeen == 1 ? "" : "s") seen on this page — known trackers are blocked by the engine."
             : "No trackers seen on this page. Known trackers are blocked by the engine.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 320)
    }
}

struct IncognitoPill: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "eyeglasses")
            Text("Incognito")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.incognito)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.incognito.opacity(0.15), in: Capsule())
    }
}

struct AddressField: View {
    @ObservedObject var model: BrowserModel
    @Binding var showTrackerTip: Bool
    var addressFocused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Button { withAnimation { showTrackerTip.toggle() } } label: {
                HStack(spacing: 3) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 12, weight: .bold))
                    if model.trackersSeen > 0 {
                        Text("\(model.trackersSeen)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(model.trackersSeen > 0 ? Theme.accent : Color.secondary)
            }

            TextField("Search or enter address", text: $model.addressText)
                .textFieldStyle(.plain)
                .submitLabel(.go)
                .focused(addressFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .onSubmit {
                    model.load(model.addressText)
                    addressFocused.wrappedValue = false
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { addressFocused.wrappedValue = false }
                    }
                }

            if addressFocused.wrappedValue && !model.addressText.isEmpty {
                Button {
                    model.addressText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.08), in: Capsule())
    }
}

// MARK: - Phone layout

struct PhoneBrowserLayout: View {
    @ObservedObject var manager: TabManager
    @FocusState private var addressFocused: Bool
    @State private var showTrackerTip = false
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        ZStack {
            TabContentView(manager: manager)

            VStack(spacing: 8) {
                if let model = manager.activeTab?.model {
                    ProgressBar(model: model)
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                }
                if manager.isIncognito {
                    IncognitoPill()
                }
                Spacer()
                if showTrackerTip, let model = manager.activeTab?.model {
                    TrackerTip(model: model)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                        .onTapGesture { withAnimation { showTrackerTip = false } }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let toastText = manager.toastText {
                    StatusToast(text: toastText, symbol: manager.toastSymbol,
                                actionTitle: manager.toastActionTitle) {
                        manager.allowPopupsForLastBlockedSite()
                    }
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let model = manager.activeTab?.model {
                    PhoneBottomBar(manager: manager, model: model,
                                   showTrackerTip: $showTrackerTip,
                                   addressFocused: $addressFocused,
                                   isWide: availableWidth >= 432)
                }
            }

            if manager.showTabSwitcher {
                TabSwitcher(manager: manager)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: manager.showTabSwitcher)
        .onChange(of: manager.showTabSwitcher) { _, isShowing in
            if !isShowing { manager.clearTabPreviews() }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onChange(of: geo.size.width, initial: true) { _, width in
                        availableWidth = width
                    }
            }
        )
    }
}

private struct PhoneBottomBar: View {
    @ObservedObject var manager: TabManager
    @ObservedObject var model: BrowserModel
    @Binding var showTrackerTip: Bool
    var addressFocused: FocusState<Bool>.Binding
    /// Wide phones (Plus/Max) fit everything on one row; narrower iPhones
    /// stack the address field above the buttons so nothing overflows.
    let isWide: Bool

    var body: some View {
        Group {
            if isWide {
                HStack(spacing: 10) {
                    incognitoButton
                    tabsButton

                    if !model.isStart {
                        backButton
                    }

                    AddressField(model: model, showTrackerTip: $showTrackerTip,
                                 addressFocused: addressFocused)

                    if !model.isStart {
                        reloadButton
                    }

                    eraseButton
                    settingsButton
                }
            } else {
                VStack(spacing: 10) {
                    AddressField(model: model, showTrackerTip: $showTrackerTip,
                                 addressFocused: addressFocused)

                    HStack(spacing: 18) {
                        incognitoButton
                        tabsButton

                        if !model.isStart {
                            backButton
                        }

                        if !model.isStart {
                            reloadButton
                        }

                        eraseButton
                        settingsButton
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var incognitoButton: some View {
        Button {
            withAnimation { manager.toggleIncognito() }
        } label: {
            Image(systemName: "eyeglasses")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(manager.isIncognito ? Theme.incognito : Color.white)
        }
    }

    private var tabsButton: some View {
        Button {
            withAnimation { manager.openTabSwitcher() }
        } label: {
            Image(systemName: "square.on.square")
                .font(.system(size: 15, weight: .semibold))
                .overlay(alignment: .topTrailing) {
                    if manager.tabs.count > 1 {
                        Text("\(manager.tabs.count)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.deepIndigo)
                            .padding(3)
                            .background(Theme.accent, in: Circle())
                            .offset(x: 7, y: -5)
                    }
                }
        }
    }

    private var backButton: some View {
        Button(action: model.goBack) {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
        }
        .disabled(!model.canGoBack)
        .opacity(model.canGoBack ? 1 : 0.3)
    }

    private var reloadButton: some View {
        Button(action: model.toggleReload) {
            Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                .font(.system(size: 15, weight: .semibold))
        }
    }

    private var eraseButton: some View {
        Button(action: manager.erase) {
            Image(systemName: "trash")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
    }

    private var settingsButton: some View {
        Button { manager.showSettings = true } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 15, weight: .semibold))
        }
    }
}

// MARK: - Tab switcher (iPhone)

private struct TabSwitcher: View {
    @ObservedObject var manager: TabManager

    var body: some View {
        ZStack {
            (manager.isIncognito ? Theme.incognitoDeep : Theme.deepIndigo)
                .ignoresSafeArea()
                .opacity(0.98)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text("\(manager.tabs.count) tab\(manager.tabs.count == 1 ? "" : "s")")
                        .font(.title3.bold())
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation { manager.erase() }
                        manager.showTabSwitcher = false
                    } label: {
                        Text("Close All")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.red)
                    }
                    Button {
                        withAnimation { _ = manager.addTab() }
                        manager.showTabSwitcher = false
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    Button {
                        manager.showTabSwitcher = false
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                }
                .foregroundStyle(.white)

                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                              spacing: 12) {
                        ForEach(manager.tabs) { tab in
                            TabCard(manager: manager, model: tab.model, tabID: tab.id)
                        }
                    }
                }
            }
            .padding()
        }
    }
}

private struct TabCard: View {
    @ObservedObject var manager: TabManager
    @ObservedObject var model: BrowserModel
    let tabID: Tab.ID

    private var isActive: Bool { tabID == manager.activeTabID }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                if let image = model.previewImage, !model.isStart {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.white.opacity(0.10))
                        )
                } else {
                    Image(systemName: model.isStart ? "shield.lefthalf.filled" : "globe")
                        .font(.system(size: 22))
                        .foregroundStyle(isActive ? Theme.accent : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 88)
                }
                Text(model.displayedURL?.host ?? "Start Page")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(isActive ? 0.14 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        isActive ? Theme.accent.opacity(0.6) : Color.white.opacity(0.08),
                        lineWidth: isActive ? 2 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture {
                withAnimation {
                    manager.select(tabID)
                    manager.showTabSwitcher = false
                }
            }

            Button {
                withAnimation { manager.close(tabID) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .offset(x: 6, y: -6)
        }
        .frame(height: 150)
    }
}

// MARK: - Web view container

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Start screen

private struct StartScreen: View {
    @ObservedObject var model: BrowserModel

    private let links: [(title: String, symbol: String, url: String)] = [
        ("Wikipedia", "book.fill", "https://en.wikipedia.org"),
        ("DuckDuckGo", "magnifyingglass", "https://duckduckgo.com"),
        ("Hacker News", "newspaper.fill", "https://news.ycombinator.com"),
        ("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com")
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 100, height: 100)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 6) {
                Text("Focus Lite")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("A featherweight, private browser.")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                Text("Search or type an address in the bar below.")
                    .font(.subheadline)
                Text("Every session starts fresh — nothing is saved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            HStack(spacing: 14) {
                ForEach(links, id: \.title) { link in
                    Button {
                        model.load(link.url)
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: link.symbol)
                                .font(.system(size: 20, weight: .semibold))
                            Text(link.title)
                                .font(.caption)
                        }
                        .frame(width: 74, height: 74)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)

            Spacer()
            Spacer()
        }
        .padding()
        .foregroundStyle(.white)
    }
}

// MARK: - Status toast

struct StatusToast: View {
    let text: String
    var symbol = "checkmark.circle.fill"
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(text)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }
}

// MARK: - Incognito privacy screen

/// Covers all content while the app is in the app switcher or backgrounded in
/// incognito mode, so page content never shows in task switcher snapshots.
private struct IncognitoPrivacyScreen: View {
    var body: some View {
        ZStack {
            Theme.incognitoDeep.ignoresSafeArea()
            VStack(spacing: 10) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 40, weight: .bold))
                Text("Incognito")
                    .font(.headline)
            }
            .foregroundStyle(Theme.incognito)
        }
    }
}
