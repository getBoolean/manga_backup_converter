//! Platform layer: what wry does not expose portably (request events,
//! document-start scripts, `loadData` with a base URL, runtime user agent,
//! status codes, storage deletion) is implemented per engine.

use serde_json::{json, Map, Value};

#[cfg(target_os = "windows")]
mod windows;
#[cfg(target_os = "windows")]
pub use self::windows::*;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use self::macos::*;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use self::linux::*;

/// Navigation hooks for engines without native navigation IDs (WebKitGTK):
/// wry's navigation handler enforces the scheme policy on every navigation
/// it is asked about, and its page-load handler reports completions.
#[cfg(target_os = "linux")]
pub fn generic_navigation_hooks<'a>(
  b: wry::WebViewBuilder<'a>,
  sid: &str,
  proxy: tao::event_loop::EventLoopProxy<crate::UserEvent>,
) -> wry::WebViewBuilder<'a> {
  use crate::UserEvent;
  let (nav_proxy, nav_sid) = (proxy.clone(), sid.to_string());
  let (load_proxy, load_sid) = (proxy, sid.to_string());
  b.with_navigation_handler(move |uri| {
    let allowed = crate::policy::is_navigable(&uri);
    let _ = nav_proxy.send_event(UserEvent::NavStarting { session: nav_sid.clone(), uri: uri.clone(), rejected: !allowed });
    if !allowed {
      // The engine reports no completion for a refused navigation.
      let _ = nav_proxy.send_event(UserEvent::NavFinished {
        session: nav_sid.clone(),
        url: uri,
        ok: false,
        status: None,
        error: Some("refused by scheme policy".into()),
      });
    }
    allowed
  })
  .with_on_page_load_handler(move |event, url| {
    if matches!(event, wry::PageLoadEvent::Finished) {
      let _ = load_proxy.send_event(UserEvent::NavFinished { session: load_sid.clone(), url, ok: true, status: None, error: None });
    }
  })
}

/// Channel names the engine reserves, with the reason (WKWebView only).
#[cfg(not(target_os = "macos"))]
pub const RESERVED_CHANNELS: &[(&str, &str)] = &[];

/// Cookies sent to [url], as the engine reports them.
#[cfg(not(target_os = "macos"))]
pub fn cookies_for_url(webview: &wry::WebView, url: &str) -> Result<Vec<wry::cookie::Cookie<'static>>, String> {
  webview.cookies_for_url(url).map_err(|e| e.to_string())
}

/// Engine capabilities reported in the `ready` event.
pub struct Caps {
  /// `all` (every request, with headers), `main-frame` or `none`.
  pub request_observe: &'static str,
  /// Whether a request can be answered with a substituted response.
  pub request_replace: bool,
  /// Whether completed loads report an HTTP status code.
  pub status_codes: bool,
  /// Whether failed navigations are detected (otherwise only cancellation
  /// ends a load that never finishes).
  pub navigation_failures: bool,
  /// How session storage is isolated and removed.
  pub storage: &'static str,
  /// Whether `--offline` can block every non-loopback request.
  pub offline_enforced: bool,
  /// Protocol 1.2 `BrowserFeature`s of every session: `(feature, None)` when
  /// available, `(feature, Some(reason))` when not, the reason naming the
  /// engine. Each listed state is what this engine's code path does; a
  /// feature is listed available only once it has run on that engine.
  pub browser: &'static [(&'static str, Option<&'static str>)],
}

impl Caps {
  /// The protocol 1.2 `BrowserCapabilities` JSON of every session.
  fn browser_json(&self) -> Value {
    let available: Vec<&str> = self.browser.iter().filter(|(_, r)| r.is_none()).map(|(f, _)| *f).collect();
    let unavailable: Map<String, Value> =
      self.browser.iter().filter_map(|(f, r)| r.map(|r| (f.to_string(), Value::String(r.to_string())))).collect();
    json!({"available": available, "unavailable": unavailable})
  }

  pub fn to_json(&self) -> Value {
    json!({
      "browser": self.browser_json(),
      "requestObserve": self.request_observe,
      "requestReplace": self.request_replace,
      "statusCodes": self.status_codes,
      "navigationFailures": self.navigation_failures,
      "storage": self.storage,
      "offlineEnforced": self.offline_enforced,
      "loadDataBaseUrl": true,
      "startScripts": true,
      "messageChannels": "window.<name>.postMessage(string)",
      "syncScriptInterface": false,
    })
  }
}

/// How a held request (replace tier) is answered.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub enum Answer {
  /// Let it proceed unchanged (blocked when offline).
  Proceed,
  /// Serve this response instead.
  Replace(ReplacementResponse),
  /// Fail it: the page sees a network error. Used for an invalid
  /// replacement and a throwing handler.
  Fail(String),
}

/// A response substituted for an intercepted request (replace tier).
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub struct ReplacementResponse {
  pub status: u16,
  pub reason: String,
  pub headers: Vec<(String, String)>,
  pub body: Vec<u8>,
}

impl ReplacementResponse {
  pub fn from_json(v: &Value) -> Result<Self, String> {
    use base64::Engine as _;
    let status = v.get("status").and_then(Value::as_u64).ok_or("response needs a status")?;
    let body = match v.get("bodyBase64").and_then(Value::as_str) {
      Some(b) => base64::engine::general_purpose::STANDARD.decode(b).map_err(|e| format!("bad bodyBase64: {e}"))?,
      None => Vec::new(),
    };
    let headers: Vec<(String, String)> = v
      .get("headers")
      .and_then(Value::as_object)
      .map(|h| h.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string()))).collect())
      .unwrap_or_default();
    // Protocol 1.2 `BrowserReplacement`: 100-599 and not a redirect (a
    // substituted `Location` could steer a load around the scheme policy);
    // the reason is one non-empty line.
    if !(100..=599).contains(&status) {
      return Err(format!("status {status} is outside 100-599"));
    }
    if (300..=399).contains(&status) {
      return Err(format!("redirect status {status} cannot be substituted"));
    }
    let reason = v.get("reason").and_then(Value::as_str).unwrap_or("OK").to_string();
    let multiline = |s: &str| s.contains(['\r', '\n']);
    if reason.is_empty() || multiline(&reason) {
      return Err("reason phrase must be one non-empty line".into());
    }
    if headers.iter().any(|(k, v)| k.is_empty() || k.contains(':') || multiline(k) || multiline(v)) {
      return Err("header names and values must be single-line".into());
    }
    Ok(Self { status: status as u16, reason, headers, body })
  }
}
