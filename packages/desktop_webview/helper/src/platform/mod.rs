//! Platform layer: what wry does not expose portably (request events,
//! document-start scripts, `loadData` with a base URL, runtime user agent,
//! status codes, storage deletion) is implemented per engine.

use serde_json::{json, Value};

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

/// Navigation hooks for engines without native navigation IDs (WebKit):
/// wry's navigation handler enforces the scheme policy on every navigation
/// it is asked about, and its page-load handler reports completions.
#[cfg(not(target_os = "windows"))]
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
}

impl Caps {
  pub fn to_json(&self) -> Value {
    json!({
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
    let headers = v
      .get("headers")
      .and_then(Value::as_object)
      .map(|h| h.iter().filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string()))).collect())
      .unwrap_or_default();
    Ok(Self {
      status: u16::try_from(status).map_err(|_| "status out of range")?,
      reason: v.get("reason").and_then(Value::as_str).unwrap_or("OK").to_string(),
      headers,
      body,
    })
  }
}
