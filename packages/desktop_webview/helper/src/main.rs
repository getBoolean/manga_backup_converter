//! `desktop_webview_helper`: a standalone process that drives the platform
//! WebView (WebView2 on Windows, WKWebView on macOS, WebKitGTK on Linux) for
//! the desktop `BrowserPort` (KTD20).
//!
//! It is its own program because macOS needs the AppKit event loop on the
//! process main thread. The Dart client (`package:desktop_webview`) talks to
//! it over a bounded JSON-lines protocol on stdin/stdout (see
//! `doc/helper-protocol.md`); stderr carries logs only. The helper exits when
//! stdin closes, so a crashed or killed parent never leaves windows behind.

mod platform;
mod policy;
mod scripts;

use std::{
  cell::RefCell,
  collections::{HashMap, HashSet},
  io::{BufRead, Read, Write},
  path::{Path, PathBuf},
  rc::Rc,
  sync::mpsc,
};

use serde_json::{json, Map, Value};
use tao::{
  event::{Event, WindowEvent},
  event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy, EventLoopWindowTarget},
  window::{Window, WindowBuilder, WindowId},
};
use wry::{NewWindowResponse, WebContext, WebView, WebViewBuilder};

/// Helper protocol version, reported in the `ready` event.
pub const PROTOCOL_VERSION: u64 = 1;

/// Maximum encoded frame size in either direction (KTD4).
pub const MAX_FRAME_BYTES: usize = 16 * 1024 * 1024;

/// How a session's requests are reported to the client.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum InterceptMode {
  None,
  /// Report each request (`request` event); it proceeds unchanged.
  Observe,
  /// Hold each request until the client answers with `respond`.
  Replace,
}

/// Session state shared with platform callbacks. Callbacks borrow it briefly
/// and never call back into the WebView while holding the borrow.
pub struct Shared {
  pub id: String,
  pub key: String,
  pub channels: HashSet<String>,
  pub mode: InterceptMode,
  pub offline: bool,
  /// `loadData` substitution: the next main-document request for this URL
  /// is answered with this HTML (WebView2 has no `loadDataWithBaseURL`).
  pub load_data: Option<(String, String)>,
  /// URLs of the current navigation (target plus redirect hops).
  pub load_chain: Vec<String>,
  /// Set when a load is issued and cleared by its first navigation start:
  /// completions arriving in between belong to an older navigation.
  pub awaiting_start: bool,
  /// Engine navigation ID of the current load, where the engine has one.
  pub nav_id: Option<u64>,
}

/// Events delivered to the main loop from the stdin thread and from
/// platform callbacks.
#[derive(Debug)]
pub enum UserEvent {
  Command(Value),
  StdinClosed,
  FrameError(String),
  /// `uri` is what the engine reports for the posting document (see
  /// `platform::IPC_URI_IS_POSTING_FRAME`).
  Ipc { session: String, uri: String, body: String },
  EvalDispatched { session: String, seq: u64, ok: bool },
  NavStarting { session: String, uri: String, rejected: bool },
  NavFinished { session: String, url: String, ok: bool, status: Option<i64>, error: Option<String> },
  RedirectRejected { session: String, location: String },
  Request { session: String, rid: Option<u64>, url: String, method: String, headers: Vec<(String, String)>, context: String },
}

struct PendingLoad {
  req: u64,
  rejected: Option<String>,
  /// The session's initial `about:blank` navigation: `open` replies once it
  /// settles, so no later load can race it.
  open: bool,
}

struct Session {
  window: Window,
  webview: WebView,
  shared: Rc<RefCell<Shared>>,
  _native: platform::Native,
  installed_channels: HashSet<String>,
  pending_load: Option<PendingLoad>,
  pending_evals: HashMap<u64, u64>,
  eval_seq: u64,
  showing: bool,
}

struct Options {
  data_root: Option<PathBuf>,
  offline: bool,
  test_hooks: bool,
  simulate_fatal: Option<String>,
}

