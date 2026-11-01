//
//  LuaBridge.swift
//  Focus Lite
//

import Foundation

/// Embeds a real Lua 5.3 VM (fengari — a Lua VM written in pure JavaScript,
/// https://github.com/fengari-lua/fengari) into the page's JavaScript world,
/// so extension scripts written in `.lua` files run against the same
/// WebExtensions bridge that JavaScript extensions use.
///
/// Two pieces ship here:
/// - `preloadScript`: the fengari browser bundle plus a shim that exposes a
///   `focus` table (`focus.log`, `focus.storage`, `focus.sendMessage`,
///   `focus.onMessage`) to every Lua chunk.
/// - `luaBootstrap`: wraps a `.lua` file's source in a one-line JS bootstrap;
///   the normal `wrapped()` path then treats it like any other extension
///   script, match-pattern guards included.
enum LuaBridge {
    /// Marker that tells hosts which sources are Lua bootstraps, so the Lua
    /// runtime is only preloaded when a Lua extension is actually enabled.
    static let luaBootstrapMarker = "__focusLuaRun("

    /// Wraps a Lua source file in the JavaScript bootstrap the injected Lua
    /// runtime expects. The source travels as a JSON-encoded string literal,
    /// so any Lua syntax survives the ride into JS.
    static func luaBootstrap(source: String, name: String, extId: String) -> String {
        "__focusLuaRun(\(stringLiteral(source)), \(stringLiteral(name)), \(stringLiteral(extId)));"
    }

    private static func stringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    /// fengari plus the `focus` shim, injected once per JavaScript world
    /// (page world and background host world alike); guarded so re-injection
    /// after a rescan is a no-op.
    static var preloadScript: String {
        guard let url = Bundle.main.url(forResource: "fengari-web", withExtension: "js"),
              let bundle = try? String(contentsOf: url, encoding: .utf8) else {
            return "console.warn('[Focus Lite] Lua runtime bundle is missing');"
        }
        return bundle + "\n;\n" + shim
    }

