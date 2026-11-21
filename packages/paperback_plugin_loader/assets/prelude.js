// Paperback host prelude (U6): web-platform globals shared by the 0.8 and 0.9
// adapters. Evaluated after the Dart host installs `__pbHost` and before any
// source bundle. Only primitives cross into Dart: one HTTP exchange, a timer
// wake-up, a browser call, and synchronous text/byte codecs. Everything a
// source can observe as state (timers, interceptors, selectors, cookies) is
// held here in JS, because the promise bridge drops host calls that are still
// pending when an operation ends.
(function () {
  'use strict';
  const H = globalThis.__pbHost;

  // ---- timers -------------------------------------------------------------
  // Timer state lives in JS. The host call is only a re-armable wake-up: when
  // an operation ends while a wake is pending, the bridge drops it, and the
  // next operation calls `__pbTimers.rearm()` so due timers still fire. A
  // promise parked on `Application.sleep` across operations therefore settles.
  const timers = new Map();
  let nextTimerId = 1;
  let armedFor = Infinity;
  let armToken = 0;

  function arm() {
    let due = Infinity;
    for (const t of timers.values()) if (t.due < due) due = t.due;
    if (due === Infinity || due >= armedFor) return;
    armedFor = due;
    const token = ++armToken;
    H.wake(Math.max(0, due - Date.now())).then(() => {
      if (token !== armToken) return;
      armedFor = Infinity;
      fire();
    });
  }

  function fire() {
    const now = Date.now();
    const due = [...timers.entries()]
      .filter(([, t]) => t.due <= now)
      .sort((a, b) => a[1].due - b[1].due || a[0] - b[0]);
    for (const [id, t] of due) {
      if (!timers.has(id)) continue;
      if (t.interval === null) timers.delete(id);
      else t.due = now + t.interval;
      try {
        t.fn(...t.args);
      } catch (e) {
        console.error('timer callback threw: ' + (e && e.stack ? e.stack : e));
      }
    }
    arm();
  }

  function addTimer(fn, ms, args, repeat) {
    if (typeof fn !== 'function') throw new TypeError('timer callback must be a function');
    const delay = Math.max(0, Number(ms) || 0);
    const id = nextTimerId++;
    timers.set(id, { fn, args, due: Date.now() + delay, interval: repeat ? Math.max(1, delay) : null });
    arm();
    return id;
  }

  globalThis.setTimeout = (fn, ms, ...args) => addTimer(fn, ms, args, false);
  globalThis.setInterval = (fn, ms, ...args) => addTimer(fn, ms, args, true);
  globalThis.clearTimeout = (id) => { timers.delete(id); };
  globalThis.clearInterval = globalThis.clearTimeout;
  globalThis.queueMicrotask = (fn) => { Promise.resolve().then(fn); };
  globalThis.__pbTimers = {
    rearm() {
      armedFor = Infinity;
      armToken++;
      arm();
    },
    get pending() { return timers.size; },
  };

  // ---- bytes and text ------------------------------------------------------
  function toBytes(value) {
    if (value instanceof Uint8Array) return value;
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    if (Array.isArray(value)) return new Uint8Array(value);
    throw new TypeError('expected bytes, got ' + typeof value);
  }
  function toArrayBuffer(bytes) {
    return bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength
      ? bytes.buffer
      : bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  }
  globalThis.__pbBytes = { toBytes, toArrayBuffer };

  class TextEncoder {
    get encoding() { return 'utf-8'; }
    encode(input = '') { return H.utf8Encode(String(input)); }
  }
  class TextDecoder {
    constructor(label = 'utf-8') {
      const l = String(label).toLowerCase();
      if (l === 'utf-8' || l === 'utf8') this._enc = 'utf-8';
      else if (l === 'ascii' || l === 'latin1' || l === 'iso-8859-1' || l === 'us-ascii') this._enc = 'latin1';
      else if (l === 'utf-16' || l === 'utf-16le') this._enc = 'utf-16le';
      else throw new RangeError('[capability-unavailable] TextDecoder encoding "' + label + '"');
    }
    get encoding() { return this._enc === 'latin1' ? 'windows-1252' : this._enc; }
    decode(input) {
      if (input === undefined) return '';
      const bytes = toBytes(input);
      if (this._enc === 'utf-8') return H.utf8Decode(bytes);
      if (this._enc === 'latin1') return H.latin1Decode(bytes);
      return H.utf16Decode(bytes);
    }
  }
  globalThis.TextEncoder = TextEncoder;
  globalThis.TextDecoder = TextDecoder;

  globalThis.btoa = (s) => {
    const str = String(s);
    const bytes = new Uint8Array(str.length);
    for (let i = 0; i < str.length; i++) {
      const c = str.charCodeAt(i);
      if (c > 255) throw new Error('btoa: character out of Latin1 range');
      bytes[i] = c;
    }
    return H.base64Encode(bytes);
  };
  globalThis.atob = (s) => H.latin1Decode(H.base64Decode(String(s).replace(/[\t\n\f\r ]/g, '')));

  // ---- misc ------------------------------------------------------------------
  if (typeof globalThis.structuredClone !== 'function') {
    globalThis.structuredClone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
  }

  // Normalises a value for the trip to Dart: Dates become ISO strings, byte
  // views become Uint8Arrays, functions and undefined are dropped.
  globalThis.__pbPlain = function plain(v, depth = 0) {
    if (depth > 48) return null;
    if (v === null || v === undefined) return null;
    if (v instanceof Date) return isNaN(v.getTime()) ? null : v.toISOString();
    if (v instanceof ArrayBuffer || ArrayBuffer.isView(v)) return toBytes(v).slice();
    if (Array.isArray(v)) return v.map((x) => plain(x, depth + 1));
    switch (typeof v) {
      case 'string':
      case 'boolean':
        return v;
      case 'number':
        return Number.isFinite(v) ? v : null;
      case 'bigint':
        return v.toString();
      case 'object': {
        const out = {};
        for (const k of Object.keys(v)) {
          const x = v[k];
          if (x === undefined || typeof x === 'function' || typeof x === 'symbol') continue;
          out[k] = plain(x, depth + 1);
        }
        return out;
      }
      default:
        return null;
    }
  };

  // Parses `Set-Cookie` header values the way the 0.9 reference polyfill does.
  globalThis.__pbParseSetCookie = function (values, url) {
    const host = H.hostOf(url);
    const out = [];
    for (const raw of values || []) {
      const props = String(raw).split(';');
      const [name, ...valueParts] = props.shift().split('=');
      let domain;
      let path;
      let expires;
      for (const p of props) {
        const [attr, ...rest] = p.split('=');
        const val = rest.join('=').trim();
        switch (attr.trim().toLowerCase()) {
          case 'expires': expires = new Date(val); break;
          case 'max-age': expires = new Date(Date.now() + Number(val) * 1000); break;
          case 'domain': domain = val.replace(/^\./, ''); break;
          case 'path': path = val; break;
        }
      }
      out.push({ name: name.trim(), value: valueParts.join('=').trim(), domain: domain || host, path: path || '/', expires });
    }
    return out;
  };

  // Follows redirects for one logical request. `next(proposed, response)` may
  // replace or cancel (return undefined) the proposed request. Each hop is one
  // host exchange; cookies set by a hop travel with the next hop.
  globalThis.__pbFetchFollowing = async function (wire, next, maxRedirects = 10) {
    let current = wire;
    // Every hop's cookies, oldest first, for hosts that keep a cookie jar.
    const hops = [];
    for (let hop = 0; ; hop++) {
      const raw = await H.fetch(current);
      hops.push(raw);
      const redirect = raw.redirectUrl;
      if (!redirect || hop >= maxRedirects) return { raw, request: current, hops };
      const method = String(current.method || 'GET').toUpperCase();
      const keepMethod = raw.status === 307 || raw.status === 308 || (method === 'GET' || method === 'HEAD');
      let proposed = {
        url: redirect,
        method: keepMethod ? method : 'GET',
        headers: { ...(current.headers || {}) },
        body: keepMethod ? current.body : undefined,
        cookies: { ...(current.cookies || {}) },
      };
      for (const c of globalThis.__pbParseSetCookie(raw.setCookie, raw.url)) proposed.cookies[c.name] = c.value;
      if (next) {
        proposed = await next(proposed, raw);
        if (!proposed) return { raw, request: current, hops };
      }
      current = proposed;
    }
  };
})();