fn parse_args() -> Result<Options, String> {
  let mut opts = Options { data_root: None, offline: false, test_hooks: false, simulate_fatal: None };
  let mut args = std::env::args().skip(1);
  while let Some(a) = args.next() {
    match a.as_str() {
      "--data-root" => opts.data_root = Some(PathBuf::from(args.next().ok_or("--data-root needs a value")?)),
      "--offline" => opts.offline = true,
      "--test-hooks" => opts.test_hooks = true,
      // Test hook: report this fatal code at start-up (typed-failure tests
      // for hosts that do have a display and a WebView runtime).
      "--simulate-fatal" => opts.simulate_fatal = Some(args.next().ok_or("--simulate-fatal needs a value")?),
      "--version" => {
        println!("desktop_webview_helper {} protocol {}", env!("CARGO_PKG_VERSION"), PROTOCOL_VERSION);
        std::process::exit(0);
      }
      other => return Err(format!("unknown argument {other}")),
    }
  }
  Ok(opts)
}

/// Writes frames to stdout from one thread, so callbacks never block on I/O.
#[derive(Clone)]
struct Out(mpsc::Sender<String>);

impl Out {
  fn start() -> (Out, std::thread::JoinHandle<()>) {
    let (tx, rx) = mpsc::channel::<String>();
    let handle = std::thread::spawn(move || {
      let stdout = std::io::stdout();
      let mut lock = stdout.lock();
      for line in rx {
        if line.len() > MAX_FRAME_BYTES {
          eprintln!("[helper] dropping oversized outgoing frame ({} bytes)", line.len());
          continue;
        }
        if lock.write_all(line.as_bytes()).and_then(|_| lock.write_all(b"\n")).and_then(|_| lock.flush()).is_err() {
          break;
        }
      }
    });
    (Out(tx), handle)
  }

  fn send(&self, v: Value) {
    let _ = self.0.send(v.to_string());
  }

  fn ok(&self, id: u64, v: Value) {
    self.send(json!({"id": id, "ok": v}));
  }

  fn err(&self, id: u64, code: &str, message: impl Into<String>, extra: Option<(&str, Value)>) {
    let mut e = Map::new();
    e.insert("code".into(), json!(code));
    e.insert("message".into(), json!(message.into()));
    if let Some((k, v)) = extra {
      e.insert(k.into(), v);
    }
    self.send(json!({"id": id, "err": Value::Object(e)}));
  }
}

fn fatal(out: &Out, code: &str, message: &str) -> ! {
  out.send(json!({"ev": "fatal", "code": code, "message": message}));
  // Give the writer thread a moment to flush the frame.
  std::thread::sleep(std::time::Duration::from_millis(100));
  std::process::exit(3);
}

/// Reads bounded JSON lines from stdin and forwards them to the main loop.
fn spawn_stdin(proxy: EventLoopProxy<UserEvent>) {
  std::thread::spawn(move || {
    let stdin = std::io::stdin();
    let mut reader = stdin.lock();
    loop {
      let mut line = Vec::new();
      let n = match (&mut reader).take(MAX_FRAME_BYTES as u64 + 1).read_until(b'\n', &mut line) {
        Ok(n) => n,
        Err(e) => {
          let _ = proxy.send_event(UserEvent::FrameError(format!("stdin read failed: {e}")));
          return;
        }
      };
      if n == 0 {
        let _ = proxy.send_event(UserEvent::StdinClosed);
        return;
      }
      if line.last() != Some(&b'\n') && line.len() > MAX_FRAME_BYTES {
        let _ = proxy.send_event(UserEvent::FrameError(format!("frame exceeds {MAX_FRAME_BYTES} bytes")));
        return;
      }
      while matches!(line.last(), Some(b'\n' | b'\r')) {
        line.pop();
      }
      if line.is_empty() {
        continue;
      }
      match serde_json::from_slice::<Value>(&line) {
        Ok(v) => {
          if proxy.send_event(UserEvent::Command(v)).is_err() {
            return;
          }
        }
        Err(e) => {
          let _ = proxy.send_event(UserEvent::FrameError(format!("malformed frame: {e}")));
          return;
        }
      }
    }
  });
}

/// Startup wipe (KTD20): removes every helper data directory under [root]
/// that a previous (crashed or killed) helper left behind. Directories that
/// cannot be removed are still in use by a running helper's browser process.
fn wipe_stale(root: &Path, own: Option<&Path>) -> (u32, u32) {
  let (mut removed, mut failed) = (0, 0);
  if let Ok(entries) = std::fs::read_dir(root) {
    for e in entries.flatten() {
      let p = e.path();
      if Some(p.as_path()) == own || !e.file_name().to_string_lossy().starts_with("h-") {
        continue;
      }
      match std::fs::remove_dir_all(&p) {
        Ok(()) => removed += 1,
        Err(_) => failed += 1,
      }
    }
  }
  (removed, failed)
}

