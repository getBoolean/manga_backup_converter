//! WebView2 (Windows). Uses the COM API directly for what wry lacks.
//!
//! Isolation: every session is an InPrivate WebView2 profile with its own
//! profile name, so cookies and web storage are neither shared between
//! sessions nor written to disk. The environment's user data folder is a
//! per-process directory under `--data-root`; the helper wipes stale ones at
//! start-up and its own at exit (KTD20).

use std::{
  cell::RefCell,
  collections::HashMap,
  path::Path,
  rc::Rc,
};

use tao::{event_loop::EventLoopProxy, window::Window};
use webview2_com::{
  take_pwstr, AddScriptToExecuteOnDocumentCreatedCompletedHandler, ClearBrowsingDataCompletedHandler,
  FrameCreatedEventHandler, FrameWebMessageReceivedEventHandler,
  Microsoft::Web::WebView2::Win32::*, NavigationCompletedEventHandler, NavigationStartingEventHandler,
  WebMessageReceivedEventHandler, WebResourceRequestedEventHandler, WebResourceResponseReceivedEventHandler,
  WebResourceResponseViewGetContentCompletedHandler,
};
use windows::{
  core::{Interface, BOOL, HSTRING, PWSTR},
  Win32::System::Com::{IStream, STREAM_SEEK_SET},
  Win32::UI::Shell::SHCreateMemStream,
};
use wry::{WebContext, WebView, WebViewBuilder, WebViewBuilderExtWindows, WebViewExtWindows};

use super::{Answer, Caps, ReplacementResponse};
use crate::{policy, ExchangeEvent, InterceptMode, RequestEvent, Shared, UserEvent, MAX_FORWARDED_BODY_BYTES, MAX_RECORDED_BODY_BYTES};

pub const ENGINE: &str = "webview2";

/// Whether the message source URI identifies the posting frame: the
/// WebView's `WebMessageReceived` reports the top-level document's URL, and
/// the helper forwards child-frame messages with the frame's own URL.
pub const IPC_URI_IS_POSTING_FRAME: bool = true;

/// The engine's post function, captured at document start: WebView2's
/// `window.chrome.webview.postMessage`, received by `WebMessageReceived`
/// (and per-frame `WebMessageReceived` for child frames).
pub const POST_EXPR: &str =
  "(function(){var w=window.chrome&&window.chrome.webview;return w&&typeof w.postMessage==='function'?w.postMessage.bind(w):null})()";

pub static CAPS: Caps = Caps {
  request_observe: "all",
  request_replace: true,
  status_codes: true,
  navigation_failures: true,
  storage: "ephemeral-per-session (InPrivate profile per session)",
  offline_enforced: true,
  record: true,
  browser: &[
    ("pageStartScripts", None),
    ("observeNavigations", None),
    ("observeSubresources", None),
    ("observeRequestHeaders", None),
    ("observeClientHints", None),
    ("observeRequestBodies", None),
    ("replaceRequests", None),
    ("scriptErrors", None),
  ],
};

/// Asks the window to close the way the title bar's close button does: a
/// posted `WM_CLOSE` reaches the event loop as `CloseRequested` (test hook).
pub fn request_window_close(window: &Window) -> Result<(), String> {
  use tao::platform::windows::WindowExtWindows;
  use windows::Win32::{
    Foundation::{HWND, LPARAM, WPARAM},
    UI::WindowsAndMessaging::{PostMessageW, WM_CLOSE},
  };
  let hwnd = HWND(window.hwnd() as *mut core::ffi::c_void);
  unsafe { PostMessageW(Some(hwnd), WM_CLOSE, WPARAM(0), LPARAM(0)) }.map_err(|e| e.to_string())
}

pub fn display_missing() -> Option<String> {
  None
}

