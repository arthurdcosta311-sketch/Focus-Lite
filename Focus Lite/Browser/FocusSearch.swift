//
//  FocusSearch.swift
//  Focus Lite
//

import SwiftUI

/// A single web result shown on the Focus engine's results page.
struct FocusSearchResult: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    let snippet: String
    let source: String
}

/// An image result for the Images tab.
struct FocusSearchImage: Identifiable {
    let id = UUID()
    let title: String
    let imageURL: URL
    let thumbnailURL: URL
    let sourceURL: URL?
}

/// What one search returns: a real list of web results (title, snippet, URL),
/// an instant answer card when one exists, and — when the term looks like a
/// domain the DNS resolver actually answers — a direct-navigation site.
struct FocusSearchResponse {
    var instantHeading: String?
    var instantText: String?
    var instantSource: String?
    var instantURL: URL?
    var results: [FocusSearchResult] = []
    /// Links from the Instant Answer API, shown only when the web-results
    /// fetch comes back empty.
    var relatedLinks: [FocusSearchResult] = []
    var directSite: URL?

    var hasInstantAnswer: Bool { !(instantText ?? "").isEmpty }
}

/// Focus Lite's own search engine. Web results come from DuckDuckGo's
/// lightweight HTML endpoint, parsed into ordinary title/snippet/URL rows;
/// instant answers come from its key-less open API. Typed domains are verified
/// with DNS-over-HTTPS lookups against the resolver the user picked in
/// Settings (Cloudflare, Quad9 or Google), so the domain check rides the same
/// encrypted DNS path the browser already uses. No account, cookies or
/// history: the rendered page lives in the ephemeral web view and dies with
/// the session.
final class FocusSearchService {
    static let shared = FocusSearchService()
    /// Results shown per page: "Search for more" loads 10 more each tap.
    static let pageSize = 10

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    func search(_ query: String) async -> FocusSearchResponse {
        async let results = fetchResults(query)
        var response = await results
        // Verification is optional: plenty of small and open-source sites
        // aren't "verified", so the DNS check only runs when the user turns
        // it on in Settings. Either way, domain-shaped terms get a direct link.
        if let site = Self.directSiteURL(for: query) {
            if CustomizationStore.shared.verifyDomains {
                if await checkDomain(query) { response.directSite = site }
            } else {
                response.directSite = site
            }
        }
        return response
    }

    // MARK: - Results

    private func fetchResults(_ query: String) async -> FocusSearchResponse {
        async let instant = fetchInstantAnswer(query)
        async let web = fetchWebResults(query, offset: 0)
        var response = await instant
        let webResults = await web
        response.results = webResults.isEmpty ? response.relatedLinks : webResults
        return response
    }

    /// One page of web results, offset like a traditional engine's pagination.
    /// The results page's "More results" link navigates here.
    func webResults(for query: String, offset: Int) async -> [FocusSearchResult] {
        await fetchWebResults(query, offset: offset)
    }

    /// Image results for the Images tab. Sources are tried in order until
    /// one returns parseable images: Google (the best index and thumbnails),
    /// then Bing (whose results carry image + thumbnail as plain JSON),
    /// then DuckDuckGo. Each attempt is logged — without the query — so the
    /// session log shows which source is actually serving.
    func imageResults(for query: String, offset: Int) async -> [FocusSearchImage] {
        let google = await googleImages(for: query, offset: offset)
        BrowserLogStore.shared.record("Images · Google returned \(google.count)")
        if !google.isEmpty { return google }

        let bing = await bingImages(for: query, offset: offset)
        BrowserLogStore.shared.record("Images · Bing returned \(bing.count)")
        if !bing.isEmpty { return bing }

        let duckduckgo = await duckduckgoImages(for: query, offset: offset)
        BrowserLogStore.shared.record("Images · DuckDuckGo returned \(duckduckgo.count)")
        return duckduckgo
    }

