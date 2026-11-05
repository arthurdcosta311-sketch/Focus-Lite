//
//  BrowserView.swift
//  Focus Lite
//

import SwiftUI
import WebKit
import UIKit

enum Theme {
    /// The accent follows the user's choice in Settings; views re-render
    /// because TabManager forwards the customization store's changes.
    static var accent: Color { CustomizationStore.shared.accentColor }
    static let deepIndigo = Color(red: 0.09, green: 0.09, blue: 0.24)
    static let incognito = Color(red: 0.66, green: 0.5, blue: 0.95)
    static let incognitoDeep = Color(red: 0.04, green: 0.02, blue: 0.10)
    static let christmasRed = Color(red: 0.85, green: 0.16, blue: 0.19)
    static let pineNight = Color(red: 0.04, green: 0.16, blue: 0.11)
    /// The app's night color: pine green in Christmas mode, deep indigo otherwise.
    static var baseBackground: Color {
        CustomizationStore.shared.christmasMode ? pineNight : deepIndigo
    }
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
            (manager.isIncognito ? Theme.incognitoDeep : Theme.baseBackground)
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
        .confirmationDialog(
            CustomizationStore.shared.keepCookies
                ? "Clear cookies and sign-ins too?"
                : "Erase browsing data?",
            isPresented: $manager.showEraseConfirmation,
            titleVisibility: .visible
        ) {
            if CustomizationStore.shared.keepCookies {
                Button("Erase everything, including cookies and sign-ins", role: .destructive) {
                    manager.erase(clearCookies: true)
                }
                Button("Erase history only, keep cookies and sign-ins") {
                    manager.erase(clearCookies: false)
                }
            } else {
                Button("Erase everything", role: .destructive) {
                    manager.erase(clearCookies: true)
                }
                Button("Turn on Keep cookies and sign-ins") {
                    CustomizationStore.shared.keepCookies = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(CustomizationStore.shared.keepCookies
                 ? "Cookies and website sign-ins are set to stay on this device. Keep them, or wipe them along with the history."
                 : "Cookies and sign-ins die with every session. You can start keeping them instead.")
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
                (incognito ? Theme.incognitoDeep : Theme.baseBackground)
                    .ignoresSafeArea()
                StartScreen(model: model, incognito: incognito)
                if CustomizationStore.shared.christmasMode && !incognito {
                    Snowfall()
                        .ignoresSafeArea()
                }
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
    @State private var availableHeight: CGFloat = 0
    /// The live drag offset while the user moves the bar; committed to the
    /// customization store when the drag ends.
    @State private var dragLift: CGFloat = 0

    /// How far the bottom bar is lifted up from its default spot right now.
    private var barLift: CGFloat {
        max(0, min(CGFloat(CustomizationStore.shared.searchBarLift) + dragLift,
                   maxBarLift))
    }
    /// Keeps the bar from covering the status bar area at the top.
    private var maxBarLift: CGFloat { max(0, availableHeight - 190) }

    private var moveBarGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                dragLift = -value.translation.height
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    CustomizationStore.shared.searchBarLift = Double(barLift)
                }
                dragLift = 0
            }
    }

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
                VStack(spacing: 8) {
                    if showTrackerTip, let model = manager.activeTab?.model {
                        TrackerTip(model: model)
                            .padding(.horizontal, 24)
                            .onTapGesture { withAnimation { showTrackerTip = false } }
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if let toastText = manager.toastText {
                        StatusToast(text: toastText, symbol: manager.toastSymbol,
                                    actionTitle: manager.toastActionTitle) {
                            manager.allowPopupsForLastBlockedSite()
                        }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let model = manager.activeTab?.model {
                        PhoneBottomBar(manager: manager, model: model,
                                       showTrackerTip: $showTrackerTip,
                                       addressFocused: $addressFocused,
                                       isWide: availableWidth >= 432)
                            .gesture(moveBarGesture)
                    }
                }
                .offset(y: -barLift)
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
                    .onChange(of: geo.size.height, initial: true) { _, height in
                        availableHeight = height
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
        let minimal = CustomizationStore.shared.minimalisticMode
        Group {
            if isWide || minimal {
                HStack(spacing: 10) {
                    if !minimal {
                        incognitoButton
                    }
                    tabsButton

                    if !model.isStart {
                        backButton
                    }

                    AddressField(model: model, showTrackerTip: $showTrackerTip,
                                 addressFocused: addressFocused)

                    if !model.isStart {
                        reloadButton
                    }

                    if !minimal {
                        eraseButton
                    }
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
        Button(action: manager.requestErase) {
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
            (manager.isIncognito ? Theme.incognitoDeep : Theme.baseBackground)
                .ignoresSafeArea()
                .opacity(0.98)

            if CustomizationStore.shared.christmasMode && !manager.isIncognito {
                Snowfall()
                    .ignoresSafeArea()
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text("\(manager.tabs.count) tab\(manager.tabs.count == 1 ? "" : "s")")
                        .font(.title3.bold())
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation { manager.closeAll() }
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
    let incognito: Bool

    private let links: [(title: String, symbol: String, url: String)] = [
        ("Wikipedia", "book.fill", "https://en.wikipedia.org"),
        ("Merry Christmas", "snowflake", "https://en.wikipedia.org/wiki/Christmas"),
        ("Hacker News", "newspaper.fill", "https://news.ycombinator.com"),
        ("GitHub", "chevron.left.forwardslash.chevron.right", "https://github.com/arthurdcosta311-sketch")
    ]

    var body: some View {
        let minimal = CustomizationStore.shared.minimalisticMode
        let christmas = CustomizationStore.shared.christmasMode
        VStack(spacing: 24) {
            Spacer()
            FestiveLogo()
            VStack(spacing: 6) {
                Text("Focus Lite")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                if !minimal {
                    Text("A featherweight, private browser.")
                        .foregroundStyle(.secondary)
                }
                if christmas && !minimal {
                    Text("Merry Christmas!")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.christmasRed)
                }
            }
            VStack(spacing: 4) {
                Text("Search or type an address in the bar below.")
                    .font(.subheadline)
                if !minimal {
                    Text(incognito
                         ? "Nothing in an incognito session is saved — it wipes when you leave."
                         : "Sign-ins and site data stay on this device until you erase them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(.center)

            if !minimal {
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
            }

            Spacer()
            Spacer()
        }
        .padding()
        .foregroundStyle(.white)
    }
}

// MARK: - Festive logo & snow

/// The in-app logo: the shield mark in full Christmas dress — a Santa hat,
/// snow-capped pine sprigs, holly berries and snowflakes, matching the icon.
struct FestiveLogo: View {
    private let pine = Color(red: 0.16, green: 0.45, blue: 0.28)

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 132, height: 132)

            PineSprig()
                .stroke(pine, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 54, height: 44)
                .rotationEffect(.degrees(-36))
                .offset(x: -46, y: 36)

            PineSprig()
                .stroke(pine, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .frame(width: 54, height: 44)
                .scaleEffect(x: -1)
                .rotationEffect(.degrees(-36))
                .offset(x: 46, y: 36)

            ForEach([-46.0, 46.0], id: \.self) { x in
                HStack(spacing: 3) {
                    Circle().fill(Theme.christmasRed).frame(width: 7, height: 7)
                    Circle().fill(Theme.christmasRed).frame(width: 7, height: 7)
                    Circle().fill(Theme.christmasRed).frame(width: 7, height: 7)
                }
                .offset(x: x, y: 52)
            }

            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(Theme.accent)
                .overlay(alignment: .top) {
                    SantaHat()
                        .rotationEffect(.degrees(8), anchor: .bottom)
                        .offset(x: 4, y: -24)
                }

            Image(systemName: "snowflake")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .offset(x: -56, y: -44)
            Image(systemName: "snowflake")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .offset(x: 60, y: -32)
        }
        .frame(height: 132)
    }
}

/// A pine sprig: a diagonal stem with needles, drawn as one stroked path.
struct PineSprig: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: w, y: 0))
        let needlePairs = 6
        for step in 1...needlePairs {
            let t = CGFloat(step) / CGFloat(needlePairs + 1)
            let x = w * t, y = h * (1 - t)
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x + 10, y: y - 5))
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x - 4, y: y - 11))
        }
        return path
    }
}