/// Puts the helper in a kill-on-close job object, so the WebView2 processes
/// it starts (which inherit the job) end with it, even when it is killed.
/// The handle is never closed; the system closes it when the helper exits.
/// Failure (for example a parent job that forbids nesting) only loses that
/// guarantee.
///
/// Measured on WebView2 157: after a kill, the browser process can still
/// stay in termination for 1-110 s (cause not identified), holding the data
/// directory; the client's wipe retry budget (`wipe` `retryMs`) covers that.
pub fn contain_child_processes() -> Result<(), String> {
  use windows::Win32::{
    Foundation::{SetHandleInformation, HANDLE_FLAGS, HANDLE_FLAG_INHERIT},
    System::{
      Console::{GetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE},
      JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
      },
      Threading::GetCurrentProcess,
    },
  };
  unsafe {
    // The browser processes need no copy of the helper's stdio pipes: the
    // client's reads reach end-of-file when the helper itself exits.
    for std in [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE] {
      if let Ok(h) = GetStdHandle(std) {
        if !h.is_invalid() {
          let _ = SetHandleInformation(h, HANDLE_FLAG_INHERIT.0, HANDLE_FLAGS(0));
        }
      }
    }
    let job = CreateJobObjectW(None, windows::core::PCWSTR::null()).map_err(|e| e.to_string())?;
    let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
    info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(
      job,
      JobObjectExtendedLimitInformation,
      (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
      std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
    )
    .map_err(|e| e.to_string())?;
    AssignProcessToJobObject(job, GetCurrentProcess()).map_err(|e| e.to_string())
  }
}

pub fn web_context(dir: Option<&Path>) -> Option<WebContext> {
  Some(WebContext::new(dir.map(Path::to_path_buf)))
}

fn profile_name(sid: &str) -> String {
  let clean: String = sid.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_').take(48).collect();
  format!("dwv-{clean}")
}

/// wry's default WebView2 arguments; passing our own replaces them.
const WRY_DEFAULT_ARGS: &str = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection";

pub fn configure_builder<'a>(
  b: WebViewBuilder<'a>,
  sid: &str,
  _proxy: EventLoopProxy<UserEvent>,
  offline: bool,
) -> WebViewBuilder<'a> {
  let b = b.with_profile_name(profile_name(sid));
  if offline {
    // Backstop for traffic WebResourceRequested never sees (WebSockets,
    // some service-worker fetches): no host other than loopback resolves,
    // and no proxy is used (L3): a system proxy on loopback is excluded from
    // the resolver rules and would otherwise resolve and fetch every host
    // itself. Every session of a helper uses the same arguments, as WebView2
    // requires for a shared data directory.
    b.with_additional_browser_args(offline_browser_args())
  } else {
    b
  }
}

/// WebView2 arguments of an offline helper.
pub fn offline_browser_args() -> String {
  format!("{WRY_DEFAULT_ARGS} --no-proxy-server --host-resolver-rules=\"MAP * ~NOTFOUND, EXCLUDE 127.0.0.1, EXCLUDE localhost\"")
}

pub fn build(b: WebViewBuilder<'_>, window: &Window) -> wry::Result<WebView> {
  b.build(window)
}

/// Keeps the session's native state alive (event tokens are dropped with
/// the WebView itself).
pub struct Native;

struct Deferred {
  args: ICoreWebView2WebResourceRequestedEventArgs,
  deferral: ICoreWebView2Deferral,
  env: ICoreWebView2Environment,
  offline: bool,
  url: String,
}

thread_local! {
  static DEFERRED: RefCell<HashMap<u64, Deferred>> = RefCell::new(HashMap::new());
  static NEXT_RID: RefCell<u64> = const { RefCell::new(0) };
}

fn pwstr(f: impl FnOnce(*mut PWSTR) -> windows::core::Result<()>) -> String {
  let mut p = PWSTR::null();
  match f(&mut p) {
    Ok(()) => take_pwstr(p),
    Err(_) => String::new(),
  }
}

