//! Page scripts the helper injects. Every message to the host carries the
//! session's random key; frames without it are dropped.

fn js_string(s: &str) -> String {
  serde_json::Value::String(s.to_string()).to_string()
}

/// Defines `window.<name>.postMessage(string)` (the `addJavascriptInterface`
/// shape the Tachi shim expects). Installed as a document-start script, and
/// evaluated once in the current document.
pub fn channel_script(key: &str, name: &str) -> String {
  format!(
    "(function(){{var k={k},c={c};if(!window.ipc)return;var P=window.ipc.postMessage,S=JSON.stringify;\
if(window[c]&&window[c].__dwv)return;\
var L=window.location;\
Object.defineProperty(window,c,{{configurable:true,value:Object.freeze({{__dwv:true,postMessage:function(m){{if(typeof m!=='string')return;var T=null;try{{T=window.top.location.origin}}catch(e){{}}\
P(S({{k:k,t:'msg',c:c,m:m,o:L.origin,to:T}}))}}}})}});}})();",
    k = js_string(key),
    c = js_string(name)
  )
}

/// Wraps [script] so its completion value (awaited if it is a promise) is
/// posted back as JSON text. The wrapper itself evaluates to `1` when the
/// bridge exists, which the helper checks through the engine's own script
/// result.
pub fn eval_wrapper(key: &str, seq: u64, script: &str) -> String {
  format!(
    "(function(){{var k={k},i={i};if(!window.ipc)return 0;var P=window.ipc.postMessage,S=JSON.stringify;\
function E(e){{P(S({{k:k,t:'eval',id:i,err:String(e&&e.stack||e)}}))}}\
var v;try{{v=(0,eval)({s});}}catch(e){{E(e);return 1;}}\
Promise.resolve(v).then(function(r){{var s;try{{s=S(r)}}catch(e){{s=undefined}}P(S({{k:k,t:'eval',id:i,ok:s===undefined?'null':s}}))}},E);return 1;}})()",
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
