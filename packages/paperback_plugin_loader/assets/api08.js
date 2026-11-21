// Paperback 0.8 host adapter (U6, KTD6): the `App` global declared by
// @paperback/types 0.8.x (`src/generated/Exports/*.ts`).
//
// Semantics follow the 0.8 toolchain's reference host,
// @paperback/runtime-polyfills 0.8.7 (`RequestManager.ts`, `RawData.ts`,
// `SourceStateManager.ts`), which the toolchain's source tester loads before
// `new Sources[id](cheerio)`:
// - `schedule` runs `interceptor.interceptRequest`, sends `url + param`,
//   then runs `interceptor.interceptResponse` on the packed response;
// - cookies become one `cookie` header (`a=1;b=2;`), a missing user agent
//   becomes `Paperback-iOS` (an echoed `getDefaultUserAgent()` is not sent;
//   see `schedule`);
// - an object body is form-encoded when the content type says so, otherwise
//   JSON (axios' default);
// - `rawData` is the body bytes with a UTF-8 `toString`.
// Redirects are followed as axios does. Unlike the axios mock, a non-2xx
// status resolves rather than rejects: 0.8 sources inspect
// `response.status` themselves (for example for Cloudflare), which they
// could not do if the host rejected. `requestsPerSecond` is enforced and the
// manager keeps an in-memory cookie store, as the 0.9 compatibility wrapper
// does for 0.8 sources.
(function () {
  'use strict';
  const H = globalThis.__pbHost;
  const { toBytes } = globalThis.__pbBytes;

  let state = {};
  let secureState = {};

  function rawData(bytes) {
    const data = new Uint8Array(bytes);
    Object.defineProperty(data, 'toString', { enumerable: false, value: () => H.utf8Decode(data) });
    return data;
  }

  function domainMatches(host, domain) {
    if (!domain) return true;
    const d = String(domain).replace(/^\./, '').toLowerCase();
    const h = String(host).toLowerCase();
    return h === d || h.endsWith('.' + d);
  }

  function encodeBody(data, headers) {
    if (data === undefined || data === null) return undefined;
    if (typeof data === 'string') return data;
    if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) return toBytes(data);
    if (typeof data === 'object') {
      const ct = Object.keys(headers).find((k) => k.toLowerCase() === 'content-type');
      if (ct && String(headers[ct]).includes('application/x-www-form-urlencoded')) {
        return Object.keys(data).map((k) => k + '=' + data[k]).join('&');
      }
      if (!ct) headers['content-type'] = 'application/json';
      return JSON.stringify(data);
    }
    return String(data);
  }

  class RequestManager {
    constructor(info) {
      this.interceptor = info.interceptor;
      this.requestsPerSecond = info.requestsPerSecond ?? 2.5;
      this.requestTimeout = info.requestTimeout ?? 20000;
      const jar = [];
      this._jar = jar;
      this.cookieStore = {
        getAllCookies: () => jar.slice(),
        addCookie(cookie) {
          const i = jar.findIndex((c) => c.name === cookie.name && (c.domain || '') === (cookie.domain || ''));
          if (i >= 0) jar.splice(i, 1);
          jar.push(cookie);
        },
        removeCookie(cookie) {
          const i = jar.findIndex((c) => c.name === cookie.name && (c.domain || '') === (cookie.domain || ''));
          if (i >= 0) jar.splice(i, 1);
        },
      };
      this._nextSlot = 0;
    }

    async getDefaultUserAgent() {
      return H.defaultUserAgent;
    }

    async _throttle() {
      const rps = Number(this.requestsPerSecond);
      if (!(rps > 0)) return;
      const spacing = 1000 / rps;
      const now = Date.now();
      const slot = Math.max(now, this._nextSlot);
      this._nextSlot = slot + spacing;
      if (slot > now) await new Promise((resolve) => setTimeout(resolve, slot - now));
    }

    async schedule(request, retry) {
      await this._throttle();
      if (this.interceptor) request = await this.interceptor.interceptRequest(request);
      const headers = { ...(request.headers || {}) };
      const url = request.url + (request.param ?? '');
      const host = H.hostOf(url);
      let cookieData = '';
      for (const c of this._jar) if (domainMatches(host, c.domain)) cookieData += c.name + '=' + c.value + ';';
      for (const c of request.cookies || []) cookieData += c.name + '=' + c.value + ';';
      if (cookieData) headers['cookie'] = cookieData;
      // A missing user agent becomes `Paperback-iOS` (reference host). A source
      // that echoes `getDefaultUserAgent()` sends none, so the HTTP client's
      // own applies, as for 0.9 sources that set none: the host is not a
      // browser. MangaDex's edge challenged the echoed browser string and not
      // the client's own (one capture run each, consistent with, not proof
      // of, the cause). A source-chosen value is sent as is.
      const uaKey = Object.keys(headers).find((k) => k.toLowerCase() === 'user-agent');
      if (uaKey === undefined) headers['user-agent'] = 'Paperback-iOS';
      else if (headers[uaKey] === H.defaultUserAgent) delete headers[uaKey];
      const body = encodeBody(request.data, headers);
      const wire = { url, method: String(request.method || 'GET').toUpperCase(), headers, body, timeoutMs: this.requestTimeout };
      let attempts = Math.max(0, Number(retry) || 0);
      let raw;
      let hops = [];
      for (;;) {
        try {
          ({ raw, hops } = await globalThis.__pbFetchFollowing(wire, undefined, 5));
          break;
        } catch (e) {
          if (attempts-- <= 0 || String(e && e.message).includes('[capture-miss]')) throw e;
        }
      }
      for (const hop of hops) {
        for (const c of globalThis.__pbParseSetCookie(hop.setCookie, hop.url)) this.cookieStore.addCookie(c);
      }
      let response = {
        rawData: rawData(raw.body),
        data: H.utf8Decode(raw.body),
        status: raw.status,
        headers: raw.headers,
        request,
      };
      if (this.interceptor) response = await this.interceptor.interceptResponse(response);
      return response;
    }
  }

  function stateManager() {
    return {
      keychain: {
        async store(key, value) { secureState[key] = value; },
        async retrieve(key) { return secureState[key]; },
      },
      async store(key, value) { state[key] = value; },
      async retrieve(key) { return state[key]; },
    };
  }

  const factories = {
    createRequestManager: (info) => new RequestManager(info || {}),
    createSourceStateManager: stateManager,
    createRawData: ({ byteArray }) => rawData(toBytes(byteArray)),
    createByteArray: (raw) => new Uint8Array(raw),
    createRequest: (info) => ({ headers: {}, cookies: [], ...info }),
  };

  // Every other `create*` factory returns its argument (the reference proxy);
  // `createDUI*` rows also carry their type, as the 0.9 compatibility shim
  // records it.
  globalThis.App = new Proxy(factories, {
    get(target, p) {
      if (target[p]) return target[p];
      if (typeof p === 'string' && p.startsWith('createDUI')) {
        const type = p.slice(6);
        return (props) => Object.defineProperty(props || {}, 'type', { enumerable: true, value: type });
      }
      if (typeof p === 'string' && p.startsWith('create')) return (props) => props;
      return undefined;
    },
  });

  globalThis.__pbApi = {
    family: 'paperback-0.8',
    seed(values, secrets) {
      state = { ...values };
      secureState = { ...secrets };
    },
    state: () => state,
  };
})();
