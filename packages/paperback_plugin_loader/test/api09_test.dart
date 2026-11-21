// Host contract tests for the Paperback 0.9 adapter (`Application`), using
// handwritten fixture bundles. Real bundles are exercised in
// source_execution_test.dart; these pin each host behaviour precisely.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import 'support/host_harness.dart';
import 'support/scripted_browser_port.dart';

Future<HostUnderTest> _load09(
  String source, {
  Future<http.Response> Function(http.Request request)? handler,
  PaperbackBrowserChannel? browser,
  SettingsPayload? settings,
}) => HostUnderTest.load(
  bundle09('e.Test = (function(){ $source })();'),
  PaperbackApiFamily.v09,
  handler: handler,
  browser: browser,
  settings: settings,
);

/// Wraps a body as `getSearchResults` returning `{items, metadata}`; the
/// body sees `query` and `metadata`.
String _searchSource(String body, {String fields = '', String init = ''}) =>
    '''
  return new (class {
    $fields
    async initialise() { $init }
    async getMangaDetails(id) { return { mangaId: id, mangaInfo: { primaryTitle: id, secondaryTitles: [], thumbnailUrl: '', synopsis: '', contentRating: 'EVERYONE' } }; }
    async getChapters(m) { return []; }
    async getSearchResults(query, metadata) { $body }
  })();''';

Future<SourceFailure> failureOf(Future<Object?> operation) async {
  try {
    await operation;
  } on PaperbackRuntimeException catch (e) {
    return e.failure;
  }
  throw StateError('The operation succeeded');
}