fn nonce() -> String {
  use std::hash::{BuildHasher, Hasher};
  let mut s = String::new();
  for i in 0..2u64 {
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u64(i);
    h.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
    s.push_str(&format!("{:016x}", h.finish()));
  }
  s
}

struct App {
  out: Out,
  proxy: EventLoopProxy<UserEvent>,
  opts: Options,
  data_dir: Option<PathBuf>,
  web_context: Option<WebContext>,
  sessions: HashMap<String, Session>,
  windows: HashMap<WindowId, String>,
  shutting_down: bool,
}

fn str_field<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
  v.get(k).and_then(Value::as_str)
}

impl App {
  fn handle_command(&mut self, cmd: Value, target: &EventLoopWindowTarget<UserEvent>) -> bool {
    let Some(id) = cmd.get("id").and_then(Value::as_u64) else {
      eprintln!("[helper] command without id ignored");
      return true;
    };
    let op = str_field(&cmd, "op").unwrap_or("").to_string();
    match op.as_str() {
      "open" => self.open(id, &cmd, target),
      "shutdown" => {
        self.out.ok(id, json!({}));
        return false;
      }
      "wipe" => {
        let (removed, failed) = match &self.opts.data_root {
          Some(root) => wipe_stale(root, self.data_dir.as_deref()),
          None => (0, 0),
        };
        if failed > 0 {
          self.out.err(id, "capability-unavailable", format!("{failed} stale browser data directories could not be removed"), Some(("operation", json!("wipe"))));
        } else {
          self.out.ok(id, json!({"removed": removed}));
        }
      }
      "respond" => {
        let rid = cmd.get("rid").and_then(Value::as_u64).unwrap_or(0);
        let response = cmd.get("response").filter(|r| !r.is_null()).map(platform::ReplacementResponse::from_json);
        match response {
          Some(Err(e)) => self.out.err(id, "invalid", e, None),
          Some(Ok(r)) => {
            platform::respond(rid, Some(r));
            self.out.ok(id, json!({}));
          }
          None => {
            platform::respond(rid, None);
            self.out.ok(id, json!({}));
          }
        }
      }
      _ => {
        let Some(sid) = str_field(&cmd, "session").map(str::to_string) else {
          self.out.err(id, "invalid", format!("{op} needs a session"), None);
          return true;
        };
        if !self.sessions.contains_key(&sid) {
          self.out.err(id, "session-closed", format!("unknown session {sid}"), None);
          return true;
        }
        self.session_command(id, &op, &sid, &cmd);
      }
    }
    true
  }

