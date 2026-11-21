# desktop_webview helper protocol (version 1)

`desktop_webview_helper` is a standalone executable (Rust, `wry` 0.57.3 / `tao` 0.37.3) that drives the platform WebView: WebView2 on Windows, WKWebView on macOS, WebKitGTK on Linux. It is a separate program because macOS needs the AppKit event loop on the process main thread, and the repository's cargo build hooks produce only dynamic-library code assets (KTD20). `DesktopBrowserPort` (`lib/src/desktop_browser_port.dart`) is its only client: one helper process per conversion and one helper session per source session.

## Transport

- **Frames:** UTF-8 JSON objects, one per line, on stdin (client → helper) and stdout (helper → client). Neither side accepts a frame larger than 16 MiB (KTD4). The client refuses to send an oversized request. An oversized or malformed frame on stdin makes the helper emit `protocolError` and exit.
- **Logs:** stderr only. Lines may contain URLs; the client passes them to `DesktopWebViewConfig.onLog`, which should be a redacting sink (KTD9).
- **Lifetime:** the helper exits when stdin closes, so a crashed or killed parent never leaves windows or WebViews behind.

## Arguments

| Argument | Meaning |
|---|---|
| `--data-root <dir>` | Parent of per-process data directories (`h-<pid>`). Stale `h-*` directories are removed at start-up before any session opens (KTD20 start-up wipe, one attempt). Each is renamed first, so a directory a live helper's browser still holds is skipped rather than partly deleted. On Windows the helper runs in a kill-on-close job object, so its WebView2 processes end with it even when it is killed; the browser process can still take 1-90 s (measured, WebView2 157) to finish terminating and release the directory, which the `wipe` request's retry budget covers. The helper tries to remove its own directory at exit; the next wipe removes what is left. Only WebView2 uses it. |
| `--offline` | Replay mode. Every non-loopback request that no `respond` answers is blocked with a 502 (`X-Desktop-Webview-Blocked: 1`). On WebView2, interception covers all request source kinds, and `--host-resolver-rules` keeps every host except loopback from resolving, as a backstop for traffic interception misses (WebSockets). Engines that cannot block requests refuse to start (`fatal` `offline-unsupported`) instead of falling through to the network. |
| `--test-hooks` | Enables `debugRequestClose`. |
| `--simulate-fatal <code>` | Test hook: report `fatal` with this code at start-up. |
| `--version` | Prints the helper and protocol versions. |

## Start-up

The first frame is either:

- `{"ev":"ready","protocol":1,"helperVersion","engine":"webview2"|"wkwebview"|"webkitgtk","engineVersion","pid","maxFrameBytes","capabilities":{…},"wipe":{"removed","failed"}}`, or
- `{"ev":"fatal","code","message"}`, after which the helper exits with code 3. Codes: `runtime-missing` (no WebView runtime installed), `no-display` (Linux without `DISPLAY`/`WAYLAND_DISPLAY`), `offline-unsupported`, `init-failed`, `invalid-arguments`. The client maps each one to `BrowserCapabilityUnavailable`.

`capabilities` reports what the engine supports: `browser`, the protocol 1.2 `BrowserCapabilities` of every session (`{"available": [feature], "unavailable": {feature: reason}}`, each reason naming the engine; the client uses it as `BrowserSession.capabilities`), plus `requestObserve` (`all` | `main-frame` | `none`), `requestReplace`, `statusCodes`, `navigationFailures`, `storage`, `offlineEnforced`, `loadDataBaseUrl`, `startScripts`, `messageChannels`, and `syncScriptInterface` (always `false`). A feature is listed available only once it has run on that engine.

## Requests

`{"id": <int>, "op": <string>, ...}`, answered by `{"id", "ok": {...}}` or `{"id", "err": {"code", "message", "operation"?, "url"?}}`. Error codes: `capability-unavailable` (names `operation`), `navigation-failed` (names `url`), `interaction-required`, `script-error` (the script threw or its promise rejected; `message` is the thrown value), `no-script-bridge` (the document has no page bridge, e.g. the initial `about:blank`), `navigated` (the page navigated away before the script completed), `session-closed`, `cancelled`, `invalid`.