void main() {
  test('request interceptors run in registration order, response interceptors in reverse', () async {
    final HostUnderTest h = await _load09(
      _searchSource(
        '''
        const [res, data] = await Application.scheduleRequest({ url: 'https://example.test/a', method: 'GET' });
        return { items: [{ mangaId: Application.arrayBufferToUTF8String(data), title: res.headers['x-order'] || '' }] };''',
        fields: '''
          tag(name) {
            return {
              req: async (r) => ({ ...r, headers: { ...(r.headers || {}), 'x-order': ((r.headers || {})['x-order'] || '') + name } }),
              res: async (req, res, data) => new TextEncoder().encode(Application.arrayBufferToUTF8String(data) + name).buffer,
            };
          }''',
        init: '''
          const a = this.tag('A'); const b = this.tag('B');
          this.a = a; this.b = b;
          Application.registerInterceptor('a', Application.Selector(a, 'req'), Application.Selector(a, 'res'));
          Application.registerInterceptor('b', Application.Selector(b, 'req'), Application.Selector(b, 'res'));''',
      ),
      handler: (http.Request r) async =>
          http.Response('body:', 200, headers: <String, String>{'x-order': r.headers['x-order'] ?? ''}),
    );
    try {
      final PaperbackSearchPage page = await h.search('q');
      check(h.requests.single.headers['x-order']).equals('AB');
      // The body passes B's response interceptor first, then A's.
      check(page.items.single['mangaId']).equals('body:BA');
    } finally {
      h.dispose();
    }
  });

  test('user agent: the host sends what the source sets, and adds none of its own', () async {
    final HostUnderTest h = await _load09(
      _searchSource('''
        const ua = await Application.getDefaultUserAgent();
        await Application.scheduleRequest({ url: 'https://example.test/echo', method: 'GET', headers: { 'user-agent': ua } });
        await Application.scheduleRequest({ url: 'https://example.test/missing', method: 'GET' });
        return { items: [] };'''),
      handler: (http.Request r) async => http.Response('', 200),
    );
    try {
      await h.search('q');
      check(<String, String?>{
        for (final http.Request r in h.requests) r.url.path: r.headers['user-agent'],
      }).deepEquals(<String, String?>{'/echo': paperbackDefaultUserAgent, '/missing': null});
    } finally {
      h.dispose();
    }
  });

  test('redirects run through the redirect handler and carry cookies set by each hop', () async {
    final HostUnderTest h = await _load09(
      _searchSource(
        '''
        const [res, data] = await Application.scheduleRequest({ url: 'https://example.test/start', method: 'GET', cookies: { a: '1' } });
        return { items: [{ mangaId: res.url, title: Application.arrayBufferToUTF8String(data) }], metadata: { cookies: res.cookies.map((c) => c.name + '=' + c.value + '@' + c.domain) } };''',
        fields: '''async onRedirect(proposed, response) { return { ...proposed, headers: { ...proposed.headers, 'x-hop': String(response.status) } }; }''',
        init: '''Application.setRedirectHandler(Application.Selector(this, 'onRedirect'));''',
      ),
      handler: (http.Request r) async => switch (r.url.path) {
        '/start' => http.Response(
          '',
          302,
          headers: <String, String>{'location': '/final', 'set-cookie': 'sid=xyz; Path=/'},
        ),
        '/final' => http.Response(
          'cookie=${r.headers['cookie']} hop=${r.headers['x-hop']}',
          200,
          headers: <String, String>{'set-cookie': 'late=1; Domain=.example.test'},
        ),
        _ => http.Response('', 404),
      },
    );
    try {
      final PaperbackSearchPage page = await h.search('q');
      check(h.requests.map((http.Request r) => r.url.path).toList()).deepEquals(<String>['/start', '/final']);
      check(page.items.single['mangaId']).equals('https://example.test/final');
      check(page.items.single['title']).equals('cookie=a=1; sid=xyz; hop=302');
      check(page.nextCursor).equals(
        jsonEncode(<String, Object?>{
          'cookies': <Object?>['late=1@example.test'],
        }),
      );
    } finally {
      h.dispose();
    }
  });

  test('binary bodies, non-ASCII text and pagination metadata survive intact', () async {
    final binary = <int>[0, 255, 254, 1, 128, 10];
    final HostUnderTest h = await _load09(
      _searchSource('''
        const [, bin] = await Application.scheduleRequest({ url: 'https://example.test/bin', method: 'GET' });
        const [, txt] = await Application.scheduleRequest({ url: 'https://example.test/txt', method: 'POST', body: 'é' });
        const page = (metadata && metadata.page) || 1;
        return {
          items: [{ mangaId: Application.base64Encode(bin), title: Application.arrayBufferToUTF8String(txt) }],
          metadata: { page: page + 1, token: 'tök€n', seen: metadata || null },
        };'''),
      handler: (http.Request r) async => r.url.path == '/bin'
          ? http.Response.bytes(binary, 200, headers: <String, String>{'content-type': 'application/octet-stream'})
          : http.Response.bytes(utf8.encode('おにまい ${utf8.decode(r.bodyBytes)}'), 200),
    );
    try {
      final PaperbackSearchPage first = await h.search('q');
      check(base64.decode(first.items.single['mangaId']! as String)).deepEquals(binary);
      check(first.items.single['title']).equals('おにまい é');
      final PaperbackSearchPage second = await h.search('q', first.nextCursor);
      check(jsonDecode(second.nextCursor!) as Map<String, Object?>)
        ..has((Map<String, Object?> m) => m['page'], 'page').equals(3)
        ..has((Map<String, Object?> m) => jsonEncode(m['seen']), 'seen').equals(first.nextCursor!);
    } finally {
      h.dispose();
    }
  });

  test('a sleep promise parked at the end of one operation settles in the next', () async {
    final HostUnderTest h = await _load09(
      _searchSource('''
        if (query.title === 'park') { this.parked = Application.sleep(0.15).then(() => 'woke'); return { items: [] }; }
        return { items: [{ mangaId: await this.parked, title: 't' }] };'''),
    );
    try {
      await h.search('park');
      final PaperbackSearchPage page = await h.search('wait');
      check(page.items.single['mangaId']).equals('woke');
    } finally {
      h.dispose();
    }
  });

  test('settings seed state, string sets and source scopes; secrets reach secure state only', () async {
    final HostUnderTest h = await _load09(
      _searchSource(
        '''
        return { items: [{ mangaId: JSON.stringify([Application.getState('lang'), Application.getState('genres'), Application.getState('token'), Application.getSecureState('token')]), title: 't' }] };''',
      ),
      settings: SettingsPayload.fromSnapshot(
        SettingsSnapshot(
          values: const <String, Object>{
            'lang': 'en',
            'genres': <String>['b', 'a', 'a'],
          },
          secrets: const <String, String>{'token': 'pkg-secret'},
          sources: <String, SourceScopedSettings>{
            'Test': SourceScopedSettings(
              values: const <String, Object>{'lang': 'ja'},
              secrets: const <String, String>{'token': 'scoped-secret'},
            ),
          },
        ),
      ),
    );
    try {
      final PaperbackSearchPage page = await h.search('q');
      check(page.items.single['mangaId']).equals(
        jsonEncode(<Object?>[
          'ja',
          <Object?>['a', 'b'],
          null,
          'scoped-secret',
        ]),
      );
    } finally {
      h.dispose();
    }
  });

  test('an Application member this host does not provide fails as a named capability', () async {
    final HostUnderTest h = await _load09(
      _searchSource('Application.crypto_digest("SHA-256", new ArrayBuffer(1)); return { items: [] };'),
    );
    try {
      check(await failureOf(h.search('q')))
          .isA<CapabilityUnavailableFailure>()
          .has((CapabilityUnavailableFailure f) => f.operation, 'operation')
          .equals('Application.crypto_digest');
    } finally {
      h.dispose();
    }
  });

  test('a CloudflareError is reported as interaction-required, not a source error', () async {
    final HostUnderTest h = await _load09(
      _searchSource('''
        const err = new Error('Cloudflare bypass is required'); err.type = 'cloudflareError'; err.resolutionRequest = { url: 'https://example.test/' };
        throw err;'''),
    );
    try {
      check(await failureOf(h.search('q'))).isA<InteractionRequiredFailure>();
    } finally {
      h.dispose();
    }
  });

  group('executeInWebView', () {
    const identity = SourceIdentity(
      ecosystem: 'paperback',
      packageId: 'pkg',
      sourceId: 'Test',
      artifact: ArtifactBinding(sha256: 'x', kind: 'paperback-bundle-0.9', version: '1'),
    );
    const webviewSource = '''
      const r = await Application.executeInWebView({
        source: { html: '<html><head></head><body>hi</body></html>', baseUrl: 'https://example.test/page', loadCSS: false, loadImages: false, userAgent: await Application.getDefaultUserAgent() },
        inject: 'return window.__capture;',
        storage: { cookies: [{ name: 'sid', value: 'abc', domain: 'example.test' }] },
      });
      return { items: [{ mangaId: JSON.stringify(r.result), title: r.storage.cookies.map((c) => c.name + '=' + c.value).sort().join(',') }] };''';

    test('runs through the BrowserPort with the source context, and returns result and cookies', () async {
      final port = ScriptedBrowserPort(
        respond: (ScriptedPage page) => <String, Object?>{
          'matched': '/api/x?vrf=1',
          'html': page.html,
          'base': page.baseUrl.toString(),
        },
        setCookiesOnLoad: const <BrowserCookie>[
          BrowserCookie(name: 'cf_clearance', value: 'ok', domain: 'example.test'),
        ],
      );
      final channel = InProcessBrowserChannel(port: port, source: identity);
      final HostUnderTest h = await HostUnderTest.load(
        bundle09('e.Test = (function(){ ${_searchSource(webviewSource)} })();'),
        PaperbackApiFamily.v09,
        browser: channel,
      );
      try {
        // The package is "pkg" and its source "Test", matching [identity].
        final PaperbackSearchPage page = await h.search('q');
        final result = jsonDecode(page.items.single['mangaId']! as String) as Map<String, Object?>;
        check(result['matched']).equals('/api/x?vrf=1');
        check(result['html']).equals('<html><head></head><body>hi</body></html>');
        check(result['base']).equals('https://example.test/page');
        check(page.items.single['title']).equals('cf_clearance=ok,sid=abc');
        check(port.pages.single.userAgent).equals(paperbackDefaultUserAgent);
        check(port.pages.single.scripts.single).contains('return window.__capture;');
        check(port.closed).length.equals(1);
      } finally {
        h.dispose();
        await channel.close();
      }
    });

    test('a port that cannot evaluate yields capability-unavailable, never an empty result', () async {
      final port = ScriptedBrowserPort(respond: (_) => null, evaluateUnavailable: true);
      final channel = InProcessBrowserChannel(port: port, source: identity);
      final HostUnderTest h = await HostUnderTest.load(
        bundle09('e.Test = (function(){ ${_searchSource(webviewSource)} })();'),
        PaperbackApiFamily.v09,
        browser: channel,
      );
      try {
        check(await failureOf(h.search('q'))).isA<CapabilityUnavailableFailure>();
        check(port.closed).length.equals(1);
      } finally {
        h.dispose();
        await channel.close();
      }
    });

    test('without a browser port the call fails as capability-unavailable', () async {
      final HostUnderTest h = await _load09(_searchSource(webviewSource));
      try {
        check(await failureOf(h.search('q')))
            .isA<CapabilityUnavailableFailure>()
            .has((CapabilityUnavailableFailure f) => f.operation, 'operation')
            .equals('executeInWebView');
      } finally {
        h.dispose();
      }
    });
  });
}