  fn open(&mut self, id: u64, cmd: &Value, target: &EventLoopWindowTarget<UserEvent>) {
    let Some(sid) = str_field(cmd, "session").map(str::to_string) else {
      return self.out.err(id, "invalid", "open needs a session", None);
    };
    if self.sessions.contains_key(&sid) {
      return self.out.err(id, "invalid", format!("session {sid} already open"), None);
    }
    let mode = match parse_mode(str_field(cmd, "intercept").unwrap_or("none")) {
      Ok(m) => m,
      Err((op, msg)) => return self.out.err(id, "capability-unavailable", msg, Some(("operation", json!(op)))),
    };
    let shared = Rc::new(RefCell::new(Shared {
      id: sid.clone(),
      key: nonce(),
      channels: HashSet::new(),
      mode,
      offline: self.opts.offline,
      load_data: None,
      load_chain: Vec::new(),
      awaiting_start: false,
      nav_id: None,
    }));
    let window = match WindowBuilder::new()
      .with_title(str_field(cmd, "title").unwrap_or("Source browser"))
      .with_visible(false)
      .build(target)
    {
      Ok(w) => w,
      Err(e) => return self.out.err(id, "interaction-required", format!("cannot create a window: {e}"), None),
    };

    let proxy = self.proxy.clone();
    let ipc_sid = sid.clone();
    let ipc_proxy = proxy.clone();
    let mut builder = match self.web_context.as_mut() {
      Some(ctx) => WebViewBuilder::new_with_web_context(ctx),
      None => WebViewBuilder::new(),
    }
    .with_incognito(true)
    .with_devtools(false)
    .with_ipc_handler(move |req| {
      let _ = ipc_proxy.send_event(UserEvent::Ipc { session: ipc_sid.clone(), uri: req.uri().to_string(), body: req.body().clone() });
    })
    .with_new_window_req_handler(|_, _| NewWindowResponse::Deny);
    if let Some(ua) = str_field(cmd, "userAgent") {
      builder = builder.with_user_agent(ua);
    }
    builder = platform::configure_builder(builder, &sid, proxy.clone());
    let webview = match platform::build(builder, &window) {
      Ok(w) => w,
      Err(e) => return self.out.err(id, "capability-unavailable", format!("cannot create the WebView: {e}"), Some(("operation", json!("openSession")))),
    };
    let native = match platform::install(&webview, shared.clone(), proxy) {
      Ok(n) => n,
      Err(e) => return self.out.err(id, "capability-unavailable", format!("cannot hook the WebView: {e}"), Some(("operation", json!("openSession")))),
    };
    // Start the initial document only now that the hooks are installed, and
    // reply to `open` when it settles.
    shared.borrow_mut().awaiting_start = true;
    if let Err(e) = webview.load_url("about:blank") {
      return self.out.err(id, "capability-unavailable", format!("cannot start the WebView: {e}"), Some(("operation", json!("openSession"))));
    }
    self.windows.insert(window.id(), sid.clone());
    self.sessions.insert(
      sid,
      Session {
        window,
        webview,
        shared,
        _native: native,
        installed_channels: HashSet::new(),
        pending_load: Some(PendingLoad { req: id, rejected: None, open: true }),
        pending_evals: HashMap::new(),
        eval_seq: 0,
        showing: false,
      },
    );
  }

