//
//  TrackerBlocker.swift
//  Focus Lite
//

import WebKit

enum TrackerBlocker {
    static let blockedTrackers: [String] = [
        "doubleclick.net", "googlesyndication.com", "google-analytics.com", "googletagmanager.com",
        "adservice.google.com", "connect.facebook.net", "facebook.net", "scorecardresearch.com",
        "quantserve.com", "hotjar.com", "mixpanel.com", "segment.io", "segment.com", "amplitude.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "adnxs.com", "adsrvr.org",
        "pubmatic.com", "rubiconproject.com", "casalemedia.com", "openx.net", "bidswitch.net",
        "smartadserver.com", "amazon-adsystem.com", "appsflyer.com", "branch.io", "kochava.com",
        "chartboost.com", "inmobi.com", "mopub.com", "moatads.com", "yieldmo.com"
    ]

    private static let ruleListIdentifier = "focus.blockers.v1"
    private static var cachedRuleList: WKContentRuleList?
    private static var pendingControllers: [WKUserContentController] = []
    private static var isPreparingRuleList = false

    /// WebKit content-rule JSON that blocks every known tracker domain.
    static var rulesJSON: String {
        let rules = blockedTrackers.map { domain in
            "{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*.\(domain)\"]},\"action\":{\"type\":\"block\"}}"
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    static func install(into controller: WKUserContentController) {
        if let cachedRuleList {
            controller.add(cachedRuleList)
            return
        }

        pendingControllers.append(controller)
        guard !isPreparingRuleList else { return }
        isPreparingRuleList = true

        guard let store = WKContentRuleListStore.default() else {
            finishPreparing(nil)
            return
        }
        store.lookUpContentRuleList(forIdentifier: ruleListIdentifier) { ruleList, _ in
            if let ruleList {
                finishPreparing(ruleList)
                return
            }
            store.compileContentRuleList(
                forIdentifier: ruleListIdentifier,
                encodedContentRuleList: rulesJSON
            ) { compiledList, error in
                if let error {
                    print("[Focus Lite] rule list compile failed: \(error.localizedDescription)")
                }
                finishPreparing(compiledList)
            }
        }
    }

    private static func finishPreparing(_ ruleList: WKContentRuleList?) {
        DispatchQueue.main.async {
            if let ruleList {
                cachedRuleList = ruleList
                pendingControllers.forEach { $0.add(ruleList) }
            }
            pendingControllers.removeAll()
            isPreparingRuleList = false
        }
    }

    /// Counts tracking resources seen on the current page (the engine blocks
    /// the request itself; this audit reports what the page attempted).
    static var auditScript: String {
        let serializedTrackers = blockedTrackers.map { "\"\($0)\"" }.joined(separator: ",")
        return #"""
(function () {
  var trackers = [\#(serializedTrackers)];
  var seen = {};
  function check(url) {
    if (!url) return;
    for (var i = 0; i < trackers.length; i++) { if (url.indexOf(trackers[i]) !== -1) { seen[trackers[i]] = 1; } }
  }
  try { performance.getEntriesByType("resource").forEach(function (e) { check(e.name); }); } catch (e) {}
  try {
    var nodes = document.querySelectorAll("script[src],img[src],iframe[src],link[href]");
    for (var j = 0; j < nodes.length; j++) { check(nodes[j].src || nodes[j].href); }
  } catch (e) {}
  return Object.keys(seen).length;
})()
"""#
    }
}
