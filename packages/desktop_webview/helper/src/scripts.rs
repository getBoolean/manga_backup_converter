//! Page scripts the helper injects.
//!
//! Page-to-host traffic uses the engine's own messaging, never a
//! `window.<identifier>` global (protocol 1.2 reserves no channel name):
//! [bootstrap_script] captures the engine's post function at document start,
//! before any channel or page script runs, and stores it under a property
//! whose name is not a JavaScript identifier (`dwv:<random>`), so no channel
//! (`ipc`, `chrome`, `webkit`, ...) can shadow it. Every message carries the
//! session's random key; frames without it are dropped.

fn js_string(s: &str) -> String {
  serde_json::Value::String(s.to_string()).to_string()
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
    "(function(){{var k={k},c={c},P=window[{b}];if(typeof P!=='function')return;var S=JSON.stringify;\
if(window[c]&&window[c].__dwv)return;\
var L=window.location;\
Object.defineProperty(window,c,{{configurable:true,value:Object.freeze({{__dwv:true,postMessage:function(m){{if(typeof m!=='string')return;var T=null;try{{T=window.top.location.origin}}catch(e){{}}\
P(S({{k:k,t:'msg',c:c,m:m,o:L.origin,to:T}}))}}}})}});}})();",
    b = js_string(bridge),
    k = js_string(key),
    c = js_string(name)
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
    "(function(){{var k={k},i={i},P=window[{b}];if(typeof P!=='function')return 0;var S=JSON.stringify;\
function E(e){{var m;try{{m=String(e);var t=e&&e.stack;if(t&&String(t).indexOf(m)<0)m+='\\n'+t;}}catch(x){{m='script threw a value that cannot be converted to a string'}}P(S({{k:k,t:'eval',id:i,err:m}}))}}\
var v;try{{v=(0,eval)({s});}}catch(e){{E(e);return 1;}}\
Promise.resolve(v).then(function(r){{var s;try{{s=S(r)}}catch(e){{s=undefined}}P(S({{k:k,t:'eval',id:i,ok:s===undefined?'null':s}}))}},E);return 1;}})()",
    b = js_string(bridge),
    k = js_string(key),
    i = seq,
    s = js_string(script)
  )
}

/// Removes `window.<name>` from the current document (the channel's
/// document-start script stays installed; its messages are dropped).
pub fn remove_channel_script(name: &str) -> String {
  format!("(function(){{var c={c};if(window[c]&&window[c].__dwv)delete window[c];}})();", c = js_string(name))
}