    /// Google Images without JavaScript: the results page embeds its data as
    /// ["url",width,height] blobs — gstatic thumbnails plus the images they
    /// stand for — which parse into the same thumbnail grid. `start` pages
    /// through results the same way Google's own pagination does.
    private func googleImages(for query: String, offset: Int) async -> [FocusSearchImage] {
        var components = URLComponents(string: "https://www.google.com/search")
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "tbm", value: "isch"),
            URLQueryItem(name: "hl", value: "en"),
            // SafeSearch off: image results must not be pre-filtered.
            URLQueryItem(name: "safe", value: "off")
        ]
        if offset > 0 { items.append(URLQueryItem(name: "start", value: String(offset))) }
        components?.queryItems = items
        guard let url = components?.url else { return [] }
        // The modern page embeds its data blobs; a legacy user agent gets
        // Google's basic HTML page with plain /imgres links instead. Try both.
        let modern = await fetchAndParseGoogleImages(url, userAgent: Self.imageUserAgent)
        if !modern.isEmpty { return modern }
        return await fetchAndParseGoogleImages(url, userAgent: Self.basicHTMLUserAgent)
    }

    private func fetchAndParseGoogleImages(_ url: URL, userAgent: String) async -> [FocusSearchImage] {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return [] }
            return Self.parseGoogleImages(html: html)
        } catch {
            return []
        }
    }

    private static func parseGoogleImages(html: String) -> [FocusSearchImage] {
        // Google packs its data with escaped slashes and unicode escapes, so
        // normalize first and let one set of patterns cover every layout.
        let text = html
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\\"", with: "\"")
        var images: [FocusSearchImage] = []
        var seen = Set<String>()

        // Modern layout: results are packed as ["url",width,height] blobs,
        // with gstatic thumbnails pairing, in order, with the images they
        // stand for.
        let blobPattern = /\["(https:\/\/[^"\[\]]+)",(\d+),(\d+)\]/
        var thumbnailURLs: [URL] = []
        var fullImages: [URL] = []
        for match in text.matches(of: blobPattern) {
            let raw = String(match.output.1)
            guard let url = URL(string: raw), url.scheme == "http" || url.scheme == "https" else { continue }
            if raw.contains("gstatic.com") || raw.contains("ggpht.com") {
                thumbnailURLs.append(url)
            } else {
                fullImages.append(url)
            }
        }
        for (index, thumbnail) in thumbnailURLs.enumerated() where index < fullImages.count {
            guard seen.insert(thumbnail.absoluteString).inserted else { continue }
            images.append(FocusSearchImage(title: "", imageURL: fullImages[index], thumbnailURL: thumbnail, sourceURL: nil))
            if images.count >= 30 { break }
        }
        if !images.isEmpty { return images }

        // Basic HTML layout: links through /imgres carry the full image and
        // its source page, with a gstatic thumbnail beside each one.
        let imgresPattern = /imgres\?imgurl=([^&"\\]+)&(?:amp;)?imgrefurl=([^&"\\]+)/
        let thumbPattern = /(https:\/\/(?:encrypted-tbn|tbn)\d*\.gstatic\.com\/images\?[^"'\\\s]+)/
        let imgresLinks = text.matches(of: imgresPattern)
        let thumbs = text.matches(of: thumbPattern).map { String($0.output.1) }
        for (index, link) in imgresLinks.enumerated() {
            guard let imageURL = decodePercent(String(link.output.1)),
                  let thumbURL = index < thumbs.count ? URL(string: thumbs[index]) : nil,
                  seen.insert(imageURL.absoluteString).inserted else { continue }
            let sourceURL = decodePercent(String(link.output.2))
            images.append(FocusSearchImage(title: "", imageURL: imageURL, thumbnailURL: thumbURL, sourceURL: sourceURL))
            if images.count >= 30 { break }
        }
        return images
    }

    private static func decodePercent(_ text: String) -> URL? {
        URL(string: text.removingPercentEncoding ?? text)
    }

    /// Bing Images: every result carries an m="{...}" attribute holding the
    /// original image URL (murl), Bing's thumbnail (turl) and the source page
    /// (purl) as HTML-escaped JSON — no JavaScript and no blob pairing needed,
    /// and `first` pages through results the same way as our offset.
    private func bingImages(for query: String, offset: Int) async -> [FocusSearchImage] {
        var components = URLComponents(string: "https://www.bing.com/images/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "first", value: String(offset + 1)),
            // SafeSearch off.
            URLQueryItem(name: "adlt", value: "off")
        ]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(Self.imageUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return [] }
            return Self.parseBingImages(html: html)
        } catch {
            return []
        }
    }

    private static func parseBingImages(html: String) -> [FocusSearchImage] {
        var images: [FocusSearchImage] = []
        var seen = Set<String>()
        for match in html.matches(of: /m="([^"]+)"/) {
            let json = String(match.1)
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
            guard let data = json.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let murl = entry["murl"] as? String,
                  let imageURL = URL(string: murl) else { continue }
            let thumbnail = (entry["turl"] as? String).flatMap(URL.init(string:)) ?? imageURL
            guard seen.insert(imageURL.absoluteString).inserted else { continue }
            let sourceURL = (entry["purl"] as? String).flatMap(URL.init(string:))
            images.append(FocusSearchImage(title: entry["t"] as? String ?? "", imageURL: imageURL, thumbnailURL: thumbnail, sourceURL: sourceURL))
            if images.count >= 30 { break }
        }
        return images
    }

    /// DuckDuckGo's images endpoint, the fallback. It needs a per-query vqd
    /// token, taken from the search page first.
    private func duckduckgoImages(for query: String, offset: Int) async -> [FocusSearchImage] {
        guard let vqd = await fetchVQD(query) else { return [] }
        var components = URLComponents(string: "https://duckduckgo.com/i.js")
        var items = [
            URLQueryItem(name: "l", value: "wt-wt"),
            URLQueryItem(name: "o", value: "json"),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "vqd", value: vqd),
            URLQueryItem(name: "f", value: ",,,"),
            URLQueryItem(name: "p", value: "1"),
            // SafeSearch off: kp=-2 disables DuckDuckGo's filter.
            URLQueryItem(name: "kp", value: "-2")
        ]
        if offset > 0 { items.append(URLQueryItem(name: "s", value: String(offset))) }
        components?.queryItems = items
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue(Self.imageUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            var images: [FocusSearchImage] = []
            var seen = Set<String>()
            for entry in payload {
                guard let imageString = entry["image"] as? String,
                      let imageURL = URL(string: imageString) else { continue }
                let thumbnailString = entry["thumbnail"] as? String ?? imageString
                guard let thumbnailURL = URL(string: thumbnailString) else { continue }
                guard seen.insert(imageURL.absoluteString).inserted else { continue }
                images.append(FocusSearchImage(
                    title: entry["title"] as? String ?? "",
                    imageURL: imageURL,
                    thumbnailURL: thumbnailURL,
                    sourceURL: (entry["url"] as? String).flatMap(URL.init(string:))
                ))
            }
            return images
        } catch {
            return []
        }
    }

    private func fetchVQD(_ query: String) async -> String? {
        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "iax", value: "images"),
            URLQueryItem(name: "ia", value: "images")
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(Self.imageUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return nil }
            guard let match = html.firstMatch(of: /vqd=["']?([0-9-]+)/) else { return nil }
            return String(match.1)
        } catch {
            return nil
        }
    }

    private static let imageUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    /// A legacy desktop agent, which makes Google serve its basic HTML page.
    private static let basicHTMLUserAgent = "Mozilla/5.0 (Windows NT 10.0; rv:60.0) Gecko/20100101 Firefox/60.0"

    /// Instant answers — abstracts, definitions and computed answers — from
    /// the key-less JSON API. Its related links are a fallback for when the
    /// web-results fetch fails, not the main listing.
    private func fetchInstantAnswer(_ query: String) async -> FocusSearchResponse {
        var components = URLComponents(string: "https://api.duckduckgo.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "no_redirect", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
            URLQueryItem(name: "t", value: "focuslite")
        ]
        guard let url = components?.url else { return FocusSearchResponse() }
        do {
            let (data, _) = try await session.data(from: url)
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return FocusSearchResponse()
            }
            return Self.parseInstantAnswer(payload)
        } catch {
            return FocusSearchResponse()
        }
    }

    private static func parseInstantAnswer(_ payload: [String: Any]) -> FocusSearchResponse {
        var response = FocusSearchResponse()
        let heading = payload["Heading"] as? String
        let abstract = payload["AbstractText"] as? String
        let abstractSource = payload["AbstractSource"] as? String
        let abstractURL = (payload["AbstractURL"] as? String).flatMap(URL.init(string:))
        let answer = payload["Answer"] as? String
        let definition = payload["Definition"] as? String
        let definitionSource = payload["DefinitionSource"] as? String
        let definitionURL = (payload["DefinitionURL"] as? String).flatMap(URL.init(string:))

        if let abstract, !abstract.isEmpty {
            response.instantHeading = heading
            response.instantText = abstract
            response.instantSource = abstractSource
            response.instantURL = abstractURL
        } else if let answer, !answer.isEmpty {
            response.instantHeading = heading
            response.instantText = answer
            response.instantSource = "DuckDuckGo instant answer"
        } else if let definition, !definition.isEmpty {
            response.instantHeading = "Definition"
            response.instantText = definition
            response.instantSource = definitionSource
            response.instantURL = definitionURL
        }

        // Related topics arrive either flat or nested under named groups.
        var topics = payload["RelatedTopics"] as? [[String: Any]] ?? []
        var flat: [[String: Any]] = []
        while !topics.isEmpty {
            let topic = topics.removeFirst()
            if let subs = topic["Topics"] as? [[String: Any]] {
                topics.append(contentsOf: subs)
            } else {
                flat.append(topic)
            }
        }
        for topic in flat.prefix(30) {
            guard let urlString = topic["FirstURL"] as? String,
                  let url = URL(string: urlString),
                  let text = topic["Text"] as? String, !text.isEmpty else { continue }
            let title: String
            let snippet: String
            if let range = text.range(of: " - ") {
                title = String(text[..<range.lowerBound])
                snippet = String(text[range.upperBound...])
            } else {
                title = text
                snippet = ""
            }
            response.relatedLinks.append(FocusSearchResult(title: title, url: url, snippet: snippet, source: "DuckDuckGo"))
        }
        return response
    }

    /// The actual web results, the way a search engine lists them: DuckDuckGo's
    /// lightweight HTML endpoint is fetched and parsed into title/snippet/URL
    /// rows. `offset` pages through results with the endpoint's `s` parameter.
    private func fetchWebResults(_ query: String, offset: Int) async -> [FocusSearchResult] {
        var components = URLComponents(string: "https://lite.duckduckgo.com/lite/")
        var items = [URLQueryItem(name: "q", value: query)]
        if offset > 0 { items.append(URLQueryItem(name: "s", value: String(offset))) }
        components?.queryItems = items
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let html = String(data: data, encoding: .utf8) else { return [] }
            return Self.parseLite(html: html)
        } catch {
            return []
        }
    }

    private static func parseLite(html: String) -> [FocusSearchResult] {
        let anchorPattern = /<a\s([^>]*)>([\s\S]*?)<\/a>/
        let hrefPattern = /href\s*=\s*["']([^"']+)["']/
        let snippetPattern = /<td[^>]*class\s*=\s*['"]result-snippet['"][^>]*>([\s\S]*?)<\/td>/

        // Title anchors carry the result-link class; each result's snippet is
        // a sibling cell that follows it, so snippets are paired by position
        // inside the window between one title anchor and the next.
        var anchors: [(offset: String.Index, attrs: Substring, inner: Substring)] = []
        for match in html.matches(of: anchorPattern) {
            guard match.output.1.contains("result-link") else { continue }
            anchors.append((match.range.lowerBound, match.output.1, match.output.2))
        }
        let snippets: [(offset: String.Index, text: Substring)] = html.matches(of: snippetPattern).map { match in
            (match.range.lowerBound, match.output.1)
        }

        var results: [FocusSearchResult] = []
        var seen = Set<String>()
        for (index, anchor) in anchors.enumerated() {
            let windowEnd = index + 1 < anchors.count ? anchors[index + 1].offset : html.endIndex
            let snippet = snippets.first { $0.offset > anchor.offset && $0.offset < windowEnd }
                .map { decodeHTML(String($0.text)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

            guard let hrefMatch = anchor.attrs.firstMatch(of: hrefPattern) else { continue }
            let href = String(hrefMatch.1)
            let lowered = href.lowercased()
            // Sponsored entries route through ad trackers; they are not results.
            guard !lowered.contains("duckduckgo.com/y.js"),
                  !lowered.contains("ad_provider"), !lowered.contains("ad_domain"),
                  let url = resultURL(from: href) else { continue }
            let title = decodeHTML(String(anchor.inner)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert(url.absoluteString).inserted else { continue }
            results.append(FocusSearchResult(title: title, url: url, snippet: snippet, source: "DuckDuckGo"))
            if results.count >= 30 { break }
        }
        return results
    }

    /// Unwraps DuckDuckGo's redirect links and keeps only plain http(s) targets.
    private static func resultURL(from href: String) -> URL? {
        var target = href
        if target.hasPrefix("//") { target = "https:" + target }
        if let components = URLComponents(string: target),
           components.host?.hasSuffix("duckduckgo.com") == true,
           let redirected = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            target = redirected
        }
        guard let url = URL(string: target), url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    /// Strips stray tags and resolves the HTML entities the endpoint uses.
    private static func decodeHTML(_ text: String) -> String {
        var string = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#x27;": "'", "&#39;": "'", "&apos;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            string = string.replacingOccurrences(of: entity, with: replacement)
        }
        if string.contains("&#") {
            string = string.replacing(/&#(\d+);/) { match in
                guard let code = Int(match.output.1),
                      let scalar = UInt32(exactly: code),
                      let decoded = Unicode.Scalar(scalar) else { return "" }
                return String(decoded)
            }
            string = string.replacing(/&#x([0-9a-fA-F]+);/) { match in
                guard let code = Int(match.output.1, radix: 16),
                      let scalar = UInt32(exactly: code),
                      let decoded = Unicode.Scalar(scalar) else { return "" }
                return String(decoded)
            }
        }
        return string
    }

    // MARK: - DNS

    /// True when the term is domain-shaped and the chosen resolver answers it,
    /// checked with plain DNS-over-HTTPS JSON queries.
    private func checkDomain(_ query: String) async -> Bool {
        guard let domain = Self.domainCandidate(for: query) else { return false }
        return await hostResolves(domain)
    }

    /// True when the chosen resolver answers the host with an address. Shared
    /// by the results page's "open directly" link and the address bar, which
    /// resolves domain-shaped input before choosing between opening the site
    /// and searching for it.
    func hostResolves(_ host: String) async -> Bool {
        let resolver = EncryptedDNSManager.shared.resolver
        // Google publishes its JSON API under /resolve; the others answer
        // application/dns-json on their DoH endpoint directly.
        let endpoint: URL
        switch resolver {
        case .google: endpoint = URL(string: "https://dns.google/resolve")!
        default: endpoint = resolver.serverURL
        }
        for type in ["A", "AAAA"] {
            if await resolves(domain: host, type: type, endpoint: endpoint) {
                return true
            }
        }
        return false
    }

    private func resolves(domain: String, type: String, endpoint: URL) async -> Bool {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "name", value: domain),
            URLQueryItem(name: "type", value: type)
        ]
        guard let url = components?.url else { return false }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "accept")

        struct DNSReply: Decodable {
            struct Entry: Decodable { let type: Int? }
            let Status: Int?
            let Answer: [Entry]?
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let reply = try JSONDecoder().decode(DNSReply.self, from: data)
            let statusOK = reply.Status == 0
            let hasAddress = reply.Answer?.contains { entry in
                entry.type == 1 || entry.type == 28
            } ?? false
            return statusOK && hasAddress
        } catch {
            return false
        }
    }

    // MARK: - Domain shaping

    /// The domain the term refers to, when it looks like one: no spaces, at
    /// least two labels and an alphabetic top level ("3.14" stays a search).
    static func domainCandidate(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains(" "), trimmed.count <= 253,
              trimmed.contains("."), !trimmed.hasPrefix("."), !trimmed.hasSuffix("."),
              !trimmed.hasPrefix("http") else { return nil }
        let labels = trimmed.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        // IPv4 literals have no alphabetic TLD but should still load directly.
        if labels.count == 4, labels.allSatisfy({ label in
            label.allSatisfy(\.isNumber) && (0...255).contains(Int(label) ?? 256)
        }) {
            return trimmed
        }
        guard let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLetter }) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard label.count <= 63,
                  label.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  !label.hasPrefix("-"), !label.hasSuffix("-") else { return nil }
        }
        return trimmed
    }

    static func directSiteURL(for query: String) -> URL? {
        guard let domain = domainCandidate(for: query) else { return nil }
        return URL(string: "https://" + domain)
    }
}