fn make_response(env: &ICoreWebView2Environment, r: &ReplacementResponse) -> windows::core::Result<ICoreWebView2WebResourceResponse> {
  let headers: String = r.headers.iter().map(|(k, v)| format!("{k}: {v}\r\n")).collect();
  unsafe {
    let stream = SHCreateMemStream(Some(&r.body));
    env.CreateWebResourceResponse(stream.as_ref(), r.status as i32, &HSTRING::from(r.reason.as_str()), &HSTRING::from(headers))
  }
}

thread_local! {
  /// URLs answered with the offline block response: a main document among
  /// them is a failed navigation even though WebView2 sees an HTTP status.
  static OFFLINE_BLOCKED: RefCell<std::collections::HashSet<String>> = RefCell::new(std::collections::HashSet::new());
}

fn blocked(url: &str) -> ReplacementResponse {
  eprintln!("[helper] offline: blocked {url}");
  OFFLINE_BLOCKED.with(|b| b.borrow_mut().insert(url.to_string()));
  ReplacementResponse {
    status: 502,
    reason: "Blocked by offline replay".into(),
    headers: vec![("Content-Type".into(), "text/plain".into()), ("X-Desktop-Webview-Blocked".into(), "1".into())],
    body: b"blocked by desktop_webview offline replay".to_vec(),
  }
}

fn context_name(c: COREWEBVIEW2_WEB_RESOURCE_CONTEXT) -> &'static str {
  match c {
    COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT => "document",
    COREWEBVIEW2_WEB_RESOURCE_CONTEXT_SCRIPT => "script",
    COREWEBVIEW2_WEB_RESOURCE_CONTEXT_FETCH => "fetch",
    COREWEBVIEW2_WEB_RESOURCE_CONTEXT_XML_HTTP_REQUEST => "xhr",
    COREWEBVIEW2_WEB_RESOURCE_CONTEXT_IMAGE => "image",
    COREWEBVIEW2_WEB_RESOURCE_CONTEXT_STYLESHEET => "stylesheet",
    _ => "other",
  }
}

fn request_headers(req: &ICoreWebView2WebResourceRequest) -> Vec<(String, String)> {
  match unsafe { req.Headers().and_then(|h| h.GetIterator()) } {
    Ok(it) => collect_headers(&it),
    Err(_) => Vec::new(),
  }
}

/// Every header of a collection, in order (repeated names kept).
fn collect_headers(it: &ICoreWebView2HttpHeadersCollectionIterator) -> Vec<(String, String)> {
  let mut out = Vec::new();
  unsafe {
    loop {
      let mut has = BOOL::default();
      if it.HasCurrentHeader(&mut has).is_err() || !has.as_bool() {
        break;
      }
      let (mut n, mut v) = (PWSTR::null(), PWSTR::null());
      if it.GetCurrentHeader(&mut n, &mut v).is_ok() {
        out.push((take_pwstr(n), take_pwstr(v)));
      }
      let mut next = BOOL::default();
      if it.MoveNext(&mut next).is_err() || !next.as_bool() {
        break;
      }
    }
  }
  out
}

