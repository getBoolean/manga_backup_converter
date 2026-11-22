//! Scheme rules (KTD20), enforced here independently of the Dart client:
//! loads, navigations and redirects may target http(s) or `about:blank`;
//! `loadData` base URLs and cookie URLs must be http(s).

fn split_web(url: &str) -> Option<(&str, &str)> {
  let (scheme, rest) = url.split_once("://")?;
  let scheme_ok = scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("https");
  let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
  let host = authority.rsplit('@').next().unwrap_or("");
  (scheme_ok && !host.is_empty() && !host.starts_with(':')).then_some((scheme, host))
}

/// Whether [url] may be loaded or navigated to (including redirects).
pub fn is_navigable(url: &str) -> bool {
  url == "about:blank" || split_web(url).is_some()
}

/// Whether [url] is an acceptable `loadData` base URL or cookie URL.
pub fn is_allowed_base(url: &str) -> bool {
  split_web(url).is_some()
}

/// Host of an http(s) URL, without port.
pub fn host_of(url: &str) -> Option<String> {
  let (_, host) = split_web(url)?;
  let host = if host.starts_with('[') {
    host.split(']').next().map(|h| format!("{h}]"))?
  } else {
    host.split(':').next()?.to_string()
  };
  Some(host)
}

/// `scheme://host[:port]` of an http(s) URL (lowercase, default port
/// dropped), or `None` for every other URL, which has an opaque origin.
pub fn origin_of(url: &str) -> Option<String> {
  let (scheme, rest) = url.split_once("://")?;
  let scheme = scheme.to_ascii_lowercase();
  if scheme != "http" && scheme != "https" {
    return None;
  }
  let authority = rest.split(['/', '?', '#']).next()?;
  let hostport = authority.rsplit('@').next()?.to_ascii_lowercase();
  if hostport.is_empty() || hostport.starts_with(':') {
    return None;
  }
  let default = if scheme == "http" { ":80" } else { ":443" };
  let hostport = hostport.strip_suffix(default).unwrap_or(&hostport).to_string();
  Some(format!("{scheme}://{hostport}"))
}

/// Whether [url] targets the loopback interface (test fixtures served locally).
pub fn is_loopback(url: &str) -> bool {
  matches!(host_of(url).as_deref(), Some("127.0.0.1" | "localhost" | "[::1]"))
}

/// Path of an http(s) URL (`/` when it has none), without query or fragment.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn path_of(url: &str) -> Option<String> {
  split_web(url)?;
  let rest = url.split_once("://")?.1;
  let after = rest.find(['/', '?', '#']).map_or("", |i| &rest[i..]);
  let path = after.split(['?', '#']).next().unwrap_or("");
  Some(if path.starts_with('/') { path.to_string() } else { "/".to_string() })
}

/// Whether a cookie with [domain] (a leading `.` marks a domain cookie),
/// [path] and [secure] is sent to [url] (RFC 6265 domain and path matching;
/// a secure cookie also goes to loopback over http, as browsers treat it as a
/// secure context). For engines whose cookie API returns the whole store.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub fn cookie_matches(url: &str, domain: &str, path: &str, secure: bool) -> bool {
  let (Some(host), Some(req_path)) = (host_of(url), path_of(url)) else { return false };
  let host = host.to_ascii_lowercase();
  let domain = domain.to_ascii_lowercase();
  let bare = domain.strip_prefix('.').unwrap_or(&domain);
  let is_ip = host.starts_with('[') || host.parse::<std::net::Ipv4Addr>().is_ok();
  let domain_ok = host == bare || (domain.starts_with('.') && !is_ip && host.ends_with(&format!(".{bare}")));
  let cpath = if path.is_empty() { "/" } else { path };
  let path_ok = req_path == cpath
    || (req_path.starts_with(cpath) && (cpath.ends_with('/') || req_path[cpath.len()..].starts_with('/')));
  let https = url.get(..8).is_some_and(|s| s.eq_ignore_ascii_case("https://"));
  domain_ok && path_ok && (!secure || https || is_loopback(url))
}

/// Whether [name] is a plain JavaScript identifier (channel names).
pub fn is_js_identifier(name: &str) -> bool {
  let mut chars = name.chars();
  matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_' || c == '$')
    && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '$')
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn schemes() {
    for ok in ["http://a.b/", "https://mangafire.to/@waf/solver", "HTTPS://x.y", "about:blank", "http://127.0.0.1:8080/p"] {
      assert!(is_navigable(ok), "{ok}");
    }
    for bad in [
      "file:///etc/passwd",
      "file:///C:/Windows/win.ini",
      "content://com.example/data",
      "app://local/index.html",
      "javascript:alert(1)",
      "data:text/html,<p>x</p>",
      "about:srcdoc",
      "https:///nohost",
      "http://:80/",
    ] {
      assert!(!is_navigable(bad), "{bad}");
    }
    assert!(!is_allowed_base("about:blank"));
    assert!(is_allowed_base("https://mangafire.to/"));
  }

  #[test]
  fn hosts() {
    assert_eq!(host_of("https://user:pw@mangafire.to:443/x").as_deref(), Some("mangafire.to"));
    assert_eq!(host_of("http://[::1]:80/").as_deref(), Some("[::1]"));
    assert!(is_loopback("http://127.0.0.1:1234/page"));
    assert!(!is_loopback("https://mangafire.to/"));
  }

  #[test]
  fn origins() {
    assert_eq!(origin_of("https://Mangafire.to:443/@waf/solver?x").as_deref(), Some("https://mangafire.to"));
    assert_eq!(origin_of("http://127.0.0.1:8080/p").as_deref(), Some("http://127.0.0.1:8080"));
    assert_ne!(origin_of("http://127.0.0.1:8080/"), origin_of("http://127.0.0.1:8081/"));
    assert_eq!(origin_of("about:blank"), None);
    assert_eq!(origin_of("null"), None);
    assert_eq!(origin_of("file:///etc/passwd"), None);
  }

  #[test]
  fn identifiers() {
    assert!(is_js_identifier("bridge"));
    assert!(is_js_identifier("_a$1"));
    assert!(!is_js_identifier("1a"));
    assert!(!is_js_identifier("a.b"));
    assert!(!is_js_identifier(""));
  }

  #[test]
  fn cookies() {
    let u = "http://127.0.0.1:8080/a/b?q#f";
    assert_eq!(path_of(u).as_deref(), Some("/a/b"));
    assert_eq!(path_of("https://x.test").as_deref(), Some("/"));
    assert!(cookie_matches(u, "127.0.0.1", "/", false));
    assert!(cookie_matches(u, "127.0.0.1", "/a", false));
    assert!(!cookie_matches(u, "127.0.0.1", "/ab", false));
    assert!(!cookie_matches(u, ".0.0.1", "/", false));
    assert!(cookie_matches(u, "127.0.0.1", "/", true));
    assert!(cookie_matches("https://www.example.com/", ".example.com", "/", true));
    assert!(!cookie_matches("http://www.example.com/", ".example.com", "/", true));
    assert!(!cookie_matches("https://www.example.com/", "example.com", "/", false));
    assert!(!cookie_matches("https://badexample.com/", ".example.com", "/", false));
  }
}