/// A small Santa hat drawn with shapes: red cap, white trim, pompom.
/// Everything is laid out in one 48×33 frame so the pieces can't drift apart.
struct SantaHat: View {
    var body: some View {
        ZStack {
            SantaHatCap()
                .fill(Theme.christmasRed)
                .frame(width: 48, height: 33)
            SantaHatTrim()
                .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .frame(width: 48, height: 33)
            Circle()
                .fill(.white)
                .frame(width: 11, height: 11)
                .offset(x: 18, y: -6)
        }
        .frame(width: 48, height: 33)
    }
}

/// The cap: a smooth dome whose tip droops over to the right at (42, 10).
/// All curves stay inside the 48×33 frame, so nothing is clipped or spiky.
struct SantaHatCap: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 27))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 22, y: rect.minY),
            control: CGPoint(x: rect.minX + 8, y: rect.minY + 1)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 42, y: rect.minY + 10),
            control: CGPoint(x: rect.minX + 34, y: rect.minY + 1)
        )
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 36, y: rect.minY + 27),
            control: CGPoint(x: rect.minX + 42, y: rect.minY + 20)
        )
        path.closeSubpath()
        return path
    }
}

/// The trim: a white arc stroked across the cap's base, rising slightly in
/// the middle so it hugs the dome and covers the base line.
struct SantaHatTrim: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 1, y: rect.minY + 30))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + 37, y: rect.minY + 30),
            control: CGPoint(x: rect.minX + 19, y: rect.minY + 22)
        )
        return path
    }
}

/// Gentle falling snow for Christmas mode, redrawn every frame with Canvas.
struct Snowfall: View {
    private let flakeCount = 60

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                for index in 0..<flakeCount {
                    let seed = Double(index)
                    let baseX = (seed * 0.6180339887).truncatingRemainder(dividingBy: 1)
                    let speed = 18 + (seed * 0.317).truncatingRemainder(dividingBy: 1) * 32
                    let drift = sin(t * 0.5 + seed) * 9
                    let travel = t * speed + seed * 173.0
                    let y = travel.truncatingRemainder(dividingBy: size.height + 60) - 30
                    let x = baseX * size.width + drift
                    let radius = 1.2 + (seed * 0.271).truncatingRemainder(dividingBy: 1) * 2.2
                    let opacity = 0.2 + (seed * 0.113).truncatingRemainder(dividingBy: 1) * 0.55
                    let frame = CGRect(x: x - radius, y: y - radius,
                                       width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: frame), with: .color(.white.opacity(opacity)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
