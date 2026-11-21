// Host contract tests for the Paperback 0.8 adapter (`App`, injected
// Cheerio), using handwritten fixture bundles. Real bundles are exercised in
// source_execution_test.dart.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import 'support/host_harness.dart';

/// A 0.8 source class whose `getSearchResults(query, metadata)` runs [body]
/// with `this.cheerio`, `this.requestManager` (from [manager]) and
/// `this.stateManager` in scope.
Future<HostUnderTest> _load08(
  String body, {
  String manager = '{}',
  Future<http.Response> Function(http.Request request)? handler,
  SettingsPayload? settings,
}) => HostUnderTest.load(
  bundle08('''
    exports.TestInfo = { name: 'Test Source', version: '1.0.0', language: 'en', contentRating: 'EVERYONE' };
    exports.Test = class {
      constructor(cheerio) {
        this.cheerio = cheerio;
        this.requestManager = App.createRequestManager($manager);
        this.stateManager = App.createSourceStateManager();
      }
      async getMangaDetails(id) { return App.createSourceManga({ id, mangaInfo: App.createMangaInfo({ titles: [id], image: '', desc: '', status: 'Ongoing' }) }); }
      async getChapters(id) { return []; }
      async getSearchResults(query, metadata) { $body }
    };'''),
  PaperbackApiFamily.v08,
  handler: handler,
  settings: settings,
);

PaperbackSearchPage _one(String id, [String title = 't']) => PaperbackSearchPage(
  items: <Map<String, Object?>>[
    <String, Object?>{'mangaId': id, 'title': title},
  ],
);