| op | Fields | Reply |
|---|---|---|
| `open` | `session`, `userAgent?`, `title?`, `intercept?` (`none`/`observe`/`replace`) | `{}` |
| `load` | `session`, `url`, `headers?` | `finalUrl`, `status?` once the navigation completes |
| `loadData` | `session`, `html`, `baseUrl` (http/https) | `finalUrl`, `status?` |
| `stop` | `session` | `{}`; drops the pending load |
| `eval` | `session`, `script` | `result`: the completion value as JSON text (a promise is awaited, `undefined` becomes `null`); `script-error` only if it throws, `no-script-bridge` or `navigated` otherwise |
| `channel` | `session`, `name`, `enabled` | `{}` |
| `startScript` | `session`, `script` | `{}`; runs at document start in later documents |
| `intercept` | `session`, `mode` | `{}` |
| `respond` | `rid`, `response?` (`status`, `reason?`, `headers?`, `bodyBase64?`), `fail?: string` | `{}`; answers a held request with the response, or `null` to let it proceed. `fail` (a reason) fails it: the page sees a network error. A `response` that is not a valid protocol 1.2 `BrowserReplacement` (status outside 100-599 or 300-399, a reason that is not one non-empty line, a multi-line header) also fails the request, and the reply is `invalid` |
| `cookies` | `session`, `url` | `cookies: [{name, value, domain?, path?, expiresUnix?, secure, httpOnly}]` |
| `setCookie` | `session`, `url`, `cookie` | `{}`; domain and path default to the URL host and `/` |
| `userAgent` | `session`, `userAgent` | `{}` |
| `show` / `hide` | `session` | `{}` |
| `close` | `session` | `{}` once the session's data is deleted; `capability-unavailable` if deletion is not confirmed |
| `wipe` | `retryMs?` | `removed`; removes stale data directories, retrying with backoff for up to `retryMs` while one is still in use. `capability-unavailable` names each directory that could not be removed and why. Runs off the event loop |
| `debugRequestClose` | `session` | `{}` (needs `--test-hooks`) |
| `shutdown` | — | `{}`, then the helper closes every session and exits |

Scheme policy (KTD20) is enforced in the helper as well as in the client. `load` URLs and every navigation hop must be http, https or `about:blank`. `loadData` base URLs and cookie URLs must be http or https. A redirect to another scheme is reported as `capability-unavailable` with operation `navigation`. On WebView2 that covers Chromium's `REDIRECT_FAILED` status, which a redirect loop also produces. New windows are always denied.

## Events

| ev | Fields |
|---|---|
| `message` | `session`, `name`, `message`: the page called `window.<name>.postMessage(string)` on an enabled channel |
| `request` | `session`, `rid` (an integer when the request is held for `respond`, `null` when observed only), `url`, `method`, `headers`, `bodyBase64` (the body, at most 1 MiB, or `null`), `bodyOmitted` (the request had a body the event does not carry: larger than 1 MiB, or not exposed by the engine), `mainFrame` (the top-level document request), `redirect`, `context` |
| `interactionEnded` | `session`, `reason`: `closed` (the user closed the window) or `session-closed` |
| `protocolError` | `message` |

## Page bridge

Page-to-host traffic uses the engine's own messaging, not wry's IPC handler (which defines a frozen `window.ipc` and so would make `ipc` unusable as a channel name): WebView2 `window.chrome.webview.postMessage` with `WebMessageReceived` (and per-frame `WebMessageReceived` for child frames), or a WebKit script message handler under the private name `dwvHost` on macOS and Linux. The session's first document-start script captures that post function before any channel or page script runs and stores it under a `window` property whose name is not an identifier (`dwv:<random>`), so no channel name (`ipc`, `chrome`, `webkit`, ...) can shadow it. Every message carries a random per-session key, and messages without it are dropped. Channels are defined as `window.<name> = {postMessage(string)}`, the shape of Android's `addJavascriptInterface` that the Tachi shim expects. Each channel is installed as a document-start script in every frame, and also defined in the current document when it is registered. Removing a channel deletes the object from the current document; later documents still get it, but their messages are dropped.

The origin rule (protocol 1.1) delivers a message only when the posting frame's origin equals the top-level document's origin and both are http(s). The injected script reports the frame's `location.origin` and `top.location.origin`, which a cross-origin frame cannot read. Where the engine identifies the posting document, its URL must agree: WebView2 reports the top document, or the frame's own URL for forwarded child-frame messages; WKWebView reports the frame's request URL. Non-string arguments are dropped in the page. On WebView2, direct child frames are forwarded and nested frames are not.

The key keeps other pages' frames from being accepted. It does not stop the session's own page from forging results, because the page can wrap `JSON.stringify` before an evaluation runs.

## Request bodies and frames (WebView2)

- **Bodies:** read from `Request.Content`, capped at 1 MiB (a larger body is omitted whole, never truncated), and the stream is rewound so the upload is unchanged. A request without a `Content` stream that declares a `Content-Type` and is not GET or HEAD reports `bodyOmitted` (a body WebView2 does not expose); otherwise it has no body.
- **Main frame:** `NavigationStarting` (top-level navigations and their redirect hops) precedes the document's `WebResourceRequested`; a `document` request for a URL announced that way is the main frame's, every other request is not.
- **Failing a held request:** WebView2 has no call that aborts a request, so the helper rewrites the request URL to `http://127.0.0.1:1/…`. Port 1 is on Chromium's restricted-port list, so the network stack refuses it without connecting, and the page sees a network error (a failed main-frame document settles `load` as `navigation-failed`). The original request is never sent.

## Not supported

- Synchronous script-interface return values (`@JavascriptInterface` methods that return a value) cannot be emulated over asynchronous message handlers on any engine.
- Request bodies on WKWebView and WebKitGTK (no request observation there).
- Request replacement (`replace` tier) works only on WebView2.
