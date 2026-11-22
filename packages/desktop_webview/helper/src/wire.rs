//! Typed frames of the helper protocol (`doc/helper-protocol.md`).
//!
//! [Command] is what `DesktopBrowserPort` sends: each variant's fields are the
//! ones the Dart client writes, so a missing or mistyped field is an explicit
//! `invalid` error instead of an empty string. [Event] is what the helper
//! reports.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::InterceptMode;

/// The `cookie` of a `setCookie` request (Dart `BrowserCookie`).
#[derive(Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CookieSpec {
  pub name: String,
  pub value: String,
  pub domain: Option<String>,
  pub path: Option<String>,
  pub expires_unix: Option<i64>,
  pub secure: bool,
  pub http_only: bool,
}

/// One client request, without its envelope `id`.
#[derive(Debug, PartialEq, Deserialize, Serialize)]
#[serde(tag = "op", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Command {
  Open { session: String, user_agent: Option<String>, title: Option<String>, intercept: Option<InterceptMode> },
  Load { session: String, url: String, headers: Option<BTreeMap<String, String>> },
  LoadData { session: String, html: String, base_url: String },
  Stop { session: String },
  Eval { session: String, script: String },
  Channel { session: String, name: String, enabled: bool },
  StartScript { session: String, script: String },
  Intercept { session: String, mode: InterceptMode },
  /// `response` (a protocol 1.2 `BrowserReplacement`) is validated by
  /// `platform::ReplacementResponse::from_json`; `null` lets the request proceed.
  Respond {
    rid: u64,
    response: Option<Value>,
    fail: Option<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    replay: bool,
  },
  Cookies { session: String, url: String },
  SetCookie { session: String, url: String, cookie: CookieSpec },
  UserAgent { session: String, user_agent: String },
  Show { session: String },
  Hide { session: String },
  Close { session: String },
  Wipe { retry_ms: Option<u64> },
  DebugRequestClose { session: String },
  Shutdown,
}

impl Command {
  /// The session a per-session request addresses (`open` creates its own).
  pub fn session(&self) -> Option<&str> {
    match self {
      Command::Load { session, .. }
      | Command::LoadData { session, .. }
      | Command::Stop { session }
      | Command::Eval { session, .. }
      | Command::Channel { session, .. }
      | Command::StartScript { session, .. }
      | Command::Intercept { session, .. }
      | Command::Cookies { session, .. }
      | Command::SetCookie { session, .. }
      | Command::UserAgent { session, .. }
      | Command::Show { session }
      | Command::Hide { session }
      | Command::Close { session }
      | Command::DebugRequestClose { session } => Some(session),
      Command::Open { .. } | Command::Respond { .. } | Command::Wipe { .. } | Command::Shutdown => None,
    }
  }

  /// The `BrowserPort` operation a `capability-unavailable` error names. The
  /// client reports its own operation name regardless; this keeps the helper's
  /// errors and logs in the contract's vocabulary.
  pub fn operation(&self) -> &'static str {
    match self {
      Command::Open { .. } => "openSession",
      Command::Load { .. } => "loadUrl",
      Command::LoadData { .. } => "loadData",
      Command::Stop { .. } => "stop",
      Command::Eval { .. } => "evaluate",
      Command::Channel { .. } => "setMessageHandler",
      Command::StartScript { .. } => "addPageStartScript",
      Command::Intercept { .. } => "setRequestInterception",
      Command::Respond { .. } => "respond",
      Command::Cookies { .. } => "getCookies",
      Command::SetCookie { .. } => "setCookie",
      Command::UserAgent { .. } => "setUserAgent",
      Command::Show { .. } => "showForInteraction",
      Command::Hide { .. } => "hide",
      Command::Close { .. } => "close",
      Command::Wipe { .. } => "wipeAllSourceData",
      Command::DebugRequestClose { .. } => "debugRequestClose",
      Command::Shutdown => "shutdown",
    }
  }
}

/// Why a shown window stopped showing (`interactionEnded.reason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum InteractionEndReason {
  /// The user closed the window.
  Closed,
  SessionClosed,
}

/// One unsolicited helper frame (`ev`).
#[derive(Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "ev", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Event {
  Ready {
    protocol: u64,
    helper_version: String,
    engine: String,
    engine_version: String,
    pid: u32,
    max_frame_bytes: usize,
    capabilities: Value,
    wipe: WipeSummary,
  },
  Fatal { code: String, message: String },
  Message { session: String, name: String, message: String },
  Request {
    session: String,
    /// Set when the request is held for `respond`.
    rid: Option<u64>,
    url: String,
    method: String,
    headers: BTreeMap<String, String>,
    body_base64: Option<String>,
    body_omitted: bool,
    main_frame: bool,
    redirect: bool,
    context: String,
  },
  InteractionEnded { session: String, reason: InteractionEndReason },
  Exchange {
    session: String,
    method: String,
    url: String,
    request_body_base64: Option<String>,
    request_body_omitted: bool,
    status: i32,
    /// Every response header in order as `[name, value]`, repeated names kept.
    headers: Vec<(String, String)>,
    body_base64: Option<String>,
    body_omitted: bool,
  },
  ProtocolError { message: String },
}

/// The start-up wipe reported in `ready`.
#[derive(Debug, PartialEq, Serialize, Deserialize)]
pub struct WipeSummary {
  pub removed: u32,
  pub failed: usize,
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn a_missing_field_is_an_error_not_an_empty_string() {
    let err = Command::deserialize(&serde_json::json!({"id": 1, "op": "load", "session": "s1"})).unwrap_err();
    assert!(err.to_string().contains("url"), "{err}");
    let err = Command::deserialize(&serde_json::json!({"id": 1, "op": "frobnicate"})).unwrap_err();
    assert!(err.to_string().contains("frobnicate"), "{err}");
  }

  #[test]
  fn page_start_scripts_report_the_contract_operation() {
    // Regression: a failed `startScript` named `addStartScript`, which is no
    // BrowserPort operation (the contract's is `addPageStartScript`).
    let c = Command::StartScript { session: "s1".into(), script: "1".into() };
    assert_eq!(c.operation(), "addPageStartScript");
  }
}