  fn session_command(&mut self, id: u64, op: &str, sid: &str, cmd: &Value) {
    let out = self.out.clone();
    let test_hooks = self.opts.test_hooks;
    let s = self.sessions.get_mut(sid).expect("checked");
    match op {
      "load" => {
        let url = str_field(cmd, "url").unwrap_or("");
        if !policy::is_navigable(url) {
          return out.err(id, "capability-unavailable", format!("scheme of {url} is not allowed (only http, https, about:blank)"), Some(("operation", json!("load"))));
        }
        supersede_load(&out, s);
        {
          let mut sh = s.shared.borrow_mut();
          sh.load_data = None;
          sh.load_chain = vec![url.to_string()];
          sh.awaiting_start = true;
        }
        s.pending_load = Some(PendingLoad { req: id, rejected: None, open: false });
        let headers = cmd.get("headers").and_then(Value::as_object);
        let result = match headers {
          Some(h) if !h.is_empty() => {
            let mut map = wry::http::HeaderMap::new();
            for (k, v) in h {
              if let (Ok(name), Some(Ok(value))) = (
                wry::http::header::HeaderName::from_bytes(k.as_bytes()),
                v.as_str().map(wry::http::HeaderValue::from_str),
              ) {
                map.insert(name, value);
              }
            }
            s.webview.load_url_with_headers(url, map)
          }
          _ => s.webview.load_url(url),
        };
        if let Err(e) = result {
          s.pending_load = None;
          out.err(id, "navigation-failed", format!("load failed: {e}"), Some(("url", json!(url))));
        }
      }
      "loadData" => {
        let base = str_field(cmd, "baseUrl").unwrap_or("");
        if !policy::is_allowed_base(base) {
          return out.err(id, "capability-unavailable", format!("base URL scheme of {base} is not allowed (only http, https)"), Some(("operation", json!("loadData"))));
        }
        let html = str_field(cmd, "html").unwrap_or("").to_string();
        supersede_load(&out, s);
        {
          let mut sh = s.shared.borrow_mut();
          sh.load_chain = vec![base.to_string()];
          sh.awaiting_start = true;
        }
        s.pending_load = Some(PendingLoad { req: id, rejected: None, open: false });
        if let Err(e) = platform::load_data(&s.webview, &s.shared, &html, base) {
          s.pending_load = None;
          out.err(id, "navigation-failed", format!("loadData failed: {e}"), Some(("url", json!(base))));
        }
      }
      "stop" => {
        s.pending_load = None;
        platform::stop(&s.webview);
        out.ok(id, json!({}));
      }
      "eval" => {
        let script = str_field(cmd, "script").unwrap_or("");
        s.eval_seq += 1;
        let seq = s.eval_seq;
        let key = s.shared.borrow().key.clone();
        let wrapped = scripts::eval_wrapper(&key, seq, script);
        s.pending_evals.insert(seq, id);
        let proxy = self.proxy.clone();
        let session = sid.to_string();
        let r = s.webview.evaluate_script_with_callback(&wrapped, move |res| {
          let _ = proxy.send_event(UserEvent::EvalDispatched { session: session.clone(), seq, ok: res.trim() == "1" });
        });
        if let Err(e) = r {
          s.pending_evals.remove(&seq);
          out.err(id, "script-error", format!("evaluate failed: {e}"), None);
        }
      }
      "channel" => {
        let name = str_field(cmd, "name").unwrap_or("");
        if !policy::is_js_identifier(name) || name == "ipc" {
          return out.err(id, "capability-unavailable", format!("channel name {name:?} is not a JavaScript identifier"), Some(("operation", json!("setMessageHandler"))));
        }
        let enabled = cmd.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        let key = s.shared.borrow().key.clone();
        let js = scripts::channel_script(&key, name);
        if enabled {
          s.shared.borrow_mut().channels.insert(name.to_string());
          if s.installed_channels.insert(name.to_string()) {
            // Document start of every later document, in every frame.
            if let Err(e) = platform::add_start_script(&s.webview, &js) {
              return out.err(id, "capability-unavailable", format!("cannot install channel: {e}"), Some(("operation", json!("setMessageHandler"))));
            }
          }
          // And the current document, at once.
          let _ = s.webview.evaluate_script(&js);
        } else {
          s.shared.borrow_mut().channels.remove(name);
          let _ = s.webview.evaluate_script(&scripts::remove_channel_script(name));
        }
        out.ok(id, json!({}));
      }
      "intercept" => match parse_mode(str_field(cmd, "mode").unwrap_or("none")) {
        Ok(mode) => {
          s.shared.borrow_mut().mode = mode;
          out.ok(id, json!({}));
        }
        Err((op, msg)) => out.err(id, "capability-unavailable", msg, Some(("operation", json!(op)))),
      },
      "startScript" => {
        let script = str_field(cmd, "script").unwrap_or("");
        match platform::add_start_script(&s.webview, script) {
          Ok(()) => out.ok(id, json!({})),
          Err(e) => out.err(id, "capability-unavailable", format!("cannot add start script: {e}"), Some(("operation", json!("addStartScript")))),
        }
      }
      "cookies" => {
        let url = str_field(cmd, "url").unwrap_or("");
        if !policy::is_allowed_base(url) {
          return out.err(id, "capability-unavailable", format!("cookies need an http(s) URL, got {url}"), Some(("operation", json!("getCookies"))));
        }
        match s.webview.cookies_for_url(url) {
          Ok(list) => out.ok(id, json!({"cookies": list.iter().map(cookie_json).collect::<Vec<_>>()})),
          Err(e) => out.err(id, "capability-unavailable", format!("cannot read cookies: {e}"), Some(("operation", json!("getCookies")))),
        }
      }
      "setCookie" => {
        let url = str_field(cmd, "url").unwrap_or("");
        if !policy::is_allowed_base(url) {
          return out.err(id, "capability-unavailable", format!("cookies need an http(s) URL, got {url}"), Some(("operation", json!("setCookie"))));
        }
        let c = cmd.get("cookie").cloned().unwrap_or(Value::Null);
        match build_cookie(url, &c) {
          Ok(cookie) => match s.webview.set_cookie(&cookie) {
            Ok(()) => out.ok(id, json!({})),
            Err(e) => out.err(id, "capability-unavailable", format!("cannot set cookie: {e}"), Some(("operation", json!("setCookie")))),
          },
          Err(e) => out.err(id, "invalid", e, None),
        }
      }
      "userAgent" => {
        let ua = str_field(cmd, "userAgent").unwrap_or("");
        match platform::set_user_agent(&s.webview, ua) {
          Ok(()) => out.ok(id, json!({})),
          Err(e) => out.err(id, "capability-unavailable", format!("cannot set user agent: {e}"), Some(("operation", json!("setUserAgent")))),
        }
      }
      "show" => {
        s.window.set_visible(true);
        s.window.set_focus();
        s.showing = true;
        out.ok(id, json!({}));
      }
      "hide" => {
        s.window.set_visible(false);
        s.showing = false;
        out.ok(id, json!({}));
      }
      "debugRequestClose" if test_hooks => {
        out.ok(id, json!({}));
        let wid = s.window.id();
        self.window_close_requested(wid);
      }
      "close" => {
        let result = self.close_session(sid);
        match result {
          Ok(()) => out.ok(id, json!({})),
          Err(e) => out.err(id, "capability-unavailable", format!("storage deletion not confirmed: {e}"), Some(("operation", json!("close")))),
        }
      }
      other => out.err(id, "invalid", format!("unknown operation {other}"), None),
    }
  }

