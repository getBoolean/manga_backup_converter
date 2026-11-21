//! WebKitGTK (Linux). UNVERIFIED: written against webkit2gtk 2.0 (4.1 API)
//! and wry 0.57 but not yet built or run (no WebKitGTK development files on
//! the Windows host; see docs/source-runners.md).
//!
//! Isolation: wry's incognito mode gives each WebView an ephemeral
//! `WebContext`, so sessions share nothing and nothing reaches disk.
//! WebKitGTK sends no Chromium client hints; request observation is not
//! wired yet (`resource-load-started` could provide it).
//!
//! Page messages use a WebKit script message handler under the private name
//! [HOST_HANDLER] (`window.webkit.messageHandlers.<name>`), not wry's IPC
//! handler, which would define a frozen `window.ipc`.

use std::{cell::RefCell, path::Path, rc::Rc};

use javascriptcore::ValueExt as _;
use tao::{event_loop::EventLoopProxy, platform::unix::WindowExtUnix, window::Window};
use webkit2gtk::{
  LoadEvent, SettingsExt, UserContentInjectedFrames, UserContentManager, UserContentManagerExt, UserScript,
  UserScriptInjectionTime, WebViewExt as _,
};
use wry::{WebContext, WebView, WebViewBuilder, WebViewBuilderExtUnix, WebViewExtUnix};

use super::{Answer, Caps};
use crate::{Shared, UserEvent};

pub const ENGINE: &str = "webkitgtk";

/// Whether the message source URI identifies the posting frame. WebKitGTK's
/// script message signal does not identify the frame, so the posting frame's
/// `location.origin` from the injected script is used instead.
pub const IPC_URI_IS_POSTING_FRAME: bool = false;

/// Private script message handler name; page scripts never see it as a
/// `window` global.
const HOST_HANDLER: &str = "dwvHost";

/// The engine's post function, captured at document start.
pub const POST_EXPR: &str = "(function(){var m=window.webkit&&window.webkit.messageHandlers;var h=m&&m.dwvHost;return h&&typeof h.postMessage==='function'?h.postMessage.bind(h):null})()";

pub static CAPS: Caps = Caps {
  request_observe: "none",
  request_replace: false,
  status_codes: false,
  navigation_failures: true,
  storage: "ephemeral-per-session (ephemeral WebContext per WebView)",
  offline_enforced: false,
  browser: &[
    ("pageStartScripts", None),
    ("observeNavigations", Some("the WebKitGTK helper does not observe requests yet (resource-load-started is not wired)")),
    ("observeSubresources", Some("the WebKitGTK helper does not observe http(s) subresource requests")),
    ("observeRequestHeaders", Some("the WebKitGTK helper does not observe requests yet")),
    ("observeClientHints", Some("WebKit engines do not send Chromium client hints")),
    ("observeRequestBodies", Some("WebKitGTK exposes no request bodies to the helper (no request observation)")),
    ("replaceRequests", Some("WebKitGTK cannot substitute http(s) responses")),
    ("scriptErrors", Some("thrown-script reporting is not yet verified on WebKitGTK (Linux runtime verification pending)")),
  ],
};

/// GTK needs a display even for hidden windows.
/// No synthetic native close here: the caller falls back to the
/// `CloseRequested` handler directly.
pub fn request_window_close(_window: &Window) -> Result<(), String> {
  Err("no native close request on this engine".into())
}

pub fn display_missing() -> Option<String> {
  let set = |k: &str| std::env::var_os(k).is_some_and(|v| !v.is_empty());
  (!set("DISPLAY") && !set("WAYLAND_DISPLAY")).then(|| "neither DISPLAY nor WAYLAND_DISPLAY is set".to_string())
}

/// WebKitGTK's ephemeral contexts use no data directory, so a surviving web
/// process holds nothing the start-up wipe needs to remove.
pub fn contain_child_processes() -> Result<(), String> {
  Ok(())
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

/// Keeps the session's script message handler registered; unregisters it
/// when the session ends.
pub struct Native {
  manager: UserContentManager,
}

impl Drop for Native {
  fn drop(&mut self) {
    self.manager.unregister_script_message_handler(HOST_HANDLER);
  }
}

pub fn install(webview: &WebView, shared: Rc<RefCell<Shared>>, proxy: EventLoopProxy<UserEvent>) -> Result<Native, String> {
  let sid = shared.borrow().id.clone();
  let view = webview.webview();
  let manager = view.user_content_manager().ok_or("no user content manager")?;
  let (msg_proxy, msg_sid, msg_view) = (proxy.clone(), sid.clone(), view.clone());
  manager.connect_script_message_received(Some(HOST_HANDLER), move |_, result| {
    let Some(value) = result.js_value() else { return };
    if !value.is_string() {
      return;
    }
    let uri = msg_view.uri().map(|u| u.to_string()).unwrap_or_default();
    let _ = msg_proxy.send_event(UserEvent::Ipc { session: msg_sid.clone(), uri, body: value.to_str().to_string() });
  });
  if !manager.register_script_message_handler(HOST_HANDLER) {
    return Err(format!("cannot register script message handler {HOST_HANDLER}"));
  }
  view.connect_load_failed(move |_, _event: LoadEvent, uri, err| {
    let _ = proxy.send_event(UserEvent::NavFinished {
      session: sid.clone(),
      url: uri.to_string(),
      ok: false,
      status: None,
      error: Some(err.to_string()),
    });
    false
  });
  Ok(Native { manager })
}

pub fn respond(_rid: u64, _answer: Answer) {}

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