pub fn install(webview: &WebView, shared: Rc<RefCell<Shared>>, proxy: EventLoopProxy<UserEvent>) -> Result<Native, String> {
  let core = webview.webview();
  let env = webview.environment();
  let sid = shared.borrow().id.clone();
  let e = |e: windows::core::Error| e.to_string();
  let mut token = 0i64;
  unsafe {
    // Main-frame navigations: enforce the scheme policy on every hop.
    let (p, s, sh) = (proxy.clone(), sid.clone(), shared.clone());
    core
      .add_NavigationStarting(
        &NavigationStartingEventHandler::create(Box::new(move |_, args| {
          let Some(args) = args else { return Ok(()) };
          let uri = pwstr(|p| args.Uri(p));
          let mut nav_id = 0u64;
          let _ = args.NavigationId(&mut nav_id);
          let rejected = !policy::is_navigable(&uri);
          if rejected {
            args.SetCancel(true)?;
          }
          {
            let mut shared = sh.borrow_mut();
            let redirect = shared.nav_id == Some(nav_id);
            if !redirect {
              shared.awaiting_start = false;
              shared.nav_id = Some(nav_id);
              shared.main_frame_pending.clear();
            }
            if !rejected {
              // NavigationStarting precedes the document's
              // WebResourceRequested; that request is the main frame's.
              shared.main_frame_pending.push(uri.clone());
            }
          }
          let _ = p.send_event(UserEvent::NavStarting { session: s.clone(), uri, rejected });
          Ok(())
        })),
        &mut token,
      )
      .map_err(e)?;

    let (p, s, sh) = (proxy.clone(), sid.clone(), shared.clone());
    core
      .add_NavigationCompleted(
        &NavigationCompletedEventHandler::create(Box::new(move |sender, args| {
          let Some(args) = args else { return Ok(()) };
          let mut nav_id = 0u64;
          let _ = args.NavigationId(&mut nav_id);
          // A completion for an older navigation (superseded or cancelled)
          // must not settle the current load.
          {
            let shared = sh.borrow();
            if shared.awaiting_start || shared.nav_id != Some(nav_id) {
              return Ok(());
            }
          }
          let mut ok = BOOL::default();
          let _ = args.IsSuccess(&mut ok);
          let mut status_code = 0i32;
          let status = args
            .cast::<ICoreWebView2NavigationCompletedEventArgs2>()
            .ok()
            .and_then(|a2| a2.HttpStatusCode(&mut status_code).ok())
            .map(|_| status_code as i64)
            .filter(|c| *c > 0);
          let mut err = COREWEBVIEW2_WEB_ERROR_STATUS::default();
          let _ = args.WebErrorStatus(&mut err);
          let url = sender.map(|w| pwstr(|p| w.Source(p))).unwrap_or_default();
          // Chromium refuses a redirect to `file:` (and other unsafe schemes)
          // before any response event, reporting only REDIRECT_FAILED; treat
          // it as the scheme-policy refusal (fail closed). Redirect loops
          // share this status.
          if !ok.as_bool() && err == COREWEBVIEW2_WEB_ERROR_STATUS_REDIRECT_FAILED {
            let _ = p.send_event(UserEvent::RedirectRejected {
              session: s.clone(),
              location: "a redirect target the engine refused (unsafe scheme or redirect loop)".into(),
            });
          }
          // WebView2 reports an HTTP error page (4xx/5xx) as IsSuccess=false
          // with WebErrorStatus UNKNOWN; the document still loaded, so a
          // received HTTP status counts as a completed load (same as WebKit).
          let was_blocked = OFFLINE_BLOCKED.with(|b| b.borrow_mut().remove(&url));
          let loaded = !was_blocked && (ok.as_bool() || status.is_some());
          let _ = p.send_event(UserEvent::NavFinished {
            session: s.clone(),
            url,
            ok: loaded,
            status,
            error: (!loaded).then(|| if was_blocked { "blocked by offline replay".to_string() } else { format!("WebView2 web error status {}", err.0) }),
          });
          Ok(())
        })),
        &mut token,
      )
      .map_err(e)?;

    // Every request: loadData substitution, observe/replace tiers, and
    // offline replay's deny-by-default.
    // All request source kinds where the runtime supports them, so
    // requests from cross-origin iframes and workers are seen as well.
    match core.cast::<ICoreWebView2_22>() {
      Ok(core22) => core22
        .AddWebResourceRequestedFilterWithRequestSourceKinds(
          &HSTRING::from("*"),
          COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL,
          COREWEBVIEW2_WEB_RESOURCE_REQUEST_SOURCE_KINDS_ALL,
        )
        .map_err(e)?,
      Err(_) => core
        .AddWebResourceRequestedFilter(&HSTRING::from("*"), COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL)
        .map_err(e)?,
    }

    // Page messages (the top-level document posts here).
    let (p, s) = (proxy.clone(), sid.clone());
    core
      .add_WebMessageReceived(
        &WebMessageReceivedEventHandler::create(Box::new(move |_, args| {
          let Some(args) = args else { return Ok(()) };
          let uri = pwstr(|u| args.Source(u));
          let body = pwstr(|b| args.TryGetWebMessageAsString(b));
          let _ = p.send_event(UserEvent::Ipc { session: s.clone(), uri, body });
          Ok(())
        })),
        &mut token,
      )
      .map_err(e)?;

    // Child frames post to per-frame message events, not the WebView's.
    // Forward them with the frame's document URL; the origin rule then
    // keeps only same-origin frames (nested frames are not subscribed).
    if let Ok(core4) = core.cast::<ICoreWebView2_4>() {
      let (p, s) = (proxy.clone(), sid.clone());
      core4
        .add_FrameCreated(
          &FrameCreatedEventHandler::create(Box::new(move |_, args| {
            let Some(args) = args else { return Ok(()) };
            let Ok(frame2) = args.Frame().and_then(|f| f.cast::<ICoreWebView2Frame2>()) else { return Ok(()) };
            let (p, s) = (p.clone(), s.clone());
            let mut frame_token = 0i64;
            frame2.add_WebMessageReceived(
              &FrameWebMessageReceivedEventHandler::create(Box::new(move |_, args| {
                let Some(args) = args else { return Ok(()) };
                let uri = pwstr(|u| args.Source(u));
                let body = pwstr(|b| args.TryGetWebMessageAsString(b));
                let _ = p.send_event(UserEvent::Ipc { session: s.clone(), uri, body });
                Ok(())
              })),
              &mut frame_token,
            )?;
            Ok(())
          })),
          &mut token,
        )
        .map_err(e)?;
    }
    let (p, s, sh, env2) = (proxy.clone(), sid.clone(), shared.clone(), env.clone());
    core
      .add_WebResourceRequested(
        &WebResourceRequestedEventHandler::create(Box::new(move |_, args| {
          let Some(args) = args else { return Ok(()) };
          let req = args.Request()?;
          let url = pwstr(|p| req.Uri(p));
          let method = pwstr(|p| req.Method(p));
          let mut ctx = COREWEBVIEW2_WEB_RESOURCE_CONTEXT::default();
          let _ = args.ResourceContext(&mut ctx);

          let (substitute, mode, offline, main_frame) = {
            let mut shared = sh.borrow_mut();
            let main_frame = ctx == COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT
              && match shared.main_frame_pending.iter().position(|u| *u == url) {
                Some(i) => {
                  shared.main_frame_pending.remove(i);
                  true
                }
                None => false,
              };
            let substitute = match &shared.load_data {
              Some((base, _)) if ctx == COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT && *base == url => shared.load_data.take().map(|(_, html)| html),
              _ => None,
            };
            (substitute, shared.mode, shared.offline, main_frame)
          };
          if let Some(html) = substitute {
            let r = ReplacementResponse {
              status: 200,
              reason: "OK".into(),
              headers: vec![("Content-Type".into(), "text/html; charset=utf-8".into())],
              body: html.into_bytes(),
            };
            args.SetResponse(&make_response(&env2, &r)?)?;
            return Ok(());
          }
          let deny = offline && !policy::is_loopback(&url) && url != "about:blank";
          let event = |rid: Option<u64>| {
            let headers = request_headers(&req);
            let (body, body_omitted) = request_body(&req);
            RequestEvent {
              session: s.clone(),
              rid,
              url: url.clone(),
              method: method.clone(),
              headers,
              body,
              body_omitted,
              main_frame,
              redirect: false,
              context: context_name(ctx).into(),
            }
          };
          match mode {
            InterceptMode::Replace => {
              let rid = NEXT_RID.with(|n| {
                *n.borrow_mut() += 1;
                *n.borrow()
              });
              let ev = event(Some(rid));
              let deferral = args.GetDeferral()?;
              DEFERRED.with(|d| {
                d.borrow_mut().insert(rid, Deferred { args: args.clone(), deferral, env: env2.clone(), offline: deny, url: url.clone() })
              });
              let _ = p.send_event(UserEvent::Request(ev));
            }
            InterceptMode::Observe => {
              let _ = p.send_event(UserEvent::Request(event(None)));
              if deny {
                args.SetResponse(&make_response(&env2, &blocked(&url))?)?;
              }
            }
            InterceptMode::None => {
              if deny {
                args.SetResponse(&make_response(&env2, &blocked(&url))?)?;
              }
            }
          }
          Ok(())
        })),
        &mut token,
      )
      .map_err(e)?;

    // Redirect targets: Chromium refuses a 3xx to `file:` itself, so read the
    // Location header to report the policy failure by name.
    if let Ok(core2) = core.cast::<ICoreWebView2_2>() {
      let (p, s, sh) = (proxy.clone(), sid.clone(), shared.clone());
      core2
        .add_WebResourceResponseReceived(
          &WebResourceResponseReceivedEventHandler::create(Box::new(move |_, args| {
            let Some(args) = args else { return Ok(()) };
            if sh.borrow().record {
              record_exchange(&args, &s, &p);
            }
            let url = args.Request().map(|r| pwstr(|p| r.Uri(p))).unwrap_or_default();
            if !sh.borrow().load_chain.iter().any(|u| *u == url) {
              return Ok(());
            }
            let Ok(resp) = args.Response() else { return Ok(()) };
            let mut status = 0i32;
            let _ = resp.StatusCode(&mut status);
            if !(300..400).contains(&status) {
              return Ok(());
            }
            let location = resp.Headers().map(|h| pwstr(|p| h.GetHeader(&HSTRING::from("Location"), p))).unwrap_or_default();
            let absolute = location.split(['/', '?', '#']).next().is_some_and(|head| head.contains(':'));
            if absolute && !policy::is_navigable(&location) {
              let _ = p.send_event(UserEvent::RedirectRejected { session: s.clone(), location });
            }
            Ok(())
          })),
          &mut token,
        )
        .map_err(e)?;
    }
  }
  Ok(Native)
}

