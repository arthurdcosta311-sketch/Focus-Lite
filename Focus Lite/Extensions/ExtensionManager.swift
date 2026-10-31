//
//  ExtensionManager.swift
//  Focus Lite
//

import Foundation

struct BrowserExtension: Identifiable {
    struct ContentScriptSpec {
        let matches: [String]
        let scripts: [String]
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
                let sources = files.compactMap { Self.fileContents($0, in: folder) }
                guard !sources.isEmpty else { continue }
                let runAt = entry["run_at"] as? String
                contentScripts.append(BrowserExtension.ContentScriptSpec(
                    matches: matches,
                    scripts: sources,
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
            backgroundScripts = files.compactMap { Self.fileContents($0, in: folder) }
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
        guard existing.isEmpty else { return }

        for sample in BundledSamples.all {
            let folder = extensionsDirectory.appendingPathComponent(sample.folder, isDirectory: true)
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
        }
        enabledIDs = Set(BundledSamples.all.map { $0.folder })
    }
}

private enum BundledSamples {
    struct Sample {
        let folder: String
        let manifest: String
        let files: [(name: String, source: String)]
    }

    static var all: [Sample] { [pageCleaner, helloResponder] }

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
}