// MARK: - Results page

/// Renders the engine's results as an HTML page loaded straight into the tab's
/// web view — a real search-engine results page, complete with its own search
/// box and pagination. The in-page search box and "More results" link navigate
/// to the custom focussearch:// scheme, which BrowserModel intercepts and turns
/// into a fresh results page, so the whole experience stays inside the tab.
enum FocusSearchPage {
    static let scheme = "focussearch"

    /// The placeholder page shown while results are being fetched.
    static func searchingPage(query: String, tab: String) -> String {
        pageShell(query: query, tab: tab, body: "<div class=\"status\">Searching…</div>")
    }

    /// The classic results page: link-colored titles, green breadcrumbs,
    /// snippets, an instant answer box and a pagination link.
    static func resultsPage(query: String, response: FocusSearchResponse, offset: Int, hasMore: Bool) -> String {
        var body = ""

        if let site = response.directSite {
            // Verification is optional, so the note only appears when it ran.
            let note = CustomizationStore.shared.verifyDomains
                ? "<span class=\"direct-note\">Domain verified over encrypted DNS</span>"
                : ""
            body += """
            <a class="direct" href="\(escape(site.absoluteString))">
              <span class="direct-title">Open \(escape(site.host ?? site.absoluteString)) directly</span>
              \(note)
            </a>
            """
        }

        if response.hasInstantAnswer {
            var answer = """
            <div class="answer">
              <div class="answer-title">Instant answer\(response.instantSource == "DuckDuckGo instant answer" ? "" : response.instantSource.map { " · \($0)" } ?? "")</div>
              <div class="answer-text">\(escape(response.instantText ?? ""))</div>
            """
            if let url = response.instantURL {
                answer += """
                <a class="answer-link" href="\(escape(url.absoluteString))">Read more</a>
                """
            }
            body += answer + "\n</div>"
        }

        body += "<div class=\"count\">About \(response.results.count) results</div>"
        for result in response.results {
            let snippet = result.snippet.isEmpty ? "" : "<div class=\"rsnip\">\(escape(result.snippet))</div>"
            body += """
            <div class="result">
              <div class="crumb">\(escape(breadcrumb(for: result.url)))</div>
              <a class="rtitle" href="\(escape(result.url.absoluteString))">\(escape(result.title))</a>
              \(snippet)
            </div>
            """
        }

        if hasMore {
            let nextOffset = offset + max(response.results.count, 1)
            body += """
            <div class="pager"><a href="\(escape(searchURL(query: query, offset: nextOffset, tab: "web")))">Search for more »</a></div>
            """
        } else if !response.results.isEmpty {
            body += "<div class=\"pager-end\">You've reached the end of the results.</div>"
        } else if offset == 0 {
            body += "<div class=\"pager-end\">No results yet. Try different words.</div>"
        } else {
            body += "<div class=\"pager-end\">No more results.</div>"
        }

        return pageShell(query: query, tab: "web", body: body)
    }