/// `--record`: reports the response with its request and decoded body as an
/// `exchange` event. The body arrives asynchronously (`GetContent`); a
/// response without one (a redirect hop, a 204) is reported without a body.
fn record_exchange(args: &ICoreWebView2WebResourceResponseReceivedEventArgs, session: &str, proxy: &EventLoopProxy<UserEvent>) {
  let (Ok(req), Ok(resp)) = (unsafe { args.Request() }, unsafe { args.Response() }) else { return };
  let url = pwstr(|p| unsafe { req.Uri(p) });
  let method = pwstr(|p| unsafe { req.Method(p) });
  let (request_body, request_body_omitted) = request_body(&req);
  let mut status = 0i32;
  let _ = unsafe { resp.StatusCode(&mut status) };
  let headers = match unsafe { resp.Headers().and_then(|h| h.GetIterator()) } {
    Ok(it) => collect_headers(&it),
    Err(_) => Vec::new(),
  };
  let event = ExchangeEvent {
    session: session.to_string(),
    method,
    url,
    request_body,
    request_body_omitted,
    status,
    headers,
    body: None,
    body_omitted: false,
  };
  let p = proxy.clone();
  let pending = std::rc::Rc::new(RefCell::new(Some(event)));
  let fallback = pending.clone();
  let handler = WebResourceResponseViewGetContentCompletedHandler::create(Box::new(move |hr, stream| {
    let Some(mut event) = pending.borrow_mut().take() else { return Ok(()) };
    match (hr.is_ok(), stream) {
      (true, Some(stream)) => match read_stream(&stream, MAX_RECORDED_BODY_BYTES) {
        Some(body) => event.body = Some(body),
        None => event.body_omitted = true,
      },
      // No content: the engine keeps none for this response.
      (true, None) => {}
      (false, _) => event.body_omitted = true,
    }
    let _ = p.send_event(UserEvent::Exchange(event));
    Ok(())
  }));
  if unsafe { resp.GetContent(&handler) }.is_err() {
    if let Some(mut event) = fallback.borrow_mut().take() {
      event.body_omitted = true;
      let _ = proxy.send_event(UserEvent::Exchange(event));
    }
  }
}

