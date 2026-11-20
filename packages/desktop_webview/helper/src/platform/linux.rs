//! WebKitGTK (Linux). UNVERIFIED: written against webkit2gtk 2.0 (4.1 API)
//! and wry 0.57 but not yet built or run (no WebKitGTK development files on
//! the Windows host; see docs/source-runners.md).
//!
//! Isolation: wry's incognito mode gives each WebView an ephemeral
//! `WebContext`, so sessions share nothing and nothing reaches disk.
//! WebKitGTK sends no Chromium client hints; request observation is not
//! wired yet (`resource-load-started` could provide it).

use std::{cell::RefCell, path::Path, rc::Rc};

use tao::{event_loop::EventLoopProxy, platform::unix::WindowExtUnix, window::Window};
use webkit2gtk::{
  LoadEvent, SettingsExt, UserContentInjectedFrames, UserContentManagerExt, UserScript, UserScriptInjectionTime,
  WebViewExt as _,
};
use wry::{WebContext, WebView, WebViewBuilder, WebViewBuilderExtUnix, WebViewExtUnix};

use super::{Caps, ReplacementResponse};
use crate::{Shared, UserEvent};

pub const ENGINE: &str = "webkitgtk";

/// Whether the IPC request URI identifies the posting frame. wry reports the top-level URL for every frame, so the posting frame's `location.origin` from the injected script is used instead.
pub const IPC_URI_IS_POSTING_FRAME: bool = false;

pub static CAPS: Caps = Caps {
  request_observe: "none",
  request_replace: false,
  status_codes: false,
  navigation_failures: true,
  storage: "ephemeral-per-session (ephemeral WebContext per WebView)",
  offline_enforced: false,
};

/// GTK needs a display even for hidden windows.
pub fn display_missing() -> Option<String> {
  let set = |k: &str| std::env::var_os(k).is_some_and(|v| !v.is_empty());
  (!set("DISPLAY") && !set("WAYLAND_DISPLAY")).then(|| "neither DISPLAY nor WAYLAND_DISPLAY is set".to_string())
}

pub fn web_context(_dir: Option<&Path>) -> Option<WebContext> {
  None
}

pub fn configure_builder<'a>(
  b: WebViewBuilder<'a>,
  sid: &str,
  proxy: EventLoopProxy<UserEvent>,
  _offline: bool,
) -> WebViewBuilder<'a> {
  super::generic_navigation_hooks(b, sid, proxy)
}

pub fn build(b: WebViewBuilder<'_>, window: &Window) -> wry::Result<WebView> {
  let vbox = window.default_vbox().expect("tao creates a default vbox");
  b.build_gtk(vbox)
}

pub struct Native;

pub fn install(webview: &WebView, shared: Rc<RefCell<Shared>>, proxy: EventLoopProxy<UserEvent>) -> Result<Native, String> {
  let sid = shared.borrow().id.clone();
  webview.webview().connect_load_failed(move |_, _event: LoadEvent, uri, err| {
    let _ = proxy.send_event(UserEvent::NavFinished {
      session: sid.clone(),
      url: uri.to_string(),
      ok: false,
      status: None,
      error: Some(err.to_string()),
    });
    false
  });
  Ok(Native)
}

pub fn respond(_rid: u64, _response: Option<ReplacementResponse>) {}

pub fn load_data(webview: &WebView, _shared: &Rc<RefCell<Shared>>, html: &str, base: &str) -> Result<(), String> {
  webview.webview().load_html(html, Some(base));
  Ok(())
}

pub fn stop(webview: &WebView) {
  webview.webview().stop_loading();
}

pub fn add_start_script(webview: &WebView, js: &str) -> Result<(), String> {
  let manager = webview.webview().user_content_manager().ok_or("no user content manager")?;
  let script = UserScript::new(js, UserContentInjectedFrames::AllFrames, UserScriptInjectionTime::Start, &[], &[]);
  manager.add_script(&script);
  Ok(())
}

pub fn set_user_agent(webview: &WebView, ua: &str) -> Result<(), String> {
  let settings = webview.webview().settings().ok_or("no settings")?;
  settings.set_user_agent(Some(ua));
  Ok(())
}

/// The ephemeral context is discarded with the WebView; nothing persists.
pub fn clear_data(_webview: &WebView) -> Result<(), String> {
  Ok(())
}
