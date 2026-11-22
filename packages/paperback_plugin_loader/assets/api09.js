// Paperback 0.9 host adapter (U6, KTD6): the `Application` global declared by
// @paperback/types 1.0.0-alpha.94 (`lib/impl/Application.d.ts`).
//
// Semantics follow the toolchain's reference host,
// @paperback/runtime-polyfills 1.0.0-alpha.94 (MIT):
// - request interceptors run in registration order, response interceptors in
//   reverse order;
// - `request.cookies` becomes one `Cookie` header (`a=1; b=2;`);
// - `Set-Cookie` values become `response.cookies`;
// - an object body is sent as multipart form data (the reference's FormData).
// Two deliberate differences from that mock, both towards the app contract in
// the type docs: each request interceptor receives the previous interceptor's
// result (the mock passes the original request to every one), and redirects
// are followed hop by hop through `setRedirectHandler` (the mock ignores it).
(function () {
  'use strict';
  const H = globalThis.__pbHost;
  const { toBytes, toArrayBuffer } = globalThis.__pbBytes;

  let state = {};
  let secureState = {};

  // ---- selectors -------------------------------------------------------------
  const registry = {};
  let selectorSeq = 0;
  const SelectorRegistry = {
    registerSelector(id, obj, key) { registry[id] = { obj, key }; },
    unregisterSelector(id) { delete registry[id]; },
    selector(id) {
      if (typeof id === 'function') return id;
      const ref = registry[id];
      if (!ref) return undefined;
      const value = ref.obj[ref.key];
      return typeof value === 'function' ? value.bind(ref.obj) : value;
    },
  };
  function Selector(obj, key) {
    const marker = '$__selector_' + String(key);
    let id = obj[marker];
    if (!id) {
      id = 'selector-' + ++selectorSeq;
      Object.defineProperty(obj, marker, { enumerable: false, value: id });
    }
    SelectorRegistry.registerSelector(id, obj, key);
    return id;
  }

  // ---- networking ------------------------------------------------------------
  const interceptors = [];
  let redirectHandler;

  function wireRequest(request) {
    if (!request || typeof request.url !== 'string') throw new TypeError('scheduleRequest: request.url must be a string');
    const wire = {
      url: request.url,
      method: String(request.method || 'GET').toUpperCase(),
      headers: { ...(request.headers || {}) },
      cookies: { ...(request.cookies || {}) },
    };
    const body = request.body;
    if (body !== undefined && body !== null) {
      if (typeof body === 'string') wire.body = body;
      else if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) wire.body = toBytes(body);
      else if (typeof body === 'object') {
        const form = {};
        for (const k of Object.keys(body)) {
          const v = body[k];
          if (v !== undefined && v !== null) form[k] = String(v);
        }
        wire.body = { __form: form };
      }
    }
    return wire;
  }

  function responseOf(raw) {
    return {
      url: raw.url,
      headers: raw.headers,
      status: raw.status,
      mimeType: (raw.headers['content-type'] || '').split(';')[0].trim() || undefined,
      cookies: globalThis.__pbParseSetCookie(raw.setCookie, raw.url),
    };
  }

  async function scheduleRequest(request) {
    let finalRequest = request;
    for (const i of interceptors.slice()) {
      const fn = SelectorRegistry.selector(i.request);
      if (fn) finalRequest = await fn(finalRequest);
    }
    const handler = redirectHandler === undefined ? undefined : SelectorRegistry.selector(redirectHandler);
    const { raw, request: sent } = await globalThis.__pbFetchFollowing(
      wireRequest(finalRequest),
      handler
        ? async (proposed, rawResponse) => {
            const replaced = await handler(proposed, responseOf(rawResponse));
            return replaced ? wireRequest(replaced) : undefined;
          }
        : undefined,
    );
    const response = responseOf(raw);
    let data = toArrayBuffer(raw.body);
    const ordered = interceptors.slice();
    const lastRequest = sent.url === finalRequest.url ? finalRequest : { ...finalRequest, url: sent.url, method: sent.method };
    for (let i = ordered.length - 1; i >= 0; i--) {
      const fn = SelectorRegistry.selector(ordered[i].response);
      if (fn) data = await fn(lastRequest, response, data);
    }
    return [response, data];
  }

  function webviewCookie(c) {
    return { name: c.name, value: c.value, domain: c.domain, path: c.path, expires: c.expires };
  }

  async function executeInWebView(context) {
    const source = (context && context.source) || {};
    const result = await H.webview(
      globalThis.__pbPlain({
        html: source.html,
        baseUrl: source.baseUrl,
        userAgent: source.userAgent,
        inject: context.inject,
        cookies: ((context.storage && context.storage.cookies) || []).map(webviewCookie),
      }),
    );
    return {
      result: result.result,
      storage: {
        cookies: (result.cookies || []).map((c) => ({ ...c, expires: c.expires ? new Date(c.expires) : undefined })),
      },
    };
  }

  // ---- encodings -------------------------------------------------------------
  function bytesOrString(bytes) {
    try {
      return H.utf8DecodeStrict(bytes);
    } catch (_) {
      return toArrayBuffer(bytes);
    }
  }

  const discoverSections = [];
  const app = {
    isResourceLimited: false,
    filterAdultTitles: false,
    filterMatureTitles: false,
    decodeHTMLEntities: (s) => globalThis.__pbLib.decodeHTMLStrict(String(s)),
    sleep: (seconds) => new Promise((resolve) => setTimeout(resolve, Number(seconds) * 1000)),
    registerDiscoverSection(section) { discoverSections.push(section); },
    unregisterDiscoverSection(id) {
      const i = discoverSections.findIndex((s) => s.id === id);
      if (i >= 0) discoverSections.splice(i, 1);
    },
    registeredDiscoverSections: () => discoverSections.slice(),
    invalidateDiscoverSections() { discoverSections.length = 0; },
    registerInterceptor(id, requestSelector, responseSelector) {
      app.unregisterInterceptor(id);
      interceptors.push({ id, request: requestSelector, response: responseSelector });
    },
    unregisterInterceptor(id) {
      const i = interceptors.findIndex((x) => x.id === id);
      if (i >= 0) interceptors.splice(i, 1);
    },
    setRedirectHandler(selector) { redirectHandler = selector; },
    getDefaultUserAgent: async () => H.defaultUserAgent,
    scheduleRequest,
    arrayBufferToUTF8String: (b) => H.utf8Decode(toBytes(b)),
    arrayBufferToASCIIString: (b) => H.latin1Decode(toBytes(b)),
    arrayBufferToUTF16String: (b) => H.utf16Decode(toBytes(b)),
    base64Encode(value) {
      const bytes = typeof value === 'string' ? H.utf8Encode(value) : toBytes(value);
      return H.base64Encode(bytes);
    },
    base64Decode(value) {
      const bytes = typeof value === 'string' ? H.base64Decode(value) : toBytes(value);
      return bytesOrString(bytes);
    },
    crypto_md5Hash: (value) => H.md5(typeof value === 'string' ? H.utf8Encode(value) : toBytes(value)),
    getSecureState: (key) => secureState[key],
    setSecureState(value, key) { secureState[key] = value; },
    getState: (key) => state[key],
    setState(value, key) { state[key] = value; },
    resetAllState() { state = {}; },
    executeInWebView,
    formDidChange() {},
    console_log: (msg) => console.log(...[].concat(msg)),
    console_warn: (msg) => console.warn(...[].concat(msg)),
    console_error: (msg) => console.error(...[].concat(msg)),
    SelectorRegistry,
    Selector,
  };

  // Any other member is a host capability this adapter does not provide: it
  // exists (so feature probes behave) but calling it fails with a named
  // capability error rather than returning an empty value.
  globalThis.Application = new Proxy(app, {
    get(target, p) {
      if (p in target || typeof p !== 'string' || p === 'then' || p === 'toJSON') return target[p];
      return function () {
        throw new Error('[capability-unavailable] Application.' + p + ' is not provided by this host');
      };
    },
  });

  globalThis.__pbApi = {
    family: 'paperback-0.9',
    seed(values, secrets) {
      state = { ...values };
      secureState = { ...secrets };
    },
    state: () => state,
  };
})();
