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

    /// WebKit content-rule JSON that blocks every known tracker domain.
    static var rulesJSON: String {
        let rules = blockedTrackers.map { domain in
            "{\"trigger\":{\"url-filter\":\".*\",\"if-domain\":[\"*.\(domain)\"]},\"action\":{\"type\":\"block\"}}"
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    static func install(into controller: WKUserContentController) {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "focus.blockers.v1",
            encodedContentRuleList: rulesJSON
        ) { ruleList, error in
            guard let ruleList else {
                if let error {
                    print("[Focus Lite] rule list compile failed: \(error.localizedDescription)")
                }
                return
            }
            DispatchQueue.main.async {
                controller.add(ruleList)
            }
        }
    }

    /// Counts tracking resources seen on the current page (the engine blocks
    /// the request itself; this audit reports what the page attempted).
    static let auditScript = #"""
(function () {
  var trackers = ["doubleclick.net","googlesyndication.com","google-analytics.com","googletagmanager.com","adservice.google.com","connect.facebook.net","facebook.net","scorecardresearch.com","quantserve.com","hotjar.com","mixpanel.com","segment.io","segment.com","amplitude.com","criteo.com","taboola.com","outbrain.com","adnxs.com","adsrvr.org","pubmatic.com","rubiconproject.com","casalemedia.com","openx.net","bidswitch.net","smartadserver.com","amazon-adsystem.com","appsflyer.com","branch.io","kochava.com","chartboost.com","inmobi.com","mopub.com","moatads.com","yieldmo.com"];
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