  /// Deletes the session's browser data, then destroys its WebView and window.
  fn close_session(&mut self, sid: &str) -> Result<(), String> {
    let Some(s) = self.sessions.remove(sid) else { return Ok(()) };
    self.windows.remove(&s.window.id());
    let result = platform::clear_data(&s.webview);
    for (_, req) in s.pending_evals.iter() {
      self.out.err(*req, "session-closed", "session closed", None);
    }
    if let Some(p) = &s.pending_load {
      self.out.err(p.req, "session-closed", "session closed", None);
    }
    if s.showing {
      self.out.send(json!({"ev": "interactionEnded", "session": sid, "reason": "session-closed"}));
    }
    drop(s);
    result
  }

  fn window_close_requested(&mut self, wid: WindowId) {
    let Some(sid) = self.windows.get(&wid).cloned() else { return };
    if let Some(s) = self.sessions.get_mut(&sid) {
      s.window.set_visible(false);
      if s.showing {
        s.showing = false;
        self.out.send(json!({"ev": "interactionEnded", "session": sid, "reason": "closed"}));
      }
    }
  }

  fn handle_event(&mut self, ev: UserEvent) {
    match ev {
      UserEvent::Ipc { session, uri, body } => self.on_ipc(&session, &uri, &body),
      UserEvent::EvalDispatched { session, seq, ok } => {
        if ok {
          return;
        }
        if let Some(s) = self.sessions.get_mut(&session) {
          if let Some(req) = s.pending_evals.remove(&seq) {
            self.out.err(req, "script-error", "the page has no script bridge (no document loaded?)", None);
          }
        }
      }
      UserEvent::NavStarting { session, uri, rejected } => {
        let Some(s) = self.sessions.get_mut(&session) else { return };
        // A new document discards pending evaluations of the old one.
        for (_, req) in s.pending_evals.drain() {
          self.out.err(req, "script-error", "the page navigated away before the script completed", None);
        }
        if rejected {
          if let Some(p) = s.pending_load.as_mut() {
            p.rejected.get_or_insert(uri);
          }
        } else {
          s.shared.borrow_mut().load_chain.push(uri);
        }
      }
      UserEvent::RedirectRejected { session, location } => {
        if let Some(p) = self.sessions.get_mut(&session).and_then(|s| s.pending_load.as_mut()) {
          p.rejected.get_or_insert(location);
        }
      }
      UserEvent::NavFinished { session, url, ok, status, error } => {
        let Some(s) = self.sessions.get_mut(&session) else { return };
        let Some(p) = s.pending_load.take() else { return };
        if p.open {
          // The initial about:blank document settled; the session is ready.
          self.out.ok(p.req, json!({}));
        } else if let Some(rejected) = p.rejected {
          self.out.err(p.req, "capability-unavailable", format!("navigation to {rejected} refused (only http, https, about:blank)"), Some(("operation", json!("navigation"))));
        } else if ok {
          self.out.ok(p.req, json!({"finalUrl": url, "status": status}));
        } else {
          self.out.err(p.req, "navigation-failed", error.unwrap_or_else(|| "navigation failed".into()), Some(("url", json!(url))));
        }
      }
      UserEvent::Request { session, rid, url, method, headers, context } => {
        let hs: Map<String, Value> = headers.into_iter().map(|(k, v)| (k, Value::String(v))).collect();
        self.out.send(json!({"ev": "request", "session": session, "rid": rid, "url": url, "method": method, "headers": hs, "context": context}));
      }
      UserEvent::Command(_) | UserEvent::StdinClosed | UserEvent::FrameError(_) => unreachable!(),
    }
  }