    /// The Images tab: a thumbnail grid; each tile opens the image's
    /// source page. "Search for more images" pages 10 at a time.
    static func imagesPage(query: String, images: [FocusSearchImage], offset: Int, hasMore: Bool) -> String {
        var body = ""
        if images.isEmpty {
            body += "<div class=\"status\">No image results yet. Try different words.</div>"
        } else {
            body += "<div class=\"count\">About \(images.count) images · SafeSearch off</div>"
            body += "<div class=\"img-grid\">"
            for image in images {
                let target = image.sourceURL?.absoluteString ?? image.imageURL.absoluteString
                body += """
                <a class="img-cell" href="\(escape(target))"><img src="\(escape(image.thumbnailURL.absoluteString))" alt="\(escape(image.title))" loading="lazy"></a>
                """
            }
            body += "</div>"
        }
        if hasMore {
            let nextOffset = offset + max(images.count, 1)
            body += """
            <div class="pager"><a href="\(escape(searchURL(query: query, offset: nextOffset, tab: "images")))">Search for more images »</a></div>
            """
        } else if !images.isEmpty {
            body += "<div class=\"pager-end\">You've reached the end of the image results.</div>"
        }
        return pageShell(query: query, tab: "images", body: body)
    }

    /// The link the page's search box, tabs and pagination navigate to.
    static func searchURL(query: String, offset: Int, tab: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "search"
        var items = [URLQueryItem(name: "q", value: query),
                     URLQueryItem(name: "tab", value: tab)]
        if offset > 0 { items.append(URLQueryItem(name: "offset", value: String(offset))) }
        components.queryItems = items
        return components.url?.absoluteString ?? ""
    }

    private static func pageShell(query: String, tab: String, body: String) -> String {
        let tabs = """
        <div class="tabs">
          <a class="tab\(tab == "web" ? " active" : "")" href="\(escape(searchURL(query: query, offset: 0, tab: "web")))">Web</a>
          <a class="tab\(tab == "images" ? " active" : "")" href="\(escape(searchURL(query: query, offset: 0, tab: "images")))">Images</a>
        </div>
        """
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(query)) - Focus Search</title>
        <style>
          body { margin: 0; padding: 0; background: #ffffff; color: #202124;
                 font-family: -apple-system, "Helvetica Neue", Arial, sans-serif; }
          .header { padding: 14px 16px 12px; border-bottom: 1px solid #ebebeb; }
          .logo { font-size: 26px; font-weight: 700; letter-spacing: -0.5px; }
          .logo .c1 { color: #4285F4; } .logo .c2 { color: #EA4335; }
          .logo .c3 { color: #FBBC05; } .logo .c4 { color: #34A853; }
          form { display: flex; margin-top: 10px; }
          input { flex: 1; font-size: 16px; padding: 10px 18px; color: #202124;
                  border: 1px solid #dfe1e5; border-radius: 24px; outline: none; }
          input:focus { border-color: #4285F4; }
          .content { padding: 4px 16px 8px; }
          .status { color: #70757a; font-size: 15px; text-align: center; padding: 40px 0; }
          .direct { display: block; margin: 14px 0 4px; padding: 12px 14px;
                    border: 1px solid #dfe1e5; border-radius: 10px; text-decoration: none; }
          .direct-title { display: block; color: #202124; font-weight: 600; font-size: 15px; }
          .direct-note { display: block; color: #70757a; font-size: 12px; margin-top: 3px; }
          .answer { background: #f8f9fa; border-radius: 10px; padding: 12px 14px; margin: 14px 0 4px; }
          .answer-title { color: #202124; font-size: 13px; font-weight: 600; margin-bottom: 5px; }
          .answer-text { color: #4d5156; font-size: 14px; line-height: 1.45; }
          .answer-link { display: inline-block; margin-top: 7px; color: #1a0dab; font-size: 13px; }
          .count { color: #70757a; font-size: 13px; margin: 14px 0 4px; }
          .result { margin: 0 0 20px; }
          .crumb { color: #006621; font-size: 13px; word-break: break-all; }
          .rtitle { display: block; color: #1a0dab; font-size: 18px; line-height: 1.3;
                    margin: 3px 0; text-decoration: none; }
          .rsnip { color: #4d5156; font-size: 14px; line-height: 1.45; }
          .pager { margin: 8px 0 12px; }
          .pager a { color: #1a0dab; font-size: 16px; font-weight: 600; text-decoration: none; }
          .pager-end { color: #70757a; font-size: 13px; margin: 8px 0 12px; }
          .tabs { display: flex; gap: 18px; margin-top: 12px; font-size: 14px; }
          .tab { color: #70757a; text-decoration: none; padding-bottom: 8px; }
          .tab.active { color: #1a0dab; font-weight: 600; border-bottom: 2px solid #1a0dab; }
          .img-grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; margin-top: 4px; }
          .img-cell img { width: 100%; height: 110px; object-fit: cover; border-radius: 6px;
                          display: block; background: #f1f3f4; }
          .content { padding-bottom: 28px; }
        </style>
        </head>
        <body>
        <div class="header">
          <div class="logo"><span class="c1">F</span><span class="c2">o</span><span class="c3">c</span><span class="c1">u</span><span class="c4">s</span></div>
          <form id="qform" onsubmit="return submitQuery(event)">
            <input id="qbox" type="text" value="\(escape(query))" autocomplete="off">
          </form>
          \(tabs)
        </div>
        <div class="content">
        \(body)
        </div>
        <script>
          function submitQuery(e) {
            e.preventDefault();
            var q = document.getElementById('qbox').value.trim();
            if (q) { window.location.href = '\(scheme)://search?q=' + encodeURIComponent(q); }
            return false;
          }
        </script>
        </body>
        </html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// "example.com › articles", the way engines show a result's source.
    private static func breadcrumb(for url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty {
            let firstSegment = path.split(separator: "/").first.map(String.init) ?? ""
            if !firstSegment.isEmpty { host += " › " + firstSegment }
        }
        return host
    }
}