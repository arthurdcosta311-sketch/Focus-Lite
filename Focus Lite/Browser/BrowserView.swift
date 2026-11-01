//
//  BrowserView.swift
//  Focus Lite
//

import SwiftUI
import WebKit

enum Theme {
    static let accent = Color(red: 1.0, green: 0.545, blue: 0.235)
    static let deepIndigo = Color(red: 0.09, green: 0.09, blue: 0.24)
    static let incognito = Color(red: 0.66, green: 0.5, blue: 0.95)
    static let incognitoDeep = Color(red: 0.04, green: 0.02, blue: 0.10)
}

struct BrowserView: View {
    @StateObject private var model = BrowserModel()
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var addressFocused: Bool
    @State private var showTrackerTip = false

    var body: some View {
        ZStack {
            (model.isIncognito ? Theme.incognitoDeep : Theme.deepIndigo)
                .ignoresSafeArea()

            if model.isStart {
                StartScreen(model: model)
                    .transition(.opacity)
            } else {
                WebViewContainer(webView: model.webView)
                    .ignoresSafeArea(edges: [.top, .bottom])
                    .transition(.opacity)
            }

            VStack(spacing: 8) {
                progressBar
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                if model.isIncognito {
                    incognitoPill
                }
                Spacer()
                if showTrackerTip {
                    trackerTip
                        .padding(.horizontal, 24)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if model.showErasedToast {
                    StatusToast(text: "Browsing data erased")
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if model.showIncognitoToast {
                    StatusToast(text: model.incognitoToastText, symbol: "eyeglasses")
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                bottomBar
            }

            if model.isIncognito && scenePhase != .active {
                IncognitoPrivacyScreen()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.isStart)
        .animation(.easeInOut(duration: 0.25), value: model.isIncognito)
        .sheet(isPresented: $model.showSettings) {
            SettingsSheet(model: model)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Pieces

    private var progressBar: some View {
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

    private var trackerTip: some View {
        Text(model.trackersSeen > 0
             ? "\(model.trackersSeen) tracking resource\(model.trackersSeen == 1 ? "" : "s") seen on this page — known trackers are blocked by the engine."
             : "No trackers seen on this page. Known trackers are blocked by the engine.")
            .font(.caption)
            .multilineTextAlignment(.center)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 320)
            .onTapGesture { withAnimation { showTrackerTip = false } }
    }

    private var incognitoPill: some View {
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

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation { model.toggleIncognito() }
            } label: {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(model.isIncognito ? Theme.incognito : Color.white)
            }

            if !model.isStart {
                Button(action: model.goBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                }
                .disabled(!model.canGoBack)
                .opacity(model.canGoBack ? 1 : 0.3)
            }

            addressField

            if !model.isStart {
                Button(action: model.toggleReload) {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                }
            }

            Button(action: model.erase) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            Button { model.showSettings = true } label: {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 15, weight: .semibold))
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

    private var addressField: some View {
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
                .focused($addressFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .onSubmit {
                    model.load(model.addressText)
                    addressFocused = false
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { addressFocused = false }
                    }
                }

            if addressFocused && !model.addressText.isEmpty {
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

private struct StatusToast: View {
    let text: String
    var symbol = "checkmark.circle.fill"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(text)
                .font(.subheadline.weight(.medium))
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