void main() {
  test('the source is constructed with the injected Cheerio and its Info is enumerated', () async {
    final HostUnderTest h = await _load08(
      "return App.createPagedResults({ results: [App.createPartialSourceManga({ mangaId: typeof this.cheerio.load, title: 'x', image: '' })] });",
    );
    try {
      check(h.host.sources.values.single)
        ..has((PaperbackLoadedSource s) => s.sourceId, 'sourceId').equals('Test')
        ..has((PaperbackLoadedSource s) => s.name, 'name').equals('Test Source')
        ..has((PaperbackLoadedSource s) => s.language, 'language').equals('en');
      check((await h.search('q')).items.single['mangaId']).equals('function');
    } finally {
      h.dispose();
    }
  });

  test('schedule runs interceptRequest, sends url+param, then interceptResponse on the packed response', () async {
    final HostUnderTest h = await _load08(
      '''
      const res = await this.requestManager.schedule(App.createRequest({ url: 'https://example.test/s', param: '?q=1', method: 'GET' }), 1);
      return App.createPagedResults({ results: [App.createPartialSourceManga({ mangaId: res.data, title: String(res.status) + ' ' + res.request.headers['x-intercepted'], image: '' })] });''',
      manager: '''
{
        interceptor: {
          interceptRequest: async (r) => { r.headers = { ...r.headers, 'x-intercepted': 'yes' }; return r; },
          interceptResponse: async (res) => ({ ...res, data: res.data + '+intercepted' }),
        },
      }''',
      handler: (http.Request r) async =>
          http.Response('${r.url.query}|${r.headers['x-intercepted']}|${r.headers['user-agent']}', 201),
    );
    try {
      final PaperbackSearchPage page = await h.search('q');
      check(page.items.single['mangaId']).equals('q=1|yes|Paperback-iOS+intercepted');
      check(page.items.single['title']).equals('201 yes');
    } finally {
      h.dispose();
    }
  });

  test('bodies: form-urlencoded objects, JSON objects, raw strings', () async {
    final HostUnderTest h = await _load08(
      '''
      const a = await this.requestManager.schedule(App.createRequest({ url: 'https://example.test/form', method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, data: { a: '1', b: 'two' } }), 0);
      const b = await this.requestManager.schedule(App.createRequest({ url: 'https://example.test/json', method: 'POST', data: { x: [1, 2] } }), 0);
      const c = await this.requestManager.schedule(App.createRequest({ url: 'https://example.test/raw', method: 'POST', data: 'plain' }), 0);
      return App.createPagedResults({ results: [a, b, c].map((r) => App.createPartialSourceManga({ mangaId: r.data, title: 't', image: '' })) });''',
      handler: (http.Request r) async => http.Response('${r.headers['content-type']}|${r.body}', 200),
    );
    try {
      final List<Object?> bodies = (await h.search('q')).items.map((Map<String, Object?> i) => i['mangaId']).toList();
      check(bodies).deepEquals(<Object?>[
        'application/x-www-form-urlencoded|a=1&b=two',
        'application/json|{"x":[1,2]}',
        'null|plain',
      ]);
    } finally {
      h.dispose();
    }
  });

  test('redirects are followed, cookies persist in the manager store, binary and UTF-8 survive', () async {
    final binary = <int>[0, 255, 128, 7];
    final HostUnderTest h = await _load08(
      '''
      const r1 = await this.requestManager.schedule(App.createRequest({ url: 'https://example.test/login', method: 'GET', cookies: [App.createCookie({ name: 'pref', value: 'x', domain: 'example.test' })] }), 0);
      const r2 = await this.requestManager.schedule(App.createRequest({ url: 'https://example.test/bin', method: 'GET' }), 0);
      const bytes = Array.from(r2.rawData);
      return App.createPagedResults({
        results: [App.createPartialSourceManga({ mangaId: r1.data, title: JSON.stringify(bytes), image: '', subtitle: this.requestManager.cookieStore.getAllCookies().map((c) => c.name).join(',') })],
      });''',
      handler: (http.Request r) async => switch (r.url.path) {
        '/login' => http.Response(
          '',
          301,
          headers: <String, String>{'location': 'https://example.test/home', 'set-cookie': 'sid=1; Path=/'},
        ),
        '/home' => http.Response.bytes(utf8.encode('ようこそ ${r.headers['cookie']}'), 200),
        '/bin' => http.Response.bytes(binary, 200, headers: <String, String>{'x-cookie': r.headers['cookie'] ?? ''}),
        _ => http.Response('', 404),
      },
    );
    try {
      final Map<String, Object?> item = (await h.search('q')).items.single;
      // Cookies set by a redirect hop travel with the next hop.
      check(item['mangaId']).equals('ようこそ pref=x; sid=1;');
      check(jsonDecode(item['title']! as String) as List<Object?>).deepEquals(binary);
      check(item['subtitle']).equals('sid');
      check(h.requests.map((http.Request r) => r.url.path).toList()).deepEquals(<String>['/login', '/home', '/bin']);
      check(h.requests.last.headers['cookie']).equals('sid=1;');
    } finally {
      h.dispose();
    }
  });

  test('requestsPerSecond spaces requests through JS timers', () async {
    final HostUnderTest h = await _load08(
      '''
      const start = Date.now();
      for (let i = 0; i < 3; i++) await this.requestManager.schedule(App.createRequest({ url: 'https://example.test/r' + i, method: 'GET' }), 0);
      return App.createPagedResults({ results: [App.createPartialSourceManga({ mangaId: String(Date.now() - start), title: 't', image: '' })] });''',
      manager: '{ requestsPerSecond: 10 }',
      handler: (http.Request r) async => http.Response('ok', 200),
    );
    try {
      final int elapsed = int.parse((await h.search('q')).items.single['mangaId']! as String);
      check(elapsed).isGreaterOrEqual(190);
    } finally {
      h.dispose();
    }
  });

  test('state manager and keychain are seeded from settings, secrets only in the keychain', () async {
    final HostUnderTest h = await _load08(
      '''
      const v = [await this.stateManager.retrieve('languages'), await this.stateManager.retrieve('password'), await this.stateManager.keychain.retrieve('password')];
      await this.stateManager.store('later', 1);
      return App.createPagedResults({ results: [App.createPartialSourceManga({ mangaId: JSON.stringify(v), title: String(await this.stateManager.retrieve('later')), image: '' })] });''',
      settings: SettingsPayload.fromSnapshot(
        SettingsSnapshot(
          values: const <String, Object>{
            'languages': <String>['vi', 'en'],
          },
          secrets: const <String, String>{'password': 'hunter2'},
        ),
      ),
    );
    try {
      final Map<String, Object?> item = (await h.search('q')).items.single;
      check(item['mangaId']).equals(
        jsonEncode(<Object?>[
          <Object?>['en', 'vi'],
          null,
          'hunter2',
        ]),
      );
      check(item['title']).equals('1');
    } finally {
      h.dispose();
    }
  });

  test('PagedResults.metadata round-trips exactly as the source wrote it', () async {
    final HostUnderTest h = await _load08(
      '''
      const page = (metadata && metadata.page) || 0;
      return App.createPagedResults({ results: [App.createPartialSourceManga({ mangaId: 'p' + page, title: 't', image: '' })], metadata: { page: page + 20, cursor: 'ç' } });''',
    );
    try {
      final PaperbackSearchPage first = await h.search('q');
      check(first.nextCursor).equals('{"page":20,"cursor":"ç"}');
      final PaperbackSearchPage second = await h.search('q', first.nextCursor);
      check(second.items.single['mangaId']).equals('p20');
      check(second.nextCursor).equals('{"page":40,"cursor":"ç"}');
    } finally {
      h.dispose();
    }
    check(_one('x').items).length.equals(1);
  });

  group('pinned Cheerio (1.0.0-rc.12)', () {
    const html = '''
      <html><body>
        <div class="card"><a href="/series/1/one">One</a><span class="badge">Hot</span></div>
        <div class="card"><a href="/series/2/two">Two</a></div>
        <section><span>View More Results...</span></section>
        <p id="enc">&eacute;t&eacute; &amp; ok</p>
      </body></html>''';

    test('matches :has, :contains, attribute and entity handling the pinned sources use', () async {
      final HostUnderTest h = await _load08(
        r'''
        const res = await this.requestManager.schedule(App.createRequest({ url: 'https://example.test/list', method: 'GET' }), 0);
        const $ = this.cheerio.load(res.data);
        const withBadge = $('div.card:has(span.badge) a').map((i, a) => $(a).text()).get();
        const more = $('span:contains("View More Results...")').toArray().length;
        const hrefs = $('div.card a').map((i, a) => $(a).attr('href')).get();
        const absolute = hrefs.map((h) => 'https://example.test' + h);
        return App.createPagedResults({ results: [App.createPartialSourceManga({ mangaId: JSON.stringify({ withBadge, more, absolute, text: $('#enc').text() }), title: 't', image: '' })] });''',
        handler: (http.Request r) async =>
            http.Response.bytes(utf8.encode(html), 200, headers: <String, String>{'content-type': 'text/html'}),
      );
      try {
        final result = jsonDecode((await h.search('q')).items.single['mangaId']! as String) as Map<String, Object?>;
        check(result['withBadge']! as List<Object?>).deepEquals(<Object?>['One']);
        check(result['more']).equals(1);
        check(result['absolute']! as List<Object?>)
            .deepEquals(<Object?>['https://example.test/series/1/one', 'https://example.test/series/2/two']);
        check(result['text']).equals('été & ok');
      } finally {
        h.dispose();
      }
    });

    test('prop("href") returns the raw attribute in rc.12; sources resolve URLs themselves', () async {
      final HostUnderTest h = await _load08(
        r'''
        const $ = this.cheerio.load('<a href="../x/y?z=1">l</a>', { baseURI: 'https://example.test/a/b/' });
        return App.createPagedResults({ results: [App.createPartialSourceManga({ mangaId: String($('a').prop('href')), title: 't', image: '' })] });''',
      );
      try {
        // Base-URI resolution arrived in Cheerio 1.0.0; the pinned rc.12 that
        // 0.8 sources were built against does not resolve.
        check((await h.search('q')).items.single['mangaId']).equals('../x/y?z=1');
      } finally {
        h.dispose();
      }
    });
  });

  test('createDUI* rows carry their type; other create* factories return their argument', () async {
    final HostUnderTest h = await _load08(
      '''
      const row = App.createDUISwitch({ id: 's', label: 'L' });
      const tag = App.createTag({ id: 't', label: 'T' });
      return App.createPagedResults({ results: [App.createPartialSourceManga({ mangaId: row.type + '/' + tag.label, title: 't', image: '' })] });''',
    );
    try {
      check((await h.search('q')).items.single['mangaId']).equals('DUISwitch/T');
    } finally {
      h.dispose();
    }
  });

  test('a failure carries the source error, never an empty page', () async {
    final HostUnderTest h = await _load08("throw new Error('site changed');");
    try {
      Object? error;
      try {
        await h.search('q');
      } on PaperbackRuntimeException catch (e) {
        error = e.failure;
      }
      check(error)
          .isA<SourceErrorFailure>()
          .has((SourceErrorFailure f) => f.message, 'message')
          .contains('site changed');
    } finally {
      h.dispose();
    }
  });
}
