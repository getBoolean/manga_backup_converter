//! WKWebView (macOS). Run on macOS arm64 (see docs/source-runners.md for the
//! capability matrix and the runs behind it).
//!
//! Isolation: wry's incognito mode gives each WebView its own
//! `WKWebsiteDataStore.nonPersistentDataStore()`, so sessions share nothing
//! and nothing reaches disk; the store is discarded with the WebView.
//! WKWebView cannot observe or replace http(s) subresource requests (a
//! `WKURLSchemeHandler` cannot be registered for http or https) and WebKit
//! sends no Chromium client hints (KTD20 degraded capability).
//!
//! Navigation: the helper replaces wry's navigation delegate with its own
//! ([NavDelegate]), which enforces the scheme policy on every navigation in
//! every frame, reports only main-frame navigations, and settles a load from
//! `didFinishNavigation` (with the main document's HTTP status) or
//! `didFail(Provisional)Navigation`. Completions of a navigation that is no
//! longer current are dropped.
//!
//! Offline replay: a WebKit content rule list blocks every http(s) and ws(s)
//! load whose host is not loopback, in every frame and for every resource
//! type, so replay fails closed. It is compiled once at start-up into a
//! store inside the helper's own data directory.
//!
//! Page messages use a WebKit script message handler under the private name
//! [HOST_HANDLER] (`window.webkit.messageHandlers.<name>`), not wry's IPC
//! handler, which would define a frozen `window.ipc`.

use std::{
  cell::{Cell, RefCell},
  path::{Path, PathBuf},
  rc::Rc,
};

