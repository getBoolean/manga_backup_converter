//! Page scripts the helper injects.
//!
//! Page-to-host traffic uses the engine's own messaging, never a
//! `window.<identifier>` global (protocol 1.2 reserves no channel name):
//! [bootstrap_script] captures the engine's post function at document start,
//! before any channel or page script runs, and stores it under a property
//! whose name is not a JavaScript identifier (`dwv:<random>`), so no channel
//! (`ipc`, `chrome`, `webkit`, ...) can shadow it. Every message carries the
//! session's random key; frames without it are dropped.
//!
//! The envelope that carries the key is never handed to anything the page
//! can reach: it is serialised by `Q` ([QUOTE_FN]), a private quoting
//! function that only uses string indexing, `length`, comparison and
//! concatenation (no `JSON.stringify`, whose `toJSON` lookup walks
//! `Object.prototype`, and no prototype method a page can replace before a
//! script is evaluated in its document). Its control-character table holds
//! an own property for every character it is consulted for.

fn js_string(s: &str) -> String {
  serde_json::Value::String(s.to_string()).to_string()
}

/// Private JSON string quoting (see the module docs): `Q(s)` returns the JSON
/// literal of the string primitive `s`.
const QUOTE_FN: &str = r#"function Q(s){var r='"',i=0,c;for(;i<s.length;i++){c=s[i];if(c==='"')r+='\\"';else if(c==='\\')r+='\\\\';else if(c<' ')r+=X[c];else r+=c;}return r+'"'}"#;

/// Defines `X` (an own property per control character) and `Q` in the
/// enclosing function.
fn envelope_quote() -> String {
  let table: serde_json::Map<String, serde_json::Value> = (0u32..0x20)
    .map(|c| (char::from_u32(c).unwrap().to_string(), serde_json::Value::String(format!("\\u{c:04x}"))))
    .collect();
  format!("var X={};{QUOTE_FN}", serde_json::Value::Object(table))
}

/// Captures the engine's post function ([post_expr], an expression that
/// evaluates to a function or `null`) under `window[bridge]`. Idempotent;
/// registered as the session's first document-start script.
pub fn bootstrap_script(bridge: &str, post_expr: &str) -> String {
  format!(
    "(function(){{var b={b};if(Object.prototype.hasOwnProperty.call(window,b))return;var p=null;try{{p={e};}}catch(x){{}}\
if(typeof p!=='function')return;Object.defineProperty(window,b,{{value:p}});}})();",
    b = js_string(bridge),
    e = post_expr
  )
}

/// Defines `window.<name>.postMessage(string)` (the `addJavascriptInterface`
/// shape the Tachi shim expects). Installed as a document-start script, and
/// evaluated once in the current document.
pub fn channel_script(bridge: &str, key: &str, name: &str) -> String {
  format!(
    "(function(){{var k={k},c={c},P=window[{b}];if(typeof P!=='function')return;{q}\
if(window[c]&&window[c].__dwv)return;\
var L=window.location;\
Object.defineProperty(window,c,{{configurable:true,value:Object.freeze({{__dwv:true,postMessage:function(m){{if(typeof m!=='string')return;var T=null;try{{T=window.top.location.origin}}catch(e){{}}\
var o=L.origin;P('{{\"k\":'+Q(k)+',\"t\":\"msg\",\"c\":'+Q(c)+',\"m\":'+Q(m)+',\"o\":'+(typeof o==='string'?Q(o):'null')+',\"to\":'+(typeof T==='string'?Q(T):'null')+'}}')}}}})}});}})();",
    b = js_string(bridge),
    k = js_string(key),
    c = js_string(name),
    q = envelope_quote()
  )
}

/// Wraps [script] so its completion value (awaited if it is a promise) is
/// posted back as JSON text, or the thrown value as `err` (its string form,
/// then its stack when the stack does not already carry it, as
/// JavaScriptCore's does not; a thrown script or a rejected promise: the only
/// source of `script-error`). The wrapper itself
/// evaluates to `1` when the bridge exists and `0` when it does not (no
/// document with the bootstrap yet), which the helper reads through the
/// engine's own script result.
pub fn eval_wrapper(bridge: &str, key: &str, seq: u64, script: &str) -> String {
  format!(
    "(function(){{var k={k},i={i},P=window[{b}];if(typeof P!=='function')return 0;var S=JSON.stringify;{q}\
function W(f,v){{P('{{\"k\":'+Q(k)+',\"t\":\"eval\",\"id\":'+i+',\"'+f+'\":'+Q(v)+'}}')}}\
function E(e){{var m;try{{m=String(e);var t=e&&e.stack;if(t&&String(t).indexOf(m)<0)m+='\\n'+t;}}catch(x){{m=''}}if(typeof m!=='string'||!m)m='script threw a value that cannot be converted to a string';W('err',m)}}\
var v;try{{v=(0,eval)({s});}}catch(e){{E(e);return 1;}}\
Promise.resolve(v).then(function(r){{var s;try{{s=S(r)}}catch(e){{s=undefined}}W('ok',typeof s==='string'?s:'null')}},E);return 1;}})()",
    b = js_string(bridge),
    k = js_string(key),
    i = seq,
    s = js_string(script),
    q = envelope_quote()
  )
}

/// Removes `window.<name>` from the current document (the channel's
/// document-start script stays installed; its messages are dropped).
pub fn remove_channel_script(name: &str) -> String {
  format!("(function(){{var c={c};if(window[c]&&window[c].__dwv)delete window[c];}})();", c = js_string(name))
}

#[cfg(test)]
mod tests {
  use super::*;

  /// The scripts that carry the session key never call `JSON.stringify` on
  /// the envelope, nor anything a page can reach through a prototype (L1).
  #[test]
  fn key_envelopes_are_built_without_prototype_reachable_calls() {
    let channel = channel_script("dwv:b", "KEY", "chan");
    assert!(!channel.contains("JSON"), "{channel}");
    assert!(!channel.contains("{k:k"), "{channel}");
    let eval = eval_wrapper("dwv:b", "KEY", 7, "1+1");
    // The page's own result is still stringified with JSON.stringify; the
    // envelope with the key is not.
    assert!(!eval.contains("S({"), "{eval}");
    assert_eq!(eval.matches("Q(k)").count(), 1, "{eval}");
    // The control-character table has an own entry for each of 0x00-0x1f.
    let quote = envelope_quote();
    for c in 0u32..0x20 {
      assert!(quote.contains(&format!(":\"\\\\u{c:04x}\"")), "missing {c:#x} in {quote}");
    }
  }
}