  fn on_ipc(&mut self, session: &str, uri: &str, body: &str) {
    let Some(s) = self.sessions.get_mut(session) else { return };
    let Ok(v) = serde_json::from_str::<Value>(body) else { return };
    if str_field(&v, "k") != Some(s.shared.borrow().key.as_str()) {
      return;
    }
    match str_field(&v, "t") {
      Some("eval") => {
        let seq = v.get("id").and_then(Value::as_u64).unwrap_or(0);
        let Some(req) = s.pending_evals.remove(&seq) else { return };
        if let Some(result) = str_field(&v, "ok") {
          self.out.ok(req, json!({"result": result}));
        } else {
          self.out.err(req, "script-error", str_field(&v, "err").unwrap_or("script failed").to_string(), None);
        }
      }
      Some("msg") => {
        let channel = str_field(&v, "c").unwrap_or("");
        if !s.shared.borrow().channels.contains(channel) {
          return;
        }
        // Origin rule: the posting frame must share the origin of the
        // current top-level http(s) document. The page script reports the
        // frame's own origin and `top.location.origin`, which a cross-origin
        // frame cannot read (it reports null). Where the engine identifies
        // the posting document, its URL must agree as well. Both are read
        // in-page, so a message posted while a new document is still loading
        // is judged against that document, not the previous one.
        let frame_origin = str_field(&v, "o").and_then(policy::origin_of);
        let top_origin = str_field(&v, "to").and_then(policy::origin_of);
        let engine_ok = !platform::IPC_URI_IS_POSTING_FRAME || policy::origin_of(uri) == frame_origin;
        if frame_origin.is_none() || frame_origin != top_origin || !engine_ok {
          return;
        }
        let Some(message) = v.get("m").and_then(Value::as_str) else { return };
        self.out.send(json!({"ev": "message", "session": session, "name": channel, "message": message}));
      }
      _ => {}
    }
  }

  fn shutdown(&mut self) {
    if self.shutting_down {
      return;
    }
    self.shutting_down = true;
    let ids: Vec<String> = self.sessions.keys().cloned().collect();
    for sid in ids {
      if let Err(e) = self.close_session(&sid) {
        eprintln!("[helper] closing {sid} on shutdown: {e}");
      }
    }
    self.web_context = None;
  }
}

fn parse_mode(mode: &str) -> Result<InterceptMode, (&'static str, &'static str)> {
  match mode {
    "observe" if platform::CAPS.request_observe == "none" => {
      Err(("interceptRequest.observe", "request observation is unavailable on this engine"))
    }
    "observe" => Ok(InterceptMode::Observe),
    "replace" if !platform::CAPS.request_replace => {
      Err(("interceptRequest.replace", "request replacement is only available on WebView2"))
    }
    "replace" => Ok(InterceptMode::Replace),
    _ => Ok(InterceptMode::None),
  }
}

fn supersede_load(out: &Out, s: &mut Session) {
  if let Some(p) = s.pending_load.take() {
    out.err(p.req, "cancelled", "superseded by a newer load", None);
  }
}

fn cookie_json(c: &wry::cookie::Cookie<'static>) -> Value {
  let expires = c.expires_datetime().map(|t| {
    let secs = t.unix_timestamp();
    json!(secs)
  });
  json!({
    "name": c.name(),
    "value": c.value(),
    "domain": c.domain(),
    "path": c.path(),
    "expiresUnix": expires,
    "secure": c.secure().unwrap_or(false),
    "httpOnly": c.http_only().unwrap_or(false),
  })
}

fn build_cookie(url: &str, c: &Value) -> Result<wry::cookie::Cookie<'static>, String> {
  let name = str_field(c, "name").ok_or("cookie needs a name")?.to_string();
  let value = str_field(c, "value").unwrap_or("").to_string();
  let host = policy::host_of(url).ok_or_else(|| format!("cannot derive a cookie domain from {url}"))?;
  let mut b = wry::cookie::Cookie::build((name, value))
    .domain(str_field(c, "domain").map(str::to_string).unwrap_or(host))
    .path(str_field(c, "path").map(str::to_string).unwrap_or_else(|| "/".into()))
    .secure(c.get("secure").and_then(Value::as_bool).unwrap_or(false))
    .http_only(c.get("httpOnly").and_then(Value::as_bool).unwrap_or(false));
  if let Some(secs) = c.get("expiresUnix").and_then(Value::as_i64) {
    let t = wry::cookie::time::OffsetDateTime::from_unix_timestamp(secs).map_err(|e| e.to_string())?;
    b = b.expires(t);
  }
  Ok(b.build())
}

