# Focus Lite

A featherweight, privacy-first browser for iPhone, inspired by Firefox Focus — plus a
lightweight engine that runs **Chrome-style extensions**.

## What it does

- **Private by default** — every session runs in an ephemeral data store. Nothing is
  saved between sessions, and the big erase button wipes everything on demand.
- **Incognito mode** — a toggle (glasses button in the bar, or in Settings) that tints
  the interface, shows an "Incognito" pill, hides page content in the app switcher, and
  wipes the session whenever you turn it on or off.
- **Tabs** — browse in multiple tabs. On iPhone the squares button opens a tab
  grid (open, switch, close, close all); on iPad the sidebar lists them. All
  tabs share one ephemeral data store, and erasing or toggling incognito drops
  them all.
- **iPad layout** — on iPad the browser switches to a large-screen layout: a
  tab sidebar beside the page, with the controls in a toolbar above the content.
- **Tracker blocking** — a WebKit content rule list blocks requests to ~35 well-known
  advertising and analytics domains. The shield in the address bar shows how many
  tracking resources a page attempted to load.
- **Browser logs** — Settings shows the latest 100 navigation and session events in
  memory only, without URL paths, search terms, or page content.
- **Runs Chrome-style extensions** — drop any folder with a Chrome `manifest.json`
  into the app's `Extensions` folder and it loads. Two sample extensions are bundled
  and enabled on first launch.

## Extension support

The engine implements a practical subset of the WebExtensions API:

| Manifest keys | Support |
| --- | --- |
| `content_scripts` (`matches`, `js`, `run_at`) | Content scripts are injected into the page's isolated world, with Chrome match-pattern globbing |
| `content_scripts.css` | Firefox-style CSS content scripts are injected as style elements behind the same match-pattern guard |
| `background` (`scripts`, `service_worker`, `page`) | Background scripts run in a hidden offscreen page and receive runtime messages |
| `browser.storage.local` / `chrome.storage.local` | Fully bridged, namespaced per extension |
| `browser.storage.sync` | Aliased to the same namespaced store — Focus Lite keeps everything on device |
| `browser.runtime.sendMessage` / `onMessage` | Bridged between content scripts and background scripts, with async `sendResponse` |
| `browser.*` and `chrome.*` namespaces | Both work inside extension scripts |

Content scripts and background scripts run in separate, isolated JavaScript worlds, so
extensions can't see each other or the page's own JavaScript — the same isolation model
Chrome uses.

**Lua extensions:** a manifest may list `.lua` files under `js` exactly where it would
list JavaScript files. They run on an embedded Lua 5.3 VM ([fengari](https://github.com/fengari-lua/fengari))
and get a global `focus` table with `focus.log(...)`, `focus.storage.get(key, callback)` /
`focus.storage.set(table, callback)`, `focus.sendMessage(message, reply)`, and
`focus.onMessage(function (message, sendResponse) ... end)`. The globals `browser` and
`chrome` are aliases of the same table. A Lua sample ("Lua Greeter") is bundled on
first launch.

**Adding an extension:** put a folder in `Files → Focus Lite → Extensions` containing a
`manifest.json` (MV2 or MV3, Chrome or Firefox — Firefox `browser.*` scripts, CSS
content scripts and `storage.sync` included) plus its scripts, then tap *Rescan extensions folder* in
Settings. Toggles apply from the next page load.

**Not (yet) supported:** `chrome.tabs`, `chrome.declarativeNetRequest`, popup UI,
options pages, and other privileged APIs beyond the table above.

## Building

Open the project in Xcode and run, or use the Run button in the app this chat lives in.
Targets iOS 17+; no third-party dependencies.

**CI:** the *Build IPA* workflow on the Actions tab builds a Release archive, uploads
an unsigned `FocusLite.ipa` artifact on every push to `main` (and on demand via
*Run workflow*), and attaches it to a GitHub Release tagged after the app's version
(e.g. `v1.1`). Pushes to the `preview` branch build the same IPA as an
*FocusLite-ipa-preview* artifact attached to a separate `v<version>-preview`
pre-release. Re-sign it with your own certificate to install on a device.

## License

MIT — see [LICENSE](LICENSE).