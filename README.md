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
- **Runs Chrome-style extensions** — drop any folder with a Chrome `manifest.json`
  into the app's `Extensions` folder and it loads. Two sample extensions are bundled
  and enabled on first launch.

## Extension support

The engine implements a practical subset of the WebExtensions API:

| Manifest keys | Support |
| --- | --- |
| `content_scripts` (`matches`, `js`, `run_at`) | Content scripts are injected into the page's isolated world, with Chrome match-pattern globbing |
| `background` (`scripts`, `service_worker`, `page`) | Background scripts run in a hidden offscreen page and receive runtime messages |
| `browser.storage.local` / `chrome.storage.local` | Fully bridged, namespaced per extension |
| `browser.runtime.sendMessage` / `onMessage` | Bridged between content scripts and background scripts, with async `sendResponse` |
| `browser.*` and `chrome.*` namespaces | Both work inside extension scripts |

Content scripts and background scripts run in separate, isolated JavaScript worlds, so
extensions can't see each other or the page's own JavaScript — the same isolation model
Chrome uses.

**Adding an extension:** put a folder in `Files → Focus Lite → Extensions` containing a
`manifest.json` (MV2 or MV3) plus its scripts, then tap *Rescan extensions folder* in
Settings. Toggles apply from the next page load.

**Not (yet) supported:** `chrome.tabs`, `chrome.declarativeNetRequest`, popup UI,
options pages, and other privileged APIs beyond the table above.

## Building

Open the project in Xcode and run, or use the Run button in the app this chat lives in.
Targets iOS 17+; no third-party dependencies.

**CI:** the *Build IPA* workflow on the Actions tab builds a Release archive, uploads
an unsigned `FocusLite.ipa` artifact on every push to `main` (and on demand via
*Run workflow*), and attaches it to a GitHub Release tagged after the app's version
(e.g. `v1.1`). Re-sign it with your own certificate to install on a device.

## License

MIT — see [LICENSE](LICENSE).