/// Reads a whole stream, or `None` when it is unreadable or larger than `cap`.
fn read_stream(stream: &IStream, cap: usize) -> Option<Vec<u8>> {
  let mut body = Vec::new();
  let mut chunk = vec![0u8; 64 * 1024];
  loop {
    let mut read = 0u32;
    let hr = unsafe { stream.Read(chunk.as_mut_ptr().cast(), chunk.len() as u32, Some(&mut read)) };
    if hr.is_err() {
      return None;
    }
    if read == 0 {
      return Some(body);
    }
    body.extend_from_slice(&chunk[..read as usize]);
    if body.len() > cap {
      return None;
    }
  }
}

/// Where a failed held request is sent instead of its own URL: port 1 is on
/// Chromium's restricted-port list, so the network stack refuses it
/// (`ERR_UNSAFE_PORT`) without connecting, and the page sees a network
/// error. WebView2 has no call that aborts a request.
const FAIL_URI: &str = "http://127.0.0.1:1/desktop-webview-failed-request";

/// Answers a held request (replace tier). [Answer::Proceed] lets it proceed,
/// unless the helper runs offline, where unanswered requests are blocked.
/// A replacement or block that cannot be built or set fails the request
/// (L3): it never falls through to the original request.
pub fn respond(rid: u64, answer: Answer) {
  let Some(d) = DEFERRED.with(|m| m.borrow_mut().remove(&rid)) else { return };
  unsafe {
    match answer {
      Answer::Replace(r) => {
        if let Err(e) = set_response(&d, &r) {
          fail_request(&d, &format!("cannot set the replacement response: {e}"));
        }
      }
      Answer::Proceed if d.offline => {
        if let Err(e) = set_response(&d, &blocked(&d.url)) {
          fail_request(&d, &format!("cannot set the offline block response: {e}"));
        }
      }
      Answer::Proceed => {}
      Answer::Fail(reason) => fail_request(&d, &reason),
    }
    let _ = d.deferral.Complete();
  }
}

unsafe fn set_response(d: &Deferred, r: &ReplacementResponse) -> windows::core::Result<()> {
  let resp = make_response(&d.env, r)?;
  unsafe { d.args.SetResponse(&resp) }
}

/// Fails a held request: rewritten to [FAIL_URI], or answered 502 when the
/// rewrite is refused. Never lets the original request go out.
unsafe fn fail_request(d: &Deferred, reason: &str) {
  eprintln!("[helper] failing held request {}: {reason}", d.url);
  let rewritten = unsafe { d.args.Request() }.and_then(|req| unsafe { req.SetUri(&HSTRING::from(FAIL_URI)) });
  if let Err(e) = rewritten {
    eprintln!("[helper] cannot rewrite failed request ({e}); answering 502");
    let r = ReplacementResponse {
      status: 502,
      reason: "Request failed".into(),
      headers: vec![("Content-Type".into(), "text/plain".into())],
      body: format!("desktop_webview failed this request: {reason}").into_bytes(),
    };
    if let Err(e) = unsafe { set_response(d, &r) } {
      eprintln!("[helper] cannot answer the failed request either ({e})");
    }
  }
}

/// The request body (WebView2 `Request.Content`), at most
/// [MAX_FORWARDED_BODY_BYTES], and whether a body was omitted. The stream is
/// rewound after reading so the upload is unchanged. A body is omitted only
/// when the stream cannot be read or exceeds the cap.
///
/// Measured on WebView2 157: `Content` carries the body of every page body
/// type (string, Blob with and without a type, FormData with a file,
/// URLSearchParams, Uint8Array, XHR), and is absent only for requests with
/// no body, including a bodiless POST with a `Content-Type` header. So a
/// missing stream means no body.
fn request_body(req: &ICoreWebView2WebResourceRequest) -> (Option<Vec<u8>>, bool) {
  let stream: Option<IStream> = unsafe { req.Content().ok() };
  let Some(stream) = stream else { return (None, false) };
  let mut body = Vec::new();
  let mut chunk = vec![0u8; 64 * 1024];
  let readable = loop {
    let mut read = 0u32;
    let hr = unsafe { stream.Read(chunk.as_mut_ptr().cast(), chunk.len() as u32, Some(&mut read)) };
    if hr.is_err() {
      break false;
    }
    if read == 0 {
      break true;
    }
    body.extend_from_slice(&chunk[..read as usize]);
    if body.len() > MAX_FORWARDED_BODY_BYTES {
      break false;
    }
  };
  unsafe {
    let _ = stream.Seek(0, STREAM_SEEK_SET, None);
  }
  if !readable {
    return (None, true);
  }
  ((!body.is_empty()).then_some(body), false)
}

pub fn load_data(webview: &WebView, shared: &Rc<RefCell<Shared>>, html: &str, base: &str) -> Result<(), String> {
  // Navigate to the base URL and answer that main-document request with the
  // HTML, so the document's URL and origin are the base URL (Android's
  // `loadDataWithBaseURL`).
  shared.borrow_mut().load_data = Some((base.to_string(), html.to_string()));
  webview.load_url(base).map_err(|e| e.to_string())
}

pub fn stop(webview: &WebView) {
  unsafe {
    let _ = webview.webview().Stop();
  }
}

pub fn add_start_script(webview: &WebView, js: &str) -> Result<(), String> {
  let core = webview.webview();
  let js = HSTRING::from(js);
  AddScriptToExecuteOnDocumentCreatedCompletedHandler::wait_for_async_operation(
    Box::new(move |handler| unsafe { core.AddScriptToExecuteOnDocumentCreated(&js, &handler).map_err(webview2_com::Error::WindowsError) }),
    Box::new(|e, _| e),
  )
  .map_err(|e| format!("{e:?}"))
}

pub fn set_user_agent(webview: &WebView, ua: &str) -> Result<(), String> {
  unsafe {
    let settings = webview.webview().Settings().map_err(|e| e.to_string())?;
    let s2 = settings.cast::<ICoreWebView2Settings2>().map_err(|e| e.to_string())?;
    s2.SetUserAgent(&HSTRING::from(ua)).map_err(|e| e.to_string())
  }
}

/// Deletes the session's cookies and all browsing data, waiting for WebView2
/// to confirm. The InPrivate profile is discarded with the WebView as well.
pub fn clear_data(webview: &WebView) -> Result<(), String> {
  unsafe {
    let core = webview.webview();
    if let Ok(core2) = core.cast::<ICoreWebView2_2>() {
      core2.CookieManager().and_then(|m| m.DeleteAllCookies()).map_err(|e| format!("cookies: {e}"))?;
    }
    let profile = core
      .cast::<ICoreWebView2_13>()
      .and_then(|c| c.Profile())
      .and_then(|p| p.cast::<ICoreWebView2Profile2>())
      .map_err(|e| format!("profile: {e}"))?;
    ClearBrowsingDataCompletedHandler::wait_for_async_operation(
      Box::new(move |handler| profile.ClearBrowsingDataAll(&handler).map_err(webview2_com::Error::WindowsError)),
      Box::new(|e| e),
    )
    .map_err(|e| format!("browsing data: {e:?}"))
  }
}


#[cfg(test)]
mod tests {
  /// An offline helper uses no proxy (a loopback system proxy would resolve
  /// and fetch hosts the resolver rules refuse) and maps every host but
  /// loopback to NOTFOUND (L3).
  #[test]
  fn offline_arguments_refuse_proxies_and_hosts() {
    let args = super::offline_browser_args();
    assert!(args.contains("--no-proxy-server"), "{args}");
    assert!(args.contains("MAP * ~NOTFOUND"), "{args}");
    assert!(args.starts_with(super::WRY_DEFAULT_ARGS), "{args}");
  }
}