fn main() {
  let (out, writer) = Out::start();
  let opts = match parse_args() {
    Ok(o) => o,
    Err(e) => fatal(&out, "invalid-arguments", &e),
  };

  if let Some(code) = &opts.simulate_fatal {
    fatal(&out, code, "simulated by --simulate-fatal");
  }
  if opts.offline && !platform::CAPS.offline_enforced {
    // Fail closed: replay must never fall through to the network.
    fatal(&out, "offline-unsupported", &format!("{} cannot block network requests yet; offline replay is unavailable", platform::ENGINE));
  }
  if let Some(reason) = platform::display_missing() {
    fatal(&out, "no-display", &reason);
  }
  let engine_version = match wry::webview_version() {
    Ok(v) => v,
    Err(e) => fatal(&out, "runtime-missing", &format!("{} runtime is not available: {e}", platform::ENGINE)),
  };

  // Startup wipe before any session exists, then a fresh per-process
  // directory (only engines with a data directory use it: WebView2).
  let mut wipe = (0, 0);
  let mut data_dir = None;
  if let Some(root) = &opts.data_root {
    if let Err(e) = std::fs::create_dir_all(root) {
      fatal(&out, "init-failed", &format!("cannot create data root: {e}"));
    }
    wipe = wipe_stale(root, None);
    let dir = root.join(format!("h-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    if let Err(e) = std::fs::create_dir_all(&dir) {
      fatal(&out, "init-failed", &format!("cannot create data directory: {e}"));
    }
    data_dir = Some(dir);
  }

  let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
  let proxy = event_loop.create_proxy();
  let web_context = platform::web_context(data_dir.as_deref());

  out.send(json!({
    "ev": "ready",
    "protocol": PROTOCOL_VERSION,
    "helperVersion": env!("CARGO_PKG_VERSION"),
    "engine": platform::ENGINE,
    "engineVersion": engine_version,
    "pid": std::process::id(),
    "maxFrameBytes": MAX_FRAME_BYTES,
    "capabilities": platform::CAPS.to_json(),
    "wipe": {"removed": wipe.0, "failed": wipe.1},
  }));
  spawn_stdin(proxy.clone());

  let mut app = App {
    out,
    proxy,
    opts,
    data_dir,
    web_context,
    sessions: HashMap::new(),
    windows: HashMap::new(),
    shutting_down: false,
  };
  let mut writer = Some(writer);

  event_loop.run(move |event, target, control_flow| {
    *control_flow = ControlFlow::Wait;
    match event {
      Event::UserEvent(UserEvent::Command(cmd)) => {
        if !app.handle_command(cmd, target) {
          app.shutdown();
          *control_flow = ControlFlow::Exit;
        }
      }
      Event::UserEvent(UserEvent::StdinClosed) => {
        app.shutdown();
        *control_flow = ControlFlow::Exit;
      }
      Event::UserEvent(UserEvent::FrameError(e)) => {
        app.out.send(json!({"ev": "protocolError", "message": e}));
        app.shutdown();
        *control_flow = ControlFlow::Exit;
      }
      Event::UserEvent(ev) => app.handle_event(ev),
      Event::WindowEvent { window_id, event: WindowEvent::CloseRequested, .. } => app.window_close_requested(window_id),
      Event::LoopDestroyed => {
        app.shutdown();
        if let Some(dir) = app.data_dir.take() {
          // The browser process may hold files briefly after the last WebView closes.
          for _ in 0..20 {
            if std::fs::remove_dir_all(&dir).is_ok() || !dir.exists() {
              break;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
          }
        }
        let (tx, _) = mpsc::channel();
        app.out = Out(tx);
        if let Some(w) = writer.take() {
          let _ = w.join();
        }
      }
      _ => {}
    }
  });
}
