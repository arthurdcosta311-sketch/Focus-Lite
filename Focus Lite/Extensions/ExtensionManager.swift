//
//  ExtensionManager.swift
//  Focus Lite
//

import Foundation

struct BrowserExtension: Identifiable {
    struct ContentScriptSpec {
        let matches: [String]
        let scripts: [String]
        let cssSources: [String]
        let runAtDocumentStart: Bool
    }

    let id: String
    let name: String
    let version: String
    let descriptionText: String
    let contentScripts: [ContentScriptSpec]
    let backgroundScripts: [String]
}

final class ExtensionManager: ObservableObject {
    static let shared = ExtensionManager()

    @Published private(set) var extensions: [BrowserExtension] = []

    private(set) var extensionsDirectory: URL
    private let enabledKey = "focus.extensions.enabled"

    var enabledIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: enabledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: enabledKey) }
    }

    func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    func setEnabled(_ id: String, _ enabled: Bool) {
        var ids = enabledIDs
        if enabled { ids.insert(id) } else { ids.remove(id) }
        enabledIDs = ids
    }

    /// True when any enabled extension ships a Lua script, so the hosts know
    /// to preload the Lua runtime before the extension scripts.
    var usesLua: Bool {
        let marker = LuaBridge.luaBootstrapMarker
        return extensions.contains { ext in
            guard isEnabled(ext.id) else { return false }
            if ext.backgroundScripts.contains(where: { $0.hasPrefix(marker) }) { return true }
            return ext.contentScripts.contains { $0.scripts.contains { $0.hasPrefix(marker) } }
        }
    }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        extensionsDirectory = documents.appendingPathComponent("Extensions", isDirectory: true)
        materializeSamplesIfNeeded()
        reload()
    }

    func reload() {
        var found: [BrowserExtension] = []
        let fileManager = FileManager.default
        if let entries = try? fileManager.contentsOfDirectory(
            at: extensionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if let extensionModel = Self.load(from: entry) {
                    found.append(extensionModel)
                }
            }
        }
        extensions = found
    }

    // MARK: - Manifest parsing (Chrome MV2 / MV3 subset)

    private static func load(from folder: URL) -> BrowserExtension? {
        let manifestURL = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let name = manifest["name"] as? String ?? folder.lastPathComponent
        let version = manifest["version"] as? String ?? "1.0"
        let descriptionText = manifest["description"] as? String ?? ""

        var contentScripts: [BrowserExtension.ContentScriptSpec] = []
        if let entries = manifest["content_scripts"] as? [[String: Any]] {
            for entry in entries {
                let matches = entry["matches"] as? [String] ?? ["<all_urls>"]
                let files = entry["js"] as? [String] ?? []
                let sources = files.compactMap { Self.scriptSource($0, in: folder, extId: folder.lastPathComponent) }
                // Firefox-style CSS content scripts are welcome too; they are
                // injected as style elements behind the same match guard.
                let cssFiles = entry["css"] as? [String] ?? []
                let css = cssFiles.compactMap { Self.fileContents($0, in: folder) }
                guard !sources.isEmpty || !css.isEmpty else { continue }
                let runAt = entry["run_at"] as? String
                contentScripts.append(BrowserExtension.ContentScriptSpec(
                    matches: matches,
                    scripts: sources,
                    cssSources: css,
                    runAtDocumentStart: runAt == "document_start"
                ))
            }
        }

        var backgroundScripts: [String] = []
        if let background = manifest["background"] as? [String: Any] {
            var files: [String] = []
            if let scripts = background["scripts"] as? [String] {
                files = scripts
            } else if let worker = background["service_worker"] as? String {
                files = [worker]
            } else if let page = background["page"] as? String {
                files = [page]
            }
            backgroundScripts = files.compactMap { Self.scriptSource($0, in: folder, extId: folder.lastPathComponent) }
        } else if let single = manifest["background"] as? String {
            backgroundScripts = [single].compactMap { Self.fileContents($0, in: folder) }
        }

        return BrowserExtension(
            id: folder.lastPathComponent,
            name: name,
            version: version,
            descriptionText: descriptionText,
            contentScripts: contentScripts,
            backgroundScripts: backgroundScripts
        )
    }

    private static func fileContents(_ name: String, in folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns a script's source, wrapping `.lua` files in the JavaScript
    /// bootstrap that runs them on the embedded Lua VM. JavaScript files pass
    /// through untouched.
    private static func scriptSource(_ name: String, in folder: URL, extId: String) -> String? {
        guard let contents = fileContents(name, in: folder) else { return nil }
        guard name.hasSuffix(".lua") else { return contents }
        return LuaBridge.luaBootstrap(source: contents, name: name, extId: extId)
    }

    // MARK: - Match patterns (host/path glob subset of Chrome match patterns)

    static func matchRegexes(for patterns: [String]) -> [String] {
        patterns.compactMap { patternRegex($0)?.pattern }
    }

    private static func patternRegex(_ pattern: String) -> NSRegularExpression? {
        guard pattern != "<all_urls>" else { return nil }

        var schemePattern = "https?"
        var remainder = pattern
        if let separator = pattern.range(of: "://") {
            schemePattern = String(pattern[pattern.startIndex..<separator.lowerBound])
            remainder = String(pattern[separator.upperBound...])
            if schemePattern == "*" { schemePattern = "[a-z][a-z0-9+.-]*" }
        }

        let parts = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let hostPart = parts.first.map(String.init) ?? "*"
        let pathPart = parts.count > 1 ? "/" + parts[1] : "/"

        var regex = "^" + schemePattern + "://"
        if hostPart.hasPrefix("*.") {
            regex += "([^/]+\\.)?" + NSRegularExpression.escapedPattern(for: String(hostPart.dropFirst(2)))
        } else if hostPart == "*" {
            regex += "[^/]*"
        } else {
            regex += NSRegularExpression.escapedPattern(for: hostPart)
        }

        let pathRegex = pathPart.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*")
        regex += pathRegex + "$"

        return try? NSRegularExpression(pattern: regex)
    }

    // MARK: - Bundled sample extensions

    private func materializeSamplesIfNeeded() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: extensionsDirectory, withIntermediateDirectories: true)
        let existing = (try? fileManager.contentsOfDirectory(atPath: extensionsDirectory.path)) ?? []
        let isFirstLaunch = existing.isEmpty

        // Materialize per folder, so samples added in later versions reach
        // installs that already have the older ones.
        var newlyAdded: [String] = []
        for sample in BundledSamples.all {
            let folder = extensionsDirectory.appendingPathComponent(sample.folder, isDirectory: true)
            guard !fileManager.fileExists(atPath: folder.path) else { continue }
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try? sample.manifest.write(
                to: folder.appendingPathComponent("manifest.json"),
                atomically: true, encoding: .utf8
            )
            for file in sample.files {
                try? file.source.write(
                    to: folder.appendingPathComponent(file.name),
                    atomically: true, encoding: .utf8
                )
            }
            newlyAdded.append(sample.folder)
        }
        guard !newlyAdded.isEmpty else { return }
        if isFirstLaunch {
            enabledIDs = Set(BundledSamples.all.map { $0.folder })
        } else {
            // Only newly added samples turn on, so toggles users flipped
            // keep their state.
            enabledIDs = enabledIDs.union(newlyAdded)
        }
    }
}

