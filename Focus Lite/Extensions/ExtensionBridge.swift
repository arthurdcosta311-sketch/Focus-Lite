//
//  ExtensionBridge.swift
//  Focus Lite
//

import Foundation
import WebKit

/// Bridges a lightweight `browser` / `chrome` WebExtensions API between
/// content scripts (page world), the app, and per-extension background scripts.
final class ExtensionBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "__focusExt"

    weak var pageWebView: WKWebView?
    weak var backgroundWebView: WKWebView?

    /// token -> waiting page request
    private var pendingRuntime: [String: (pageWebView: WKWebView, extId: String, ticket: String)] = [:]

    // MARK: - Injected JavaScript

    /// One-time factory that hands every extension script its own API instance.
    static let factoryScript = #"""
(function () {
  if (window.__focusExtAPI) return;
  var store = (window.__focusExtStore = { instances: {} });
  function send(extId, msg) {
    msg.ext = extId;
    try { window.webkit.messageHandlers.__focusExt.postMessage(msg); } catch (e) {}
  }
  window.__focusExtAPI = function (extId) {
    var inst = store.instances[extId];
    if (inst) return inst.api;
    var pending = {};
    var listeners = [];
    var seq = 0;
    var api = {
      runtime: {
        id: extId,
        sendMessage: function (message) {
          return new Promise(function (resolve, reject) {
            var t = extId + ":" + (++seq);
            pending[t] = { resolve: resolve, reject: reject };
            send(extId, { kind: "runtime", ticket: t, message: message === undefined ? null : message });
            setTimeout(function () {
              if (pending[t]) { delete pending[t]; reject(new Error("No receiver")); }
            }, 8000);
          });
        },
        onMessage: { addListener: function (fn) { listeners.push(fn); } }
      },
      storage: {
        local: {
          get: function (keys) {
            return new Promise(function (resolve) {
              var t = extId + ":" + (++seq);
              pending[t] = { resolve: resolve };
              send(extId, { kind: "storage.get", ticket: t, keys: keys === undefined ? null : keys });
            });
          },
          set: function (items) {
            return new Promise(function (resolve) {
              var t = extId + ":" + (++seq);
              pending[t] = { resolve: resolve };
              send(extId, { kind: "storage.set", ticket: t, items: items || {} });
            });
          },
          remove: function (keys) {
            return new Promise(function (resolve) {
              var t = extId + ":" + (++seq);
              pending[t] = { resolve: resolve };
              send(extId, { kind: "storage.remove", ticket: t, keys: keys === undefined ? null : keys });
            });
          },
          clear: function () {
            return new Promise(function (resolve) {
              var t = extId + ":" + (++seq);
              pending[t] = { resolve: resolve };
              send(extId, { kind: "storage.clear", ticket: t });
            });
          }
        }
      }
    };
    inst = { api: api, pending: pending, listeners: listeners };
    store.instances[extId] = inst;
    return api;
  };
  window.__focusExtDispatch = function (envelope) {
    var inst = store.instances[envelope.ext];
    if (!inst) return;
    if (envelope.reply !== undefined || envelope.error) {
      var entry = inst.pending[envelope.ticket];
      if (entry) {
        delete inst.pending[envelope.ticket];
        if (envelope.error) { if (entry.reject) entry.reject(new Error(envelope.error)); }
        else { entry.resolve(envelope.reply); }
      }
      return;
    }
    var sendResponse = null;
    if (envelope.replyToken) {
      sendResponse = function (response) {
        send(envelope.ext, { kind: "runtime.reply", token: envelope.replyToken, message: response === undefined ? null : response });
      };
    }
    inst.listeners.slice().forEach(function (fn) {
      try { fn(envelope.message, { id: envelope.ext }, sendResponse); } catch (e) {}
    });
  };
})();
"""#

    /// Wraps an extension script: isolated API instance plus match-pattern guard.
    static func wrapped(source: String, extId: String, patterns: [String]) -> String {
        let safeId = extId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let regexes = ExtensionManager.matchRegexes(for: patterns)
        let patternsJSON = (try? String(data: JSONSerialization.data(withJSONObject: regexes), encoding: .utf8)) ?? "[]"
        let guardCode = regexes.isEmpty ? "" :
            "var __ok = __patterns.some(function (r) { try { return new RegExp(r).test(location.href); } catch (e) { return false; } });\nif (!__ok) return;\n"
        return "(function(){\n"
            + "var browser = window.__focusExtAPI(\"\(safeId)\");\n"
            + "var chrome = browser;\n"
            + "var __patterns = \(patternsJSON);\n"
            + guardCode
            + source
            + "\n})();"
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let ext = body["ext"] as? String,
              let kind = body["kind"] as? String,
              let ticket = body["ticket"] as? String else { return }
        let fromBackground = message.webView != nil && message.webView === backgroundWebView

        switch kind {
        case "storage.get":
            handleStorageGet(ext: ext, body: body, ticket: ticket, in: message.webView)
        case "storage.set":
            handleStorageSet(ext: ext, body: body, ticket: ticket, in: message.webView)
        case "storage.remove":
            handleStorageRemove(ext: ext, body: body, ticket: ticket, in: message.webView)
        case "storage.clear":
            UserDefaults.standard.removeObject(forKey: storageKey(ext))
            deliver(["ext": ext, "ticket": ticket, "reply": [String: Any]()], to: message.webView)
        case "runtime":
            guard !fromBackground else { return }
            forwardRuntime(ext: ext, body: body, ticket: ticket)
        case "runtime.reply":
            guard fromBackground,
                  let token = body["token"] as? String,
                  let entry = pendingRuntime.removeValue(forKey: token) else { return }
            deliver(["ext": entry.extId, "ticket": entry.ticket, "reply": body["message"] ?? NSNull()],
                    to: entry.pageWebView)
        default:
            break
        }
    }

    // MARK: - Runtime messaging

    private func forwardRuntime(ext: String, body: [String: Any], ticket: String) {
        guard let background = backgroundWebView else {
            deliver(["ext": ext, "ticket": ticket, "error": "This extension has no background script"], to: pageWebView)
            return
        }
        let token = UUID().uuidString
        if let page = pageWebView {
            pendingRuntime[token] = (page, ext, ticket)
        }
        deliver([
            "ext": ext,
            "message": body["message"] ?? NSNull(),
            "sender": ["id": ext],
            "replyToken": token
        ], to: background)
    }

    // MARK: - storage.local (namespaced per extension)

    private func storageKey(_ ext: String) -> String { "focus.ext.storage." + ext }

    private func loadStorage(_ ext: String) -> [String: Any] {
        guard let data = UserDefaults.standard.data(forKey: storageKey(ext)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func saveStorage(_ ext: String, _ storage: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: storage) {
            UserDefaults.standard.set(data, forKey: storageKey(ext))
        }
    }

    private func handleStorageGet(ext: String, body: [String: Any], ticket: String, in webView: WKWebView?) {
        let stored = loadStorage(ext)
        var result: [String: Any] = [:]
        if let keys = body["keys"] as? [String] {
            for key in keys where stored[key] != nil { result[key] = stored[key] }
        } else if let key = body["keys"] as? String, let value = stored[key] {
            result[key] = value
        } else {
            result = stored
        }
        deliver(["ext": ext, "ticket": ticket, "reply": result], to: webView)
    }

    private func handleStorageSet(ext: String, body: [String: Any], ticket: String, in webView: WKWebView?) {
        var stored = loadStorage(ext)
        if let items = body["items"] as? [String: Any] {
            for (key, value) in items { stored[key] = value }
        }
        saveStorage(ext, stored)
        deliver(["ext": ext, "ticket": ticket, "reply": [String: Any]()], to: webView)
    }

    private func handleStorageRemove(ext: String, body: [String: Any], ticket: String, in webView: WKWebView?) {
        var stored = loadStorage(ext)
        if let keys = body["keys"] as? [String] {
            for key in keys { stored.removeValue(forKey: key) }
        } else if let key = body["keys"] as? String {
            stored.removeValue(forKey: key)
        } else {
            stored.removeAll()
        }
        saveStorage(ext, stored)
        deliver(["ext": ext, "ticket": ticket, "reply": [String: Any]()], to: webView)
    }

    // MARK: - Delivery

    private func deliver(_ envelope: [String: Any], to webView: WKWebView?) {
        guard let webView,
              JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope),
              let json = String(data: data, encoding: .utf8) else { return }
        let base64 = Data(json.utf8).base64EncodedString()
        let js = "window.__focusExtDispatch(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('\(base64)'), function (c) { return c.charCodeAt(0); }))));"
        webView.evaluateJavaScript(js, in: nil, in: .page, completionHandler: nil)
    }
}