    private static let shim = #"""
(function () {
  if (window.__focusLuaReady) return;
  window.__focusLuaReady = true;
  var F = window.fengari;
  if (!F) { console.error("[Focus Lite] Lua runtime did not load"); return; }
  var lua = F.lua, lauxlib = F.lauxlib, lualib = F.lualib;
  var to_luastring = F.to_luastring;
  window.__focusLuaStates = [];

  // Converts the Lua value at stack index idx into a plain JS value
  // (tables become objects; only JSON-shaped data round-trips).
  function luaToJs(L, idx) {
    var abs = lua.lua_absindex(L, idx);
    switch (lua.lua_type(L, abs)) {
      case lua.LUA_TNIL: return null;
      case lua.LUA_TBOOLEAN: return lua.lua_toboolean(L, abs) == true;
      case lua.LUA_TNUMBER: return lua.lua_tonumber(L, abs);
      case lua.LUA_TSTRING: return lua.lua_tojsstring(L, abs);
      case lua.LUA_TTABLE: {
        var out = {};
        lua.lua_pushnil(L);
        while (lua.lua_next(L, abs) !== 0) {
          var key = luaToJs(L, abs + 1);
          var val = luaToJs(L, abs + 2);
          lua.lua_pop(L, 1);
          if (typeof key === "string" || typeof key === "number") out[key] = val;
        }
        return out;
      }
      default: return null;
    }
  }

  // Pushes a plain JS value onto the Lua stack as an equivalent Lua value.
  function jsToLua(L, v) {
    if (v === null || v === undefined) { lua.lua_pushnil(L); return; }
    var t = typeof v;
    if (t === "string") { lua.lua_pushliteral(L, v); return; }
    if (t === "number") { lua.lua_pushnumber(L, v); return; }
    if (t === "boolean") { lua.lua_pushboolean(L, v ? 1 : 0); return; }
    if (Array.isArray(v)) {
      lua.lua_createtable(L, v.length, 0);
      for (var i = 0; i < v.length; i++) {
        jsToLua(L, v[i]);
        lua.lua_rawseti(L, -2, i + 1);
      }
      return;
    }
    if (t === "object") {
      var keys = Object.keys(v);
      lua.lua_createtable(L, 0, keys.length);
      for (var k = 0; k < keys.length; k++) {
        lua.lua_pushliteral(L, keys[k]);
        jsToLua(L, v[keys[k]]);
        lua.lua_rawset(L, -3);
      }
      return;
    }
    lua.lua_pushnil(L);
  }

  // pcall wrapper that reports errors on the console instead of crashing.
  function pcall(L, argc, label) {
    if (lua.lua_pcall(L, argc, 0, 0) !== lua.LUA_OK) {
      var err = lua.lua_tojsstring(L, -1) || "(lua error)";
      lua.lua_pop(L, 1);
      console.error("[Focus Lite] Lua " + label + ": " + err);
    }
  }

  // Storage helpers share one shape: call the JS API, then hand the reply
  // to the Lua callback the script passed in (a proxy keeps it callable later).
  function addStorageFn(L, api, name, label) {
    lua.lua_pushliteral(L, name);
    lua.lua_pushjsfunction(L, function (L2) {
      var arg1 = lua.lua_type(L2, 1) === lua.LUA_TNIL ? null : luaToJs(L2, 1);
      var cb = lua.lua_type(L2, 2) === lua.LUA_TFUNCTION ? lua.lua_toproxy(L2, 2) : null;
      var call;
      if (label === "storage.get") call = api.storage.local.get(arg1);
      else if (label === "storage.set") call = api.storage.local.set(arg1 || {});
      else if (label === "storage.remove") call = api.storage.local.remove(arg1);
      else call = api.storage.local.clear();
      call.then(function (reply) {
        if (cb) {
          cb(L2);
          jsToLua(L2, reply);
          pcall(L2, 1, label + " callback");
        }
      });
      return 0;
    });
    lua.lua_settable(L, -3);
  }

  function installFocusAPI(L, extId) {
    var api = window.__focusExtAPI(extId);
    lua.lua_createtable(L, 0, 4);

    // focus.log(...)
    lua.lua_pushliteral(L, "log");
    lua.lua_pushjsfunction(L, function (L2) {
      var parts = [];
      for (var i = 1; i <= lua.lua_gettop(L2); i++) {
        var t = lua.lua_type(L2, i);
        if (t === lua.LUA_TSTRING) parts.push(lua.lua_tojsstring(L2, i));
        else if (t === lua.LUA_TNIL) parts.push("nil");
        else { try { parts.push(JSON.stringify(luaToJs(L2, i))); } catch (e) { parts.push("?"); } }
      }
      console.log("[Focus Lite: " + extId + "]", parts.join(" "));
      return 0;
    });
    lua.lua_settable(L, -3);

    // focus.storage = { get, set, remove, clear }
    lua.lua_pushliteral(L, "storage");
    lua.lua_createtable(L, 0, 4);
    addStorageFn(L, api, "get", "storage.get");
    addStorageFn(L, api, "set", "storage.set");
    addStorageFn(L, api, "remove", "storage.remove");
    addStorageFn(L, api, "clear", "storage.clear");
    lua.lua_settable(L, -3);

    // focus.sendMessage(message, reply)
    lua.lua_pushliteral(L, "sendMessage");
    lua.lua_pushjsfunction(L, function (L2) {
      var msg = luaToJs(L2, 1);
      var cb = lua.lua_type(L2, 2) === lua.LUA_TFUNCTION ? lua.lua_toproxy(L2, 2) : null;
      api.runtime.sendMessage(msg).then(function (reply) {
        if (cb) {
          cb(L2);
          jsToLua(L2, reply);
          pcall(L2, 1, "sendMessage callback");
        }
      }).catch(function () {
        if (cb) {
          cb(L2);
          jsToLua(L2, null);
          pcall(L2, 1, "sendMessage callback");
        }
      });
      return 0;
    });
    lua.lua_settable(L, -3);

    // focus.onMessage(fn) — fn(message, sendResponse)
    lua.lua_pushliteral(L, "onMessage");
    lua.lua_pushjsfunction(L, function (L2) {
      if (lua.lua_type(L2, 1) !== lua.LUA_TFUNCTION) return 0;
      var fn = lua.lua_toproxy(L2, 1);
      api.runtime.onMessage.addListener(function (message, sender, sendResponse) {
        var responded = false;
        fn(L2);
        jsToLua(L2, message);
        lua.lua_pushjsfunction(L2, function (CL) {
          var reply = luaToJs(CL, 1);
          if (!responded) {
            responded = true;
            try { sendResponse(reply); } catch (e) {}
          }
          return 0;
        });
        pcall(L2, 2, "onMessage handler");
      });
      return 0;
    });
    lua.lua_settable(L, -3);

    // Expose the same table as focus, browser and chrome globals, so Lua
    // authors can use whichever name feels natural.
    lua.lua_pushvalue(L, -1);
    lua.lua_setglobal(L, to_luastring("focus"));
    lua.lua_pushvalue(L, -1);
    lua.lua_setglobal(L, to_luastring("browser"));
    lua.lua_pushvalue(L, -1);
    lua.lua_setglobal(L, to_luastring("chrome"));
    lua.lua_pop(L, 1);
  }

  // Runs one Lua source as a fresh, isolated Lua state. The focus API for
  // the owning extension is installed before the script body executes, and
  // the state is retained for as long as the page lives so callbacks
  // registered during the run keep working.
  window.__focusLuaRun = function (source, name, extId) {
    var L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    window.__focusLuaStates.push(L);
    installFocusAPI(L, String(extId || "extension"));
    var status = lauxlib.luaL_loadstring(L, to_luastring(String(source)));
    if (status !== lua.LUA_OK) {
      var err = lua.lua_tojsstring(L, -1) || "(load error)";
      lua.lua_pop(L, 1);
      console.error("[Focus Lite] Lua error in " + name + ": " + err);
      return;
    }
    pcall(L, 0, "in " + name);
  };
})();
"""#
}