private enum BundledSamples {
    struct Sample {
        let folder: String
        let manifest: String
        let files: [(name: String, source: String)]
    }

    static var all: [Sample] { [pageCleaner, helloResponder, readingTime, luaGreeter] }

    static let pageCleaner = Sample(
        folder: "focus-page-cleaner",
        manifest: #"""
{
  "manifest_version": 3,
  "name": "Focus Page Cleaner",
  "version": "1.0.0",
  "description": "Hides cookie banners, newsletter popups and paywall overlays so pages stay readable.",
  "content_scripts": [
    { "matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_end" }
  ]
}
"""#,
        files: [
            ("content.js", #"""
(function () {
  browser.storage.local.get(["cleanerEnabled"]).then(function (items) {
    if (items.cleanerEnabled === false) return;
    var selectors = [
      "[class*='cookie'][class*='banner']",
      "[id*='cookie'][class*='consent']",
      "[class*='newsletter'][class*='modal']",
      "[class*='paywall'][class*='overlay']",
      "div[class*='overlay'][style*='position: fixed']"
    ];
    var style = document.createElement("style");
    style.setAttribute("data-focus-ext", "focus-page-cleaner");
    style.textContent = selectors.join(",") + " { display: none !important; } html, body { overflow: auto !important; }";
    document.documentElement.appendChild(style);
  });
})();
"""#)
        ]
    )

    static let helloResponder = Sample(
        folder: "focus-hello-responder",
        manifest: #"""
{
  "manifest_version": 3,
  "name": "Hello Responder",
  "version": "1.0.0",
  "description": "Demonstrates the runtime bridge: a background script answers messages from its content script.",
  "content_scripts": [
    { "matches": ["<all_urls>"], "js": ["content.js"], "run_at": "document_idle" }
  ],
  "background": { "service_worker": "background.js" }
}
"""#,
        files: [
            ("content.js", #"""
(function () {
  chrome.runtime.sendMessage({ type: "focus:hello", url: location.href }).then(function (reply) {
    console.log("[Focus Lite] background says:", reply && reply.summary);
  }).catch(function () {});
})();
"""#),
            ("background.js", #"""
chrome.runtime.onMessage.addListener(function (message, sender, sendResponse) {
  if (message && message.type === "focus:hello") {
    sendResponse({ summary: "Heard " + message.url + " — the extension bridge works." });
  }
});
"""#)
        ]
    )

    /// Lightweight by design: one content script, no permissions, no
    /// background page, no storage. The same manifest and script load
    /// unchanged in Chrome and Firefox.
    static let readingTime = Sample(
        folder: "focus-reading-time",
        manifest: #"""
{
  "manifest_version": 3,
  "name": "Reading Time",
  "version": "1.0.0",
  "description": "Adds an estimated reading time above articles. Cross-browser by design: one tiny content script, no permissions, no background page.",
  "content_scripts": [
    { "matches": ["https://*/*", "http://*/*"], "js": ["content.js"], "run_at": "document_idle" }
  ]
}
"""#,
        files: [
            ("content.js", #"""
(function () {
  var article = document.querySelector("article, main, [role='main']");
  if (!article) return;
  var words = (article.innerText || "").trim().split(/\s+/).filter(String).length;
  if (words < 120) return;
  var minutes = Math.max(1, Math.round(words / 220));
  var badge = document.createElement("div");
  badge.setAttribute("data-focus-ext", "focus-reading-time");
  badge.textContent = minutes + " min read";
  badge.style.cssText = "margin:0 0 12px;font:600 13px -apple-system,sans-serif;color:#6b7280;";
  if (article.firstElementChild) {
    article.insertBefore(badge, article.firstElementChild);
  } else {
    article.appendChild(badge);
  }
})();
"""#)
        ]
    )

    /// Demonstrates the Lua scripting language: a background script and a
    /// content script, both written in `.lua`, running on the embedded Lua VM
    /// and talking over the same runtime bridge the JS samples use.
    static let luaGreeter = Sample(
        folder: "focus-lua-greeter",
        manifest: #"""
{
  "manifest_version": 3,
  "name": "Lua Greeter",
  "version": "1.0.0",
  "description": "Background and content scripts written in Lua: they run on the embedded Lua VM and greet over the runtime bridge.",
  "content_scripts": [
    { "matches": ["<all_urls>"], "js": ["content.lua"], "run_at": "document_idle" }
  ],
  "background": { "scripts": ["background.lua"] }
}
"""#,
        files: [
            ("background.lua", #"""
-- A background script written in Lua.
-- The global `focus` table is Focus Lite's Lua API.

focus.onMessage(function (message, sendResponse)
  if message and message.type == "focus:hello" then
    sendResponse({ summary = "Hello from Lua! Page said: " .. tostring(message.url) })
  end
end)

focus.log("Lua Greeter background script loaded")
"""#),
            ("content.lua", #"""
-- A Lua content script: greets the Lua background script.

focus.sendMessage({ type = "focus:hello", url = "a Lua content script" }, function (reply)
  focus.log(reply and reply.summary or "no reply from the Lua background")
end)
"""#)
        ]
    )
}