//! WKWebView (macOS). UNVERIFIED at runtime: type-checked with
//! `cargo check --target aarch64-apple-darwin` against objc2-web-kit 0.3 and
//! wry 0.57, but not yet run on a Mac (see docs/source-runners.md).
//!
//! Isolation: wry's incognito mode gives each WebView its own
//! `WKWebsiteDataStore.nonPersistentDataStore()`, so sessions share nothing
//! and nothing reaches disk; the store is discarded with the WebView.
//! WKWebView cannot observe or replace http(s) subresource requests and
//! WebKit sends no Chromium client hints (KTD20 degraded capability).
//!
//! Page messages use a WebKit script message handler under the private name
//! [HOST_HANDLER] (`window.webkit.messageHandlers.<name>`), not wry's IPC
//! handler, which would define a frozen `window.ipc`.

use std::{cell::RefCell, path::Path, rc::Rc};

use objc2::{define_class, msg_send, rc::Retained, runtime::{NSObject, ProtocolObject}, DeclaredClass, MainThreadMarker, MainThreadOnly};
use objc2_foundation::{NSObjectProtocol, NSString, NSURL};
use objc2_web_kit::{WKScriptMessage, WKScriptMessageHandler, WKUserContentController, WKUserScript, WKUserScriptInjectionTime};
use tao::{event_loop::EventLoopProxy, window::Window};
use wry::{WebContext, WebView, WebViewBuilder, WebViewExtMacOS};

use super::{Answer, Caps};
use crate::{Shared, UserEvent};

pub const ENGINE: &str = "wkwebview";

/// Whether the message source URI identifies the posting frame: the handler
/// reports the posting frame's request URL (`WKScriptMessage.frameInfo`).
pub const IPC_URI_IS_POSTING_FRAME: bool = true;

/// Private script message handler name; page scripts never see it as a
/// `window` global.
const HOST_HANDLER: &str = "dwvHost";

/// The engine's post function, captured at document start.
pub const POST_EXPR: &str = "(function(){var m=window.webkit&&window.webkit.messageHandlers;var h=m&&m.dwvHost;return h&&typeof h.postMessage==='function'?h.postMessage.bind(h):null})()";

pub static CAPS: Caps = Caps {
  request_observe: "none",
  request_replace: false,
  status_codes: false,
  navigation_failures: false,
  storage: "ephemeral-per-session (nonPersistent WKWebsiteDataStore per WebView)",
  offline_enforced: false,
  browser: &[
    ("pageStartScripts", None),
    ("observeNavigations", Some("the WKWebView helper does not observe requests yet (wry exposes no request event on WKWebView)")),
    ("observeSubresources", Some("WKWebView cannot observe http(s) subresource requests")),
    ("observeRequestHeaders", Some("the WKWebView helper does not observe requests yet")),
    ("observeClientHints", Some("WebKit engines do not send Chromium client hints")),
    ("observeRequestBodies", Some("WKWebView exposes no request bodies (no http(s) request observation)")),
    ("replaceRequests", Some("WKWebView cannot substitute http(s) responses")),
    ("scriptErrors", Some("thrown-script reporting is not yet verified on WKWebView (macOS runtime verification pending)")),
  ],
};

/// No synthetic native close here: the caller falls back to the
/// `CloseRequested` handler directly.
pub fn request_window_close(_window: &Window) -> Result<(), String> {
  Err("no native close request on this engine".into())
}

pub fn display_missing() -> Option<String> {
  None
}

/// WKWebView's processes are owned by WebKit and end with the WebView; there
/// is no data directory for them to hold.
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
  b.build(window)
}

pub struct HostHandlerIvars {
  session: String,
  proxy: EventLoopProxy<UserEvent>,
}

define_class!(
  #[unsafe(super(NSObject))]
  #[thread_kind = MainThreadOnly]
  #[ivars = HostHandlerIvars]
  struct HostHandler;

  unsafe impl NSObjectProtocol for HostHandler {}

  unsafe impl WKScriptMessageHandler for HostHandler {
    #[unsafe(method(userContentController:didReceiveScriptMessage:))]
    fn did_receive(&self, _controller: &WKUserContentController, msg: &WKScriptMessage) {
      unsafe {
        let Ok(body) = msg.body().downcast::<NSString>() else { return };
        let uri = msg.frameInfo().request().URL().and_then(|u| u.absoluteString()).map(|s| s.to_string()).unwrap_or_default();
        let ivars = self.ivars();
        let _ = ivars.proxy.send_event(UserEvent::Ipc { session: ivars.session.clone(), uri, body: body.to_string() });
      }
    }
  }
);

/// Keeps the session's script message handler registered; removes it (the
/// controller retains the handler) when the session ends.
pub struct Native {
  controller: Retained<WKUserContentController>,
  _handler: Retained<HostHandler>,
}

impl Drop for Native {
  fn drop(&mut self) {
    unsafe {
      self.controller.removeScriptMessageHandlerForName(&NSString::from_str(HOST_HANDLER));
    }
  }
}

pub fn install(webview: &WebView, shared: Rc<RefCell<Shared>>, proxy: EventLoopProxy<UserEvent>) -> Result<Native, String> {
  let mtm = MainThreadMarker::new().ok_or("not on the main thread")?;
  let session = shared.borrow().id.clone();
  let handler = mtm.alloc::<HostHandler>().set_ivars(HostHandlerIvars { session, proxy });
  let handler: Retained<HostHandler> = unsafe { msg_send![super(handler), init] };
  let controller = webview.manager();
  unsafe {
    controller.addScriptMessageHandler_name(ProtocolObject::from_ref(&*handler), &NSString::from_str(HOST_HANDLER));
  }
  Ok(Native { controller, _handler: handler })
}

pub fn respond(_rid: u64, _answer: Answer) {}

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
