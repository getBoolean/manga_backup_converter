//! WKWebView (macOS). UNVERIFIED: written against objc2-web-kit 0.3 and
//! wry 0.57 but not yet built or run on a Mac (see docs/source-runners.md).
//!
//! Isolation: wry's incognito mode gives each WebView its own
//! `WKWebsiteDataStore.nonPersistentDataStore()`, so sessions share nothing
//! and nothing reaches disk; the store is discarded with the WebView.
//! WKWebView cannot observe or replace http(s) subresource requests and
//! WebKit sends no Chromium client hints (KTD20 degraded capability).

use std::{cell::RefCell, path::Path, rc::Rc};

use objc2::{MainThreadMarker, MainThreadOnly};
use objc2_foundation::{NSString, NSURL};
use objc2_web_kit::{WKUserScript, WKUserScriptInjectionTime};
use tao::{event_loop::EventLoopProxy, window::Window};
use wry::{WebContext, WebView, WebViewBuilder, WebViewExtMacOS};

use super::{Caps, ReplacementResponse};
use crate::{Shared, UserEvent};

pub const ENGINE: &str = "wkwebview";

/// Whether the IPC request URI identifies the posting frame. wry reports the posting frame's request URL (`WKScriptMessage.frameInfo`).
pub const IPC_URI_IS_POSTING_FRAME: bool = true;

pub static CAPS: Caps = Caps {
  request_observe: "none",
  request_replace: false,
  status_codes: false,
  navigation_failures: false,
  storage: "ephemeral-per-session (nonPersistent WKWebsiteDataStore per WebView)",
  offline_enforced: false,
};

pub fn display_missing() -> Option<String> {
  None
}

pub fn web_context(_dir: Option<&Path>) -> Option<WebContext> {
  None
}

pub fn configure_builder<'a>(b: WebViewBuilder<'a>, sid: &str, proxy: EventLoopProxy<UserEvent>) -> WebViewBuilder<'a> {
  super::generic_navigation_hooks(b, sid, proxy)
}

pub fn build(b: WebViewBuilder<'_>, window: &Window) -> wry::Result<WebView> {
  b.build(window)
}

pub struct Native;

pub fn install(_webview: &WebView, _shared: Rc<RefCell<Shared>>, _proxy: EventLoopProxy<UserEvent>) -> Result<Native, String> {
  Ok(Native)
}

pub fn respond(_rid: u64, _response: Option<ReplacementResponse>) {}

pub fn load_data(webview: &WebView, _shared: &Rc<RefCell<Shared>>, html: &str, base: &str) -> Result<(), String> {
  let url = NSURL::URLWithString(&NSString::from_str(base)).ok_or_else(|| format!("invalid base URL {base}"))?;
  unsafe {
    webview.webview().loadHTMLString_baseURL(&NSString::from_str(html), Some(&url));
  }
  Ok(())
}

pub fn stop(webview: &WebView) {
  unsafe {
    webview.webview().stopLoading();
  }
}

pub fn add_start_script(webview: &WebView, js: &str) -> Result<(), String> {
  let mtm = MainThreadMarker::new().ok_or("not on the main thread")?;
  unsafe {
    let script = WKUserScript::initWithSource_injectionTime_forMainFrameOnly(
      WKUserScript::alloc(mtm),
      &NSString::from_str(js),
      WKUserScriptInjectionTime::AtDocumentStart,
      false,
    );
    webview.manager().addUserScript(&script);
  }
  Ok(())
}

pub fn set_user_agent(webview: &WebView, ua: &str) -> Result<(), String> {
  unsafe {
    webview.webview().setCustomUserAgent(Some(&NSString::from_str(ua)));
  }
  Ok(())
}

/// The non-persistent store is discarded with the WebView; nothing persists.
pub fn clear_data(_webview: &WebView) -> Result<(), String> {
  Ok(())
}
