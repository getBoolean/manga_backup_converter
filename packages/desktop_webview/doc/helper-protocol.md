# desktop_webview helper protocol (version 1)

`desktop_webview_helper` is a standalone executable (Rust, `wry` 0.57.3 / `tao` 0.37.3) that drives the platform WebView: WebView2 on Windows, WKWebView on macOS, WebKitGTK on Linux. It is a separate program because macOS needs the AppKit event loop on the process main thread, and the repository's cargo build hooks produce only dynamic-library code assets (KTD20). `DesktopBrowserPort` (`lib/src/desktop_browser_port.dart`) is its only client: one helper process per conversion and one helper session per source session.

## Transport

- **Frames:** UTF-8 JSON objects, one per line, on stdin (client → helper) and stdout (helper → client). Neither side accepts a frame larger than 16 MiB (KTD4). The client refuses to send an oversized request. An oversized or malformed frame on stdin makes the helper emit `protocolError` and exit.
- **Logs:** stderr only. Lines may contain URLs; the client passes them to `DesktopWebViewConfig.onLog`, which should be a redacting sink (KTD9).
- **Lifetime:** the helper exits when stdin closes, so a crashed or killed parent never leaves windows or WebViews behind.

## Arguments

| Argument | Meaning |
|---|---|
| `--data-root <dir>` | Parent of per-process data directories (`h-<pid>`). Stale `h-*` directories are removed at start-up before any session opens (KTD20 start-up wipe). Each is renamed first, so a directory a live helper's browser still holds is skipped rather than partly deleted. The helper tries to remove its own directory at exit, but WebView2's browser processes often outlive it; the next start-up wipe removes what is left. Only WebView2 uses it. |
| `--offline` | Replay mode. Every non-loopback request that no `respond` answers is blocked with a 502 (`X-Desktop-Webview-Blocked: 1`). On WebView2, interception covers all request source kinds, and `--host-resolver-rules` keeps every host except loopback from resolving, as a backstop for traffic interception misses (WebSockets). Engines that cannot block requests refuse to start (`fatal` `offline-unsupported`) instead of falling through to the network. |
| `--test-hooks` | Enables `debugRequestClose`. |
| `--simulate-fatal <code>` | Test hook: report `fatal` with this code at start-up. |
| `--version` | Prints the helper and protocol versions. |

## Start-up

The first frame is either:

- `{"ev":"ready","protocol":1,"helperVersion","engine":"webview2"|"wkwebview"|"webkitgtk","engineVersion","pid","maxFrameBytes","capabilities":{…},"wipe":{"removed","failed"}}`, or
- `{"ev":"fatal","code","message"}`, after which the helper exits with code 3. Codes: `runtime-missing` (no WebView runtime installed), `no-display` (Linux without `DISPLAY`/`WAYLAND_DISPLAY`), `offline-unsupported`, `init-failed`, `invalid-arguments`. The client maps each one to `BrowserCapabilityUnavailable`.

`capabilities` reports what the engine supports: `requestObserve` (`all` | `main-frame` | `none`), `requestReplace`, `statusCodes`, `navigationFailures`, `storage`, `offlineEnforced`, `loadDataBaseUrl`, `startScripts`, `messageChannels`, and `syncScriptInterface` (always `false`).

## Requests

`{"id": <int>, "op": <string>, ...}`, answered by `{"id", "ok": {...}}` or `{"id", "err": {"code", "message", "operation"?, "url"?}}`. Error codes: `capability-unavailable` (names `operation`), `navigation-failed` (names `url`), `interaction-required`, `script-error`, `session-closed`, `cancelled`, `invalid`.

| op | Fields | Reply |
|---|---|---|
| `open` | `session`, `userAgent?`, `title?`, `intercept?` (`none`/`observe`/`replace`) | `{}` |
| `load` | `session`, `url`, `headers?` | `finalUrl`, `status?` once the navigation completes |
| `loadData` | `session`, `html`, `baseUrl` (http/https) | `finalUrl`, `status?` |
| `stop` | `session` | `{}`; drops the pending load |
| `eval` | `session`, `script` | `result`: the completion value as JSON text (a promise is awaited, `undefined` becomes `null`); `script-error` if it throws |
| `channel` | `session`, `name`, `enabled` | `{}` |
| `startScript` | `session`, `script` | `{}`; runs at document start in later documents |
| `intercept` | `session`, `mode` | `{}` |
| `respond` | `rid`, `response?` (`status`, `reason?`, `headers?`, `bodyBase64?`) | `{}`; answers a held request, or `null` to let it proceed |
| `cookies` | `session`, `url` | `cookies: [{name, value, domain?, path?, expiresUnix?, secure, httpOnly}]` |
| `setCookie` | `session`, `url`, `cookie` | `{}`; domain and path default to the URL host and `/` |
| `userAgent` | `session`, `userAgent` | `{}` |
| `show` / `hide` | `session` | `{}` |
| `close` | `session` | `{}` once the session's data is deleted; `capability-unavailable` if deletion is not confirmed |
| `wipe` | — | `removed`; removes stale data directories |
| `debugRequestClose` | `session` | `{}` (needs `--test-hooks`) |
| `shutdown` | — | `{}`, then the helper closes every session and exits |

Scheme policy (KTD20) is enforced in the helper as well as in the client. `load` URLs and every navigation hop must be http, https or `about:blank`. `loadData` base URLs and cookie URLs must be http or https. A redirect to another scheme is reported as `capability-unavailable` with operation `navigation`. On WebView2 that covers Chromium's `REDIRECT_FAILED` status, which a redirect loop also produces. New windows are always denied.

## Events

| ev | Fields |
|---|---|
| `message` | `session`, `name`, `message`: the page called `window.<name>.postMessage(string)` on an enabled channel |
| `request` | `session`, `rid` (an integer when the request is held for `respond`, `null` when observed only), `url`, `method`, `headers`, `context` |
| `interactionEnded` | `session`, `reason`: `closed` (the user closed the window) or `session-closed` |
| `protocolError` | `message` |

## Page bridge

Page-to-host traffic uses wry's `window.ipc.postMessage`. Every frame carries a random per-session key, and frames without it are dropped. Channels are defined as `window.<name> = {postMessage(string)}`, the shape of Android's `addJavascriptInterface` that the Tachi shim expects. Each channel is installed as a document-start script in every frame, and also defined in the current document when it is registered. Removing a channel deletes the object from the current document; later documents still get it, but their messages are dropped.

The origin rule (protocol 1.1) delivers a message only when the posting frame's origin equals the top-level document's origin and both are http(s). The injected script reports the frame's `location.origin` and `top.location.origin`, which a cross-origin frame cannot read. Where the engine identifies the posting document, its URL must agree: WebView2 reports the top document, or the frame's own URL for forwarded child-frame messages; WKWebView reports the frame's request URL. Non-string arguments are dropped in the page. On WebView2, direct child frames are forwarded and nested frames are not.

The key keeps other pages' frames from being accepted. It does not stop the session's own page from forging results, because the page can wrap `JSON.stringify` before an evaluation runs.

## Not supported

- Synchronous script-interface return values (`@JavascriptInterface` methods that return a value) cannot be emulated over asynchronous message handlers on any engine.
- Request bodies are not forwarded in `request` events.
- Request replacement (`replace` tier) works only on WebView2.