use block2::{Block, RcBlock};
use objc2::{define_class, msg_send, rc::Retained, Message, runtime::{NSObject, ProtocolObject}, DeclaredClass, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::NSWindow;
use objc2_foundation::{NSDate, NSDefaultRunLoopMode, NSError, NSHTTPURLResponse, NSObjectProtocol, NSRunLoop, NSString, NSURL};
use objc2_web_kit::{
  WKContentRuleList, WKContentRuleListStore, WKNavigation, WKNavigationAction, WKNavigationActionPolicy, WKNavigationDelegate,
  WKNavigationResponse, WKNavigationResponsePolicy, WKScriptMessage, WKScriptMessageHandler, WKUserContentController, WKUserScript,
  WKUserScriptInjectionTime, WKWebView,
};
use tao::{event_loop::EventLoopProxy, platform::macos::WindowExtMacOS, window::Window};
use wry::{WebContext, WebView, WebViewBuilder, WebViewExtMacOS};

use super::{Answer, Caps};
use crate::{policy, Shared, UserEvent};

pub const ENGINE: &str = "wkwebview";

/// Whether the message source URI identifies the posting frame: the handler
/// reports the posting frame's request URL (`WKScriptMessage.frameInfo`).
pub const IPC_URI_IS_POSTING_FRAME: bool = true;

/// Private script message handler name; page scripts never see it as a
/// `window` global.
const HOST_HANDLER: &str = "dwvHost";

/// A navigation that never commits (refused, blocked offline by the content
/// rules, failed provisionally) leaves the document and its running scripts
/// in place, so pending evaluations end only when a new main-frame document
/// commits (measured: a captured page's meta refresh to a blocked URL would
/// otherwise cancel the evaluation while the page kept running).
pub const DRAIN_EVALS_ON_COMMIT: bool = true;

/// Channel names WKWebView itself defines as non-configurable, non-writable
/// `window` properties (measured: `window.webkit`); a channel cannot replace
/// them, so the helper refuses them by name.
pub const RESERVED_CHANNELS: &[(&str, &str)] =
  &[("webkit", "window.webkit is a non-configurable WKWebView global that a page channel cannot replace")];

/// The engine's post function, captured at document start.
pub const POST_EXPR: &str = "(function(){var m=window.webkit&&window.webkit.messageHandlers;var h=m&&m.dwvHost;return h&&typeof h.postMessage==='function'?h.postMessage.bind(h):null})()";

pub static CAPS: Caps = Caps {
  request_observe: "none",
  request_replace: false,
  status_codes: true,
  navigation_failures: true,
  storage: "ephemeral-per-session (nonPersistent WKWebsiteDataStore per WebView)",
  offline_enforced: true,
  record: false,
  browser: &[
    ("pageStartScripts", None),
    ("scriptErrors", None),
    ("observeNavigations", Some("WKWebView exposes navigation requests only to its policy delegate, without the headers the engine sends; the helper does not report them")),
    ("observeSubresources", Some("WKWebView cannot observe http(s) subresource requests (no URL scheme handler for http or https)")),
    ("observeRequestHeaders", Some("WKWebView does not expose the request headers it sends")),
    ("observeClientHints", Some("WebKit engines do not send Chromium client hints")),
    ("observeRequestBodies", Some("WKWebView exposes no request bodies (no http(s) request observation)")),
    ("replaceRequests", Some("WKWebView cannot substitute http(s) responses (no URL scheme handler for http or https)")),
  ],
};

/// Asks AppKit to close the window as its close button would
/// (`performClose:`): the window delegate's `windowShouldClose:` turns it
/// into `WindowEvent::CloseRequested`.
pub fn request_window_close(window: &Window) -> Result<(), String> {
  let ptr = window.ns_window() as *const NSWindow;
  let ns_window = unsafe { ptr.as_ref() }.ok_or("the window has no NSWindow")?;
  ns_window.performClose(None);
  Ok(())
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

thread_local! {
  /// The compiled offline rule list, added to every session when set.
  static OFFLINE_RULES: RefCell<Option<Retained<WKContentRuleList>>> = const { RefCell::new(None) };
  /// Store directory to delete at exit when it is not inside the helper's
  /// data directory.
  static RULE_STORE: RefCell<Option<PathBuf>> = const { RefCell::new(None) };
}

/// Loopback hosts offline replay may reach (the test fixture servers).
const LOOPBACK_HOSTS: &[&str] = &["127\\.0\\.0\\.1", "localhost", "\\[::1\\]"];

/// The offline content rules: block every http(s) and ws(s) URL, then exempt
/// loopback hosts. WebKit's rule regular expressions have no alternation, so
/// every scheme and host gets its own rule.
fn offline_rules_json() -> String {
  let schemes = ["https?", "wss?"];
  let mut rules = Vec::new();
  for s in schemes {
    rules.push(serde_json::json!({"trigger": {"url-filter": format!("^{s}://")}, "action": {"type": "block"}}));
  }
  for h in LOOPBACK_HOSTS {
    for s in schemes {
      rules.push(serde_json::json!({"trigger": {"url-filter": format!("^{s}://{h}[:/]")}, "action": {"type": "ignore-previous-rules"}}));
    }
  }
  serde_json::Value::Array(rules).to_string()
}

/// Compiles the offline rule list before any session exists (fail closed:
/// an error stops the helper). [dir] is the helper's data directory; without
/// one a private temporary directory is used and deleted at exit.
pub fn prepare_offline(dir: Option<&Path>) -> Result<(), String> {
  let mtm = MainThreadMarker::new().ok_or("not on the main thread")?;
  let store_dir = match dir {
    Some(d) => d.join("content-rules"),
    None => {
      let d = std::env::temp_dir().join(format!("dwv-rules-{}", std::process::id()));
      RULE_STORE.with(|s| *s.borrow_mut() = Some(d.clone()));
      d
    }
  };
  std::fs::create_dir_all(&store_dir).map_err(|e| format!("cannot create the rule store: {e}"))?;
  let url = NSURL::fileURLWithPath_isDirectory(&NSString::from_str(&store_dir.to_string_lossy()), true);
  let store = unsafe { WKContentRuleListStore::storeWithURL(Some(&url), mtm) }.ok_or("cannot open the content rule store")?;
  let result: Rc<RefCell<Option<Result<Retained<WKContentRuleList>, String>>>> = Rc::new(RefCell::new(None));
  let sink = result.clone();
  let handler = RcBlock::new(move |list: *mut WKContentRuleList, error: *mut NSError| {
    let r = match unsafe { Retained::retain(list) } {
      Some(list) => Ok(list),
      None => Err(unsafe { error.as_ref() }.map(|e| e.localizedDescription().to_string()).unwrap_or_else(|| "unknown error".into())),
    };
    *sink.borrow_mut() = Some(r);
  });
  unsafe {
    store.compileContentRuleListForIdentifier_encodedContentRuleList_completionHandler(
      Some(&NSString::from_str("dwv-offline")),
      Some(&NSString::from_str(&offline_rules_json())),
      Some(&handler),
    );
  }
  // The completion handler runs on the main queue: spin the run loop until
  // it has (the event loop does not exist yet).
  let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
  let run_loop = NSRunLoop::currentRunLoop();
  while result.borrow().is_none() {
    if std::time::Instant::now() > deadline {
      return Err("the offline content rule list did not compile within 30 s".into());
    }
    let until = NSDate::dateWithTimeIntervalSinceNow(0.05);
    unsafe { run_loop.runMode_beforeDate(NSDefaultRunLoopMode, &until) };
  }
  let list = result.borrow_mut().take().expect("set above").map_err(|e| format!("the offline content rule list did not compile: {e}"))?;
  OFFLINE_RULES.with(|r| *r.borrow_mut() = Some(list));
  Ok(())
}

/// Deletes the temporary rule store (see [prepare_offline]).
pub fn cleanup() {
  if let Some(d) = RULE_STORE.with(|s| s.borrow_mut().take()) {
    let _ = std::fs::remove_dir_all(d);
  }
}

/// The navigation delegate installs itself in [install].
pub fn configure_builder<'a>(
  b: WebViewBuilder<'a>,
  _sid: &str,
  _proxy: EventLoopProxy<UserEvent>,
  _offline: bool,
) -> WebViewBuilder<'a> {
  b
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

pub struct NavDelegateIvars {
  shared: Rc<RefCell<Shared>>,
  proxy: EventLoopProxy<UserEvent>,
  /// wry's delegate; `didCommitNavigation` is forwarded to it.
  inner: Option<Retained<ProtocolObject<dyn WKNavigationDelegate>>>,
  /// The current main-frame navigation (retained, so its address identifies
  /// it while it is current).
  current: RefCell<Option<Retained<WKNavigation>>>,
  /// HTTP status of the current navigation's main document.
  status: Cell<Option<i64>>,
}

impl NavDelegateIvars {
  fn is_current(&self, nav: Option<&WKNavigation>) -> bool {
    if self.shared.borrow().awaiting_start {
      return false;
    }
    match (self.current.borrow().as_deref(), nav) {
      (Some(c), Some(n)) => std::ptr::eq(c, n),
      _ => false,
    }
  }

  fn finish(&self, webview: &WKWebView, nav: Option<&WKNavigation>, error: Option<&NSError>) {
    if !self.is_current(nav) {
      return;
    }
    *self.current.borrow_mut() = None;
    let session = self.shared.borrow().id.clone();
    let url = unsafe { webview.URL() }.and_then(|u| u.absoluteString()).map(|s| s.to_string()).unwrap_or_default();
    // WebKit refuses a redirect to `file:` itself, before any policy
    // decision, as "no permission to read the file" (NSURLErrorDomain
    // -1102); treat it as the scheme-policy refusal (fail closed).
    if let Some(e) = error {
      if e.code() == -1102 && e.domain().to_string() == "NSURLErrorDomain" {
        let _ = self.proxy.send_event(UserEvent::RedirectRejected {
          session: session.clone(),
          location: "a redirect target the engine refused (file access)".into(),
        });
      }
    }
    let event = match error {
      None => UserEvent::NavFinished { session, url, ok: true, status: self.status.get(), error: None },
      Some(e) => UserEvent::NavFinished {
        session,
        url,
        ok: false,
        status: self.status.get(),
        error: Some(format!("{} ({} {})", e.localizedDescription(), e.domain(), e.code())),
      },
    };
    let _ = self.proxy.send_event(event);
  }
}

define_class!(
  #[unsafe(super(NSObject))]
  #[thread_kind = MainThreadOnly]
  #[ivars = NavDelegateIvars]
  struct NavDelegate;

  unsafe impl NSObjectProtocol for NavDelegate {}

  unsafe impl WKNavigationDelegate for NavDelegate {
    #[unsafe(method(webView:decidePolicyForNavigationAction:decisionHandler:))]
    fn decide_action(&self, _webview: &WKWebView, action: &WKNavigationAction, handler: &Block<dyn Fn(WKNavigationActionPolicy)>) {
      let ivars = self.ivars();
      let uri = unsafe { action.request().URL() }.and_then(|u| u.absoluteString()).map(|s| s.to_string());
      let Some(uri) = uri else {
        handler.call((WKNavigationActionPolicy::Cancel,));
        return;
      };
      // A navigation without a target frame would open a new window.
      let main_frame = unsafe { action.targetFrame() }.map(|f| unsafe { f.isMainFrame() });
      let allowed = policy::is_navigable(&uri) && main_frame.is_some();
      if main_frame == Some(true) {
        let session = ivars.shared.borrow().id.clone();
        let _ = ivars.proxy.send_event(UserEvent::NavStarting { session: session.clone(), uri: uri.clone(), rejected: !allowed });
        if !allowed && ivars.current.borrow().is_none() {
          // A refused navigation that never started reports no completion.
          let _ = ivars.proxy.send_event(UserEvent::NavFinished {
            session,
            url: uri,
            ok: false,
            status: None,
            error: Some("refused by scheme policy".into()),
          });
        }
      }
      handler.call((if allowed { WKNavigationActionPolicy::Allow } else { WKNavigationActionPolicy::Cancel },));
    }

    #[unsafe(method(webView:decidePolicyForNavigationResponse:decisionHandler:))]
    fn decide_response(&self, _webview: &WKWebView, response: &WKNavigationResponse, handler: &Block<dyn Fn(WKNavigationResponsePolicy)>) {
      unsafe {
        if response.isForMainFrame() {
          let status = response.response().downcast::<NSHTTPURLResponse>().ok().map(|r| r.statusCode() as i64);
          self.ivars().status.set(status);
        }
      }
      handler.call((WKNavigationResponsePolicy::Allow,));
    }

    #[unsafe(method(webView:didStartProvisionalNavigation:))]
    fn did_start(&self, _webview: &WKWebView, nav: Option<&WKNavigation>) {
      let ivars = self.ivars();
      ivars.shared.borrow_mut().awaiting_start = false;
      *ivars.current.borrow_mut() = nav.map(|n| n.retain());
      ivars.status.set(None);
    }

    #[unsafe(method(webView:didCommitNavigation:))]
    fn did_commit(&self, webview: &WKWebView, nav: Option<&WKNavigation>) {
      let ivars = self.ivars();
      let session = ivars.shared.borrow().id.clone();
      let _ = ivars.proxy.send_event(UserEvent::Committed { session });
      if let (Some(inner), Some(nav)) = (self.ivars().inner.as_ref(), nav) {
        unsafe {
          let _: () = msg_send![&**inner, webView: webview, didCommitNavigation: nav];
        }
      }
    }

    #[unsafe(method(webView:didFinishNavigation:))]
    fn did_finish(&self, webview: &WKWebView, nav: Option<&WKNavigation>) {
      self.ivars().finish(webview, nav, None);
    }

    #[unsafe(method(webView:didFailProvisionalNavigation:withError:))]
    fn did_fail_provisional(&self, webview: &WKWebView, nav: Option<&WKNavigation>, error: &NSError) {
      self.ivars().finish(webview, nav, Some(error));
    }

    #[unsafe(method(webView:didFailNavigation:withError:))]
    fn did_fail(&self, webview: &WKWebView, nav: Option<&WKNavigation>, error: &NSError) {
      self.ivars().finish(webview, nav, Some(error));
    }
  }
);

/// Keeps the session's delegates registered; removes the script message
/// handler (the controller retains it) when the session ends.
pub struct Native {
  controller: Retained<WKUserContentController>,
  _handler: Retained<HostHandler>,
  /// `WKWebView.navigationDelegate` is weak: this keeps the delegate alive.
  _nav: Retained<NavDelegate>,
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
  let handler = mtm.alloc::<HostHandler>().set_ivars(HostHandlerIvars { session, proxy: proxy.clone() });
  let handler: Retained<HostHandler> = unsafe { msg_send![super(handler), init] };
  let controller = webview.manager();
  unsafe {
    controller.addScriptMessageHandler_name(ProtocolObject::from_ref(&*handler), &NSString::from_str(HOST_HANDLER));
  }
  let offline = shared.borrow().offline;
  if offline {
    let rules = OFFLINE_RULES.with(|r| r.borrow().clone()).ok_or("offline replay has no compiled content rule list")?;
    unsafe { controller.addContentRuleList(&rules) };
  }
  let wk = webview.webview();
  keep_hidden_pages_running(&wk);
  let inner = unsafe { wk.navigationDelegate() };
  let nav = mtm.alloc::<NavDelegate>().set_ivars(NavDelegateIvars {
    shared,
    proxy,
    inner,
    current: RefCell::new(None),
    status: Cell::new(None),
  });
  let nav: Retained<NavDelegate> = unsafe { msg_send![super(nav), init] };
  unsafe { wk.setNavigationDelegate(Some(ProtocolObject::from_ref(&*nav))) };
  Ok(Native { controller, _handler: handler, _nav: nav })
}

/// The helper's windows stay hidden unless an interaction shows them, and
/// WebKit throttles a hidden page's timers (measured: a 10 s `setTimeout`
/// took over 30 s) and may suspend its web process, so in-page timeouts such
/// as a source's challenge or capture wait would outlast the operation
/// deadline. WKPreferences' hidden-page timer throttling and visibility-based
/// process suppression switches (WebKit SPI, present since macOS 10.12) are
/// turned off where the selectors exist; otherwise nothing is changed.
fn keep_hidden_pages_running(wk: &WKWebView) {
  use objc2::{runtime::Bool, sel};
  unsafe {
    let prefs = wk.configuration().preferences();
    if prefs.respondsToSelector(sel!(_setHiddenPageDOMTimerThrottlingEnabled:)) {
      let _: () = msg_send![&*prefs, _setHiddenPageDOMTimerThrottlingEnabled: Bool::NO];
    }
    if prefs.respondsToSelector(sel!(_setPageVisibilityBasedProcessSuppressionEnabled:)) {
      let _: () = msg_send![&*prefs, _setPageVisibilityBasedProcessSuppressionEnabled: Bool::NO];
    }
  }
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

/// Cookies sent to [url]. wry's `cookies_for_url` on WKWebView compares the
/// cookie domain with the URL's DNS name only (never an IP host) and ignores
/// the path, so the session's whole store is filtered here.
pub fn cookies_for_url(webview: &WebView, url: &str) -> Result<Vec<wry::cookie::Cookie<'static>>, String> {
  let all = webview.cookies().map_err(|e| e.to_string())?;
  Ok(
    all
      .into_iter()
      .filter(|c| policy::cookie_matches(url, c.domain().unwrap_or(""), c.path().unwrap_or("/"), c.secure().unwrap_or(false)))
      .collect(),
  )
}

/// The non-persistent store is discarded with the WebView; nothing persists.
pub fn clear_data(_webview: &WebView) -> Result<(), String> {
  Ok(())
}
