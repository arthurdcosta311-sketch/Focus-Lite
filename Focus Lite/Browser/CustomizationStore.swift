//
//  CustomizationStore.swift
//  Focus Lite
//

import SwiftUI

/// The accent colors the app ships with. The raw value is the string the
/// choice is persisted under.
enum Accent: String, CaseIterable, Identifiable {
    case tangerine, coral, amber, mint, sky, violet, rose

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .tangerine: return Color(red: 1.0, green: 0.545, blue: 0.235)
        case .coral: return Color(red: 1.0, green: 0.42, blue: 0.42)
        case .amber: return Color(red: 1.0, green: 0.78, blue: 0.25)
        case .mint: return Color(red: 0.34, green: 0.85, blue: 0.6)
        case .sky: return Color(red: 0.35, green: 0.65, blue: 1.0)
        case .violet: return Color(red: 0.66, green: 0.5, blue: 0.95)
        case .rose: return Color(red: 1.0, green: 0.45, blue: 0.7)
        }
    }

    var displayName: String { rawValue.capitalized }
}

/// The engines the address bar can send a plain search term to. The query is
/// passed through URLComponents, so it is encoded correctly for each engine.
enum SearchEngine: String, CaseIterable, Identifiable {
    case focus, duckduckgo, google, bing, brave, startpage, ecosia, qwant, custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .focus: return "Focus Search · built-in"
        case .duckduckgo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .startpage: return "Startpage"
        case .ecosia: return "Ecosia"
        case .qwant: return "Qwant"
        case .custom: return "Custom…"
        }
    }

    func searchURL(for query: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .focus:
            return nil // Handled by BrowserModel, which renders the results page in the tab.
        case .duckduckgo:
            components = URLComponents(string: "https://duckduckgo.com/")
        case .google:
            components = URLComponents(string: "https://www.google.com/search")
        case .bing:
            components = URLComponents(string: "https://www.bing.com/search")
        case .brave:
            components = URLComponents(string: "https://search.brave.com/search")
        case .startpage:
            components = URLComponents(string: "https://www.startpage.com/sp/search")
        case .ecosia:
            components = URLComponents(string: "https://www.ecosia.org/search")
        case .qwant:
            components = URLComponents(string: "https://www.qwant.com/")
        case .custom:
            return nil // Handled by CustomizationStore, which owns the template.
        }
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

/// The user's look-and-feel and search preferences. Only the choices
/// themselves are saved on device — nothing here describes browsing activity,
/// so the choices survive an erase like the pop-up blocker setting does.
final class CustomizationStore: ObservableObject {
    static let shared = CustomizationStore()

    @Published var accent: Accent {
        didSet { defaults.set(accent.rawValue, forKey: Keys.accent) }
    }
    @Published var searchEngine: SearchEngine {
        didSet { defaults.set(searchEngine.rawValue, forKey: Keys.searchEngine) }
    }
    @Published var customSearchTemplate: String {
        didSet { defaults.set(customSearchTemplate, forKey: Keys.customSearchTemplate) }
    }
    @Published var homepageEnabled: Bool {
        didSet { defaults.set(homepageEnabled, forKey: Keys.homepageEnabled) }
    }
    @Published var homepageText: String {
        didSet { defaults.set(homepageText, forKey: Keys.homepageText) }
    }
    /// WebKit page zoom as a fraction of the default size (1.0 = 100%).
    @Published var pageZoom: Double {
        didSet { defaults.set(pageZoom, forKey: Keys.pageZoom) }
    }
    /// Strips the interface down: no start-page shortcuts or tagline, a
    /// single-row bar on iPhone, and the incognito/erase buttons move to
    /// Settings only.
    @Published var minimalisticMode: Bool {
        didSet { defaults.set(minimalisticMode, forKey: Keys.minimalisticMode) }
    }
    /// How far the iPhone bottom bar (the search bar and its buttons) has
    /// been dragged up from its default position, in points. Saved so the
    /// bar stays where the user left it in both normal and minimalistic
    /// mode; 0 means the default spot at the bottom.
    @Published var searchBarLift: Double {
        didSet { defaults.set(searchBarLift, forKey: Keys.searchBarLift) }
    }
    /// Festive seasonal look: a pine-green night, falling snow on the start
    /// screen and tab switcher, and a holiday greeting. A look only — nothing
    /// about browsing behavior changes. On by default; users who turn it off
    /// stay off.
    @Published var christmasMode: Bool {
        didSet { defaults.set(christmasMode, forKey: Keys.christmasMode) }
    }
    /// Focus Search's optional DNS check for typed domains. Off by default:
    /// plenty of small and open-source sites aren't registered with the big
    /// public resolvers, so verification is only for people who want it.
    @Published var verifyDomains: Bool {
        didSet { defaults.set(verifyDomains, forKey: Keys.verifyDomains) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = Accent(rawValue: defaults.string(forKey: Keys.accent) ?? "") ?? .tangerine
        searchEngine = SearchEngine(rawValue: defaults.string(forKey: Keys.searchEngine) ?? "") ?? .focus
        customSearchTemplate = defaults.string(forKey: Keys.customSearchTemplate) ?? "https://duckduckgo.com/?q=%s"
        homepageEnabled = defaults.bool(forKey: Keys.homepageEnabled)
        homepageText = defaults.string(forKey: Keys.homepageText) ?? ""
        pageZoom = defaults.object(forKey: Keys.pageZoom) as? Double ?? 1.0
        minimalisticMode = defaults.bool(forKey: Keys.minimalisticMode)
        searchBarLift = defaults.object(forKey: Keys.searchBarLift) as? Double ?? 0
        christmasMode = defaults.object(forKey: Keys.christmasMode) as? Bool ?? true
        verifyDomains = defaults.bool(forKey: Keys.verifyDomains)
    }

    private enum Keys {
        static let accent = "customization.accent"
        static let searchEngine = "customization.searchEngine"
        static let customSearchTemplate = "customization.customSearchTemplate"
        static let homepageEnabled = "customization.homepageEnabled"
        static let homepageText = "customization.homepageText"
        static let pageZoom = "customization.pageZoom"
        static let minimalisticMode = "customization.minimalisticMode"
        static let searchBarLift = "customization.searchBarLift"
        static let christmasMode = "customization.christmasMode"
        static let verifyDomains = "customization.verifyDomains"
    }

    var accentColor: Color { accent.color }

    /// Where the address bar sends a plain search term. A custom template is
    /// an absolute http(s) URL containing %s where the encoded term goes.
    func searchURL(for query: String) -> URL? {
        switch searchEngine {
        case .custom:
            let template = customSearchTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard template.lowercased().hasPrefix("http"), template.contains("%s") else { return nil }
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
            return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
        default:
            return searchEngine.searchURL(for: query)
        }
    }

    /// The page a new tab opens with when homepage mode is on. Addresses
    /// typed without a scheme get https; an empty field means the start screen.
    func homepageURL() -> URL? {
        guard homepageEnabled else { return nil }
        let text = homepageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let scheme = URL(string: text)?.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return URL(string: text)
        }
        return URL(string: "https://" + text)
    }
}