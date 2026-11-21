// Paperback operation glue (U6): enumerates the sources a bundle exports and
// runs search / details-with-chapters on the original source methods, for
// both API families. Every entry point resolves to `{ok}` or `{failure}` with
// plain data, so the Dart side maps failures by code rather than by parsing
// messages. Version-specific shapes (0.8 `PagedResults.metadata`, 0.9
// `PagedResults.metadata`, chapter IDs and sorting indexes) are passed
// through untouched in `cursor`/`context`.
(function () {
  'use strict';
  const plain = globalThis.__pbPlain;
  const sources = {};

  // 0.9 throws `CloudflareError`; 0.8 sources throw a plain error whose
  // message starts with the conventional "CLOUDFLARE BYPASS ERROR" (the 0.8
  // app's own wording, which bundles copy).
  function isCloudflareError(e) {
    if (e && (e.type === 'cloudflareError' || e.name === 'CloudflareError')) return true;
    return /^\s*cloudflare bypass error/i.test(String((e && e.message) || e));
  }

  function failureOf(e) {
    const message = String((e && e.message) || e);
    if (isCloudflareError(e)) {
      return { code: 'interaction-required', message: 'The source requires a Cloudflare bypass: ' + message };
    }
    const tagged = /^\[([a-z-]+)\]\s*(.*)$/s.exec(message);
    if (tagged) return { code: tagged[1], message: tagged[2] };
    const name = (e && e.name) || 'Error';
    // A failure in an operation that met a challenge page is the challenge,
    // whatever the source made of the page ("not JSON", a parse error).
    const challenge = globalThis.__pbApi.challenge ? globalThis.__pbApi.challenge() : null;
    if (challenge) {
      return {
        code: 'interaction-required',
        message: 'Cloudflare challenged ' + challenge.url + ' (HTTP ' + challenge.status + '); the source failed with ' +
          name + ': ' + message,
      };
    }
    return { code: 'source-error', message: name + ': ' + message, stack: e && e.stack ? String(e.stack) : undefined };
  }

  function resetChallenge() {
    if (globalThis.__pbApi.resetChallenge) globalThis.__pbApi.resetChallenge();
  }

  async function guard(body) {
    globalThis.__pbTimers.rearm();
    resetChallenge();
    try {
      return { ok: plain(await body()) };
    } catch (e) {
      return { failure: failureOf(e) };
    } finally {
      resetChallenge();
    }
  }

  // 0.8 `SourceIntents.CLOUDFLARE_BYPASS_REQUIRED`.
  const CLOUDFLARE_BYPASS_REQUIRED = 16;
  const intents = {};

  // Runs [body]; when it fails on a Cloudflare challenge and the source
  // declares the bypass intent, runs the source's bypass request through the
  // host browser once and retries once. A second challenge is final.
  async function withBypass(id, body) {
    try {
      return await body();
    } catch (e) {
      const api = globalThis.__pbApi;
      const source = sources[id];
      const challenged = isCloudflareError(e) || (api.challenge && api.challenge() !== null);
      if (!challenged || !api.canBypass || !((intents[id] || 0) & CLOUDFLARE_BYPASS_REQUIRED) || !api.canBypass(source)) {
        throw e;
      }
      await api.bypass(source);
      resetChallenge();
      return await body();
    }
  }

  function str(v) {
    return v === undefined || v === null ? undefined : String(v);
  }
  function strings(v) {
    if (!v) return [];
    return [].concat(v).filter((x) => x !== undefined && x !== null && String(x).trim() !== '').map(String);
  }
  function names(v) {
    // 0.8 MangaInfo.author/artist are single strings that often list several
    // names; both families keep the source's own text when it is not a list.
    if (Array.isArray(v)) return strings(v);
    const s = str(v);
    return s && s.trim() ? [s.trim()] : [];
  }
  function tags(groups, labelKey) {
    const out = [];
    for (const g of groups || []) for (const t of (g && g.tags) || []) if (t && t[labelKey]) out.push(String(t[labelKey]));
    return out;
  }
  function rating09(r) {
    switch (r) {
      case 'SAFE':
      case 'EVERYONE': return 'safe';
      case 'MATURE': return 'suggestive';
      case 'ADULT': return 'nsfw';
      default: return 'unknown';
    }
  }

  // ---- 0.8 -------------------------------------------------------------------
  const api08 = {
    enumerate() {
      const lib = globalThis.Sources;
      if (!lib || typeof lib !== 'object') throw new Error('[artifact-incompatible] The bundle did not define Sources');
      const out = [];
      for (const key of Object.keys(lib)) {
        const info = lib[key + 'Info'];
        if (typeof lib[key] !== 'function' || !info || typeof info !== 'object') continue;
        const instance = new lib[key](globalThis.__pbLib.cheerio);
        sources[key] = instance;
        if (typeof info.intents === 'number') intents[key] = info.intents;
        out.push({
          sourceId: key,
          name: str(info.name) || key,
          version: str(info.version),
          language: str(info.language),
          contentRating: str(info.contentRating),
          websiteBaseURL: str(info.websiteBaseURL),
          intents: typeof info.intents === 'number' ? info.intents : undefined,
        });
      }
      return out;
    },
    async search(source, title, metadata) {
      const query = { title, includedTags: [], excludedTags: [], parameters: {} };
      const fn = source.getSearchResults || source.searchRequest;
      const page = await fn.call(source, query, metadata);
      return {
        items: ((page && page.results) || []).map((x) => ({
          mangaId: str(x.mangaId),
          title: str(x.title),
          imageUrl: str(x.image),
          subtitle: str(x.subtitle),
        })),
        metadataJson: page && page.metadata !== undefined && page.metadata !== null ? JSON.stringify(page.metadata) : undefined,
      };
    },
    async details(source, mangaId) {
      const manga = await source.getMangaDetails(mangaId);
      const info = (manga && manga.mangaInfo) || {};
      const titles = strings(info.titles);
      const chapters = await source.getChapters(mangaId);
      let url;
      try {
        url = source.getMangaShareUrl ? str(source.getMangaShareUrl(mangaId)) : undefined;
      } catch (_) {
        url = undefined;
      }
      return {
        mangaId: str(manga && manga.id) || mangaId,
        metadata: {
          title: titles[0] || mangaId,
          altTitles: titles.slice(1),
          authors: names(info.author),
          artists: names(info.artist),
          description: str(info.desc),
          tags: tags(info.tags, 'label'),
          status: str(info.status),
          contentRating: info.hentai === true ? 'nsfw' : 'unknown',
          url,
          coverUrl: str(info.image),
        },
        chapters: (chapters || []).map((c, i) => ({
          chapterId: str(c.id),
          sourceOrder: i,
          title: str(c.name),
          chapterNumber: typeof c.chapNum === 'number' ? c.chapNum : undefined,
          volumeNumber: typeof c.volume === 'number' ? c.volume : undefined,
          scanlators: strings(c.group),
          language: str(c.langCode),
          dateUploaded: c.time,
          context: { sortingIndex: c.sortingIndex, group: c.group, langCode: c.langCode },
        })),
      };
    },
  };

  // ---- 0.9 -------------------------------------------------------------------
  const api09 = {
    enumerate() {
      const lib = globalThis.source;
      if (!lib || typeof lib !== 'object') throw new Error('[artifact-incompatible] The bundle did not define source');
      const out = [];
      for (const key of Object.keys(lib)) {
        const v = lib[key];
        if (!v || typeof v !== 'object' || typeof v.getMangaDetails !== 'function') continue;
        sources[key] = v;
        out.push({ sourceId: key, name: key });
      }
      return out;
    },
    async initialise(source) {
      if (typeof source.initialise === 'function') await source.initialise();
    },
    async search(source, title, metadata) {
      if (typeof source.getSearchResults !== 'function') {
        throw new Error('[capability-unavailable] The source does not provide getSearchResults');
      }
      const page = await source.getSearchResults({ title }, metadata, undefined);
      return {
        items: ((page && page.items) || []).map((x) => ({
          mangaId: str(x.mangaId),
          title: str(x.title),
          imageUrl: str(x.imageUrl),
          subtitle: str(x.subtitle),
          contentRating: str(x.contentRating),
        })),
        metadataJson: page && page.metadata !== undefined && page.metadata !== null ? JSON.stringify(page.metadata) : undefined,
      };
    },
    async details(source, mangaId) {
      const manga = await source.getMangaDetails(mangaId);
      const info = (manga && manga.mangaInfo) || {};
      if (typeof source.getChapters !== 'function') {
        throw new Error('[capability-unavailable] The source does not provide getChapters');
      }
      const chapters = await source.getChapters(manga);
      return {
        mangaId: str(manga && manga.mangaId) || mangaId,
        metadata: {
          title: str(info.primaryTitle) || mangaId,
          altTitles: strings(info.secondaryTitles),
          authors: names(info.author),
          artists: names(info.artist),
          description: str(info.synopsis),
          tags: tags(info.tagGroups, 'title'),
          status: str(info.status),
          contentRating: rating09(info.contentRating),
          url: str(info.shareUrl),
          coverUrl: str(info.thumbnailUrl),
        },
        chapters: (chapters || []).map((c, i) => ({
          chapterId: str(c.chapterId),
          sourceOrder: i,
          title: str(c.title),
          chapterNumber: typeof c.chapNum === 'number' ? c.chapNum : undefined,
          volumeNumber: typeof c.volume === 'number' ? c.volume : undefined,
          scanlators: strings(c.version),
          language: str(c.langCode),
          dateUploaded: c.publishDate || c.creationDate,
          context: { sortingIndex: c.sortingIndex, version: c.version, langCode: c.langCode, additionalInfo: c.additionalInfo },
        })),
      };
    },
  };

  function family() {
    return globalThis.__pbApi.family === 'paperback-0.8' ? api08 : api09;
  }
  function sourceFor(id) {
    const s = sources[id];
    if (!s) throw new Error('[stale-reference] This package does not host source "' + id + '"');
    return s;
  }

  // Global functions: the Dart runtime calls entry points by global name.
  globalThis.__pbOpsLoad = () =>
      guard(async () => {
        const list = family().enumerate();
        if (family() === api09) for (const s of list) await api09.initialise(sources[s.sourceId]);
        return list;
      });
  globalThis.__pbOpsSearch = (id, title, metadataJson) =>
    guard(() =>
      withBypass(id, () =>
        family().search(sourceFor(id), title, metadataJson == null ? undefined : JSON.parse(metadataJson)),
      ),
    );
  globalThis.__pbOpsDetails = (id, mangaId) => guard(() => withBypass(id, () => family().details(sourceFor(id), mangaId)));
})();
