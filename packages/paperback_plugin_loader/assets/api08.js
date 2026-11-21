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
// does for 0.8 sources. `response.headers['set-cookie']` is an array of
// values, as axios reports it.
//
// Cloudflare (`SourceIntents.CLOUDFLARE_BYPASS_REQUIRED`, 16): `schedule`
// flags a challenge response (403/503 with a challenge page, or
// `cf-mitigated: challenge`) for the running operation, and `bypass` runs the
// source's `getCloudflareBypassRequestAsync()` request through the host
// browser. The browser's cookies and user agent become a clearance: requests
// to the cleared domain carry those cookies and, where the source echoes
// `getDefaultUserAgent()` or sets none, the browser's user agent, because a
// clearance cookie is only honoured with the user agent that earned it.
(function () {
  'use strict';
  const H = globalThis.__pbHost;
  const { toBytes } = globalThis.__pbBytes;

  let state = {};
  let secureState = {};
  // Clearances earned through the browser: `{host, userAgent, cookies}`.
  let clearances = [];
  // The first challenge the running operation met, if any.
  let challenge = null;
  const managers = [];

  const challengeMarkers = /just a moment|attention required|challenge-platform|cf-chl|_cf_chl_opt/i;

  function isChallenge(status, headers, text) {
    const mitigated = String((headers && headers['cf-mitigated']) || '').toLowerCase();
    if (mitigated === 'challenge') return true;
    return (status === 403 || status === 503) && challengeMarkers.test(text);
  }

  function clearanceFor(host) {
    return clearances.find(
      (c) => domainMatches(host, c.host) || c.cookies.some((k) => k.domain && domainMatches(host, k.domain)),
    );
  }

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
      const cleared = clearanceFor(host);
      // One value per cookie name: a browser clearance, then the manager's
      // store (later `Set-Cookie`s), then the request's own cookies, which
      // win. A source that pairs a cookie with a header carrying the same
      // token must not see a second, stale copy of that cookie on the wire.
      const jar = new Map();
      for (const c of (cleared && cleared.cookies) || []) {
        if (!c.domain || domainMatches(host, c.domain)) jar.set(c.name, c.value);
      }
      for (const c of this._jar) if (domainMatches(host, c.domain)) jar.set(c.name, c.value);
      for (const c of request.cookies || []) jar.set(c.name, c.value);
      let cookieData = '';
      for (const [name, value] of jar) cookieData += name + '=' + value + ';';
      if (cookieData) headers['cookie'] = cookieData;
      // A missing user agent becomes `Paperback-iOS` (reference host). A source
      // that echoes `getDefaultUserAgent()` sends none, so the HTTP client's
      // own applies, as for 0.9 sources that set none: the host is not a
      // browser. MangaDex's edge challenged the echoed browser string and not
      // the client's own (one capture run each, consistent with, not proof
      // of, the cause). A source-chosen value is sent as is.
      // Exception: on a domain cleared through the browser, a missing or
      // echoed user agent becomes the browser's, which the clearance is bound to.
      const uaKey = Object.keys(headers).find((k) => k.toLowerCase() === 'user-agent');
      const echoed = uaKey === undefined || headers[uaKey] === H.defaultUserAgent;
      if (echoed && cleared && cleared.userAgent) {
        if (uaKey !== undefined) delete headers[uaKey];
        headers['user-agent'] = cleared.userAgent;
      } else if (uaKey === undefined) {
        headers['user-agent'] = 'Paperback-iOS';
      } else if (headers[uaKey] === H.defaultUserAgent) {
        delete headers[uaKey];
      }
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
      const data = H.utf8Decode(raw.body);
      if (!challenge && isChallenge(raw.status, raw.headers, data)) challenge = { url, status: raw.status };
      const responseHeaders = { ...raw.headers };
      if (raw.setCookie && raw.setCookie.length) responseHeaders['set-cookie'] = raw.setCookie.slice();
      let response = {
        rawData: rawData(raw.body),
        data,
        status: raw.status,
        headers: responseHeaders,
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
    createRequestManager: (info) => {
      const m = new RequestManager(info || {});
      managers.push(m);
      return m;
    },
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

  // Runs [source]'s `getCloudflareBypassRequestAsync()` request in the host
  // browser and keeps the clearance it yields. The browser is seeded with the
  // cookies the host holds for that domain, and its cookies come back.
  async function bypass(source) {
    const req = await source.getCloudflareBypassRequestAsync();
    const url = req.url + (req.param ?? '');
    const host = H.hostOf(url);
    const headers = {};
    let userAgent;
    for (const k of Object.keys(req.headers || {})) {
      const lower = k.toLowerCase();
      if (lower === 'cookie') continue;
      if (lower === 'user-agent') {
        // An echoed default is not a choice: the browser keeps its own.
        if (req.headers[k] !== H.defaultUserAgent) userAgent = String(req.headers[k]);
        continue;
      }
      headers[k] = String(req.headers[k]);
    }
    const seed = new Map();
    const prior = clearanceFor(host);
    for (const c of (prior && prior.cookies) || []) seed.set(c.name, c);
    for (const m of managers) for (const c of m._jar) if (domainMatches(host, c.domain)) seed.set(c.name, c);
    for (const c of req.cookies || []) seed.set(c.name, c);
    const result = await H.cloudflareBypass(
      globalThis.__pbPlain({
        url,
        headers,
        userAgent,
        cookies: [...seed.values()].map((c) => ({
          name: String(c.name),
          value: String(c.value),
          domain: c.domain ? String(c.domain) : undefined,
          path: c.path ? String(c.path) : undefined,
        })),
      }),
    );
    clearances = clearances.filter((c) => c.host !== host);
    clearances.push({
      host,
      userAgent: result.userAgent || userAgent,
      cookies: (result.cookies || []).map((c) => ({ name: c.name, value: c.value, domain: c.domain, path: c.path })),
    });
  }

  globalThis.__pbApi = {
    family: 'paperback-0.8',
    seed(values, secrets) {
      state = { ...values };
      secureState = { ...secrets };
    },
    state: () => state,
    resetChallenge() {
      challenge = null;
    },
    challenge: () => challenge,
    canBypass: (source) => H.hasBrowser === true && typeof source.getCloudflareBypassRequestAsync === 'function',
    bypass,
    clearances: () => clearances,
  };
})();
