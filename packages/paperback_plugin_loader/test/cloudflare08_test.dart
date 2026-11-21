// Cloudflare handling of the Paperback 0.8 adapter, with handwritten
// fixture bundles and a synthetic site: challenge detection, the
// `CLOUDFLARE_BYPASS_REQUIRED` intent, `getCloudflareBypassRequestAsync()`
// through a scripted BrowserPort, cookies in both directions, and the
// clearance/user-agent coupling. The real Mangahub bundle is exercised in
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
import 'support/scripted_browser_port.dart';

const String _browserUa = 'ScriptedBrowser/1.0';

const SourceIdentity _identity = SourceIdentity(
  ecosystem: 'paperback',
  packageId: 'pkg',
  sourceId: 'Test',
  artifact: ArtifactBinding(sha256: 'x', kind: 'paperback-bundle-0.8', version: '1'),
);

const String _challengePage =
    '<!DOCTYPE html><html><head><title>Just a moment...</title></head><body> '
    '<script src="/cdn-cgi/challenge-platform/h/b/orchestrate/chl_page/v1"></script></body></html>';

/// The synthetic site: `cf.example.test` answers with a challenge unless the
/// request carries the clearance cookie AND the browser's user agent; every
/// other answer echoes the user agent and cookie header it received.
Future<http.Response> _site(http.Request r) async {
  final String cookie = r.headers['cookie'] ?? '';
  final bool cleared = cookie.contains('cf_clearance=solved') && r.headers['user-agent'] == _browserUa;
  if (r.url.host == 'cf.example.test' && !cleared) {
    return http.Response(
      _challengePage,
      403,
      headers: <String, String>{
        'content-type': 'text/html',
        'cf-mitigated': 'challenge',
        'set-cookie': '__cf_bm=bm1; Path=/; Domain=cf.example.test',
      },
    );
  }
  return http.Response(jsonEncode(<String, Object?>{'ua': r.headers['user-agent'], 'cookie': cookie}), 200);
}

/// A 0.8 source shaped like the Cloudflare sources in the wild: its
/// interceptor echoes `getDefaultUserAgent()` and throws the conventional
/// "CLOUDFLARE BYPASS ERROR" on a challenge page.
String _source({int intents = 1 | 16, String? search}) =>
    '''
    exports.TestInfo = { name: 'Test', version: '1.0.0', language: 'en', contentRating: 'EVERYONE', intents: $intents };
    exports.Test = class {
      constructor() {
        this.requestManager = App.createRequestManager({
          requestsPerSecond: 100,
          interceptor: {
            interceptRequest: async (r) => {
              r.headers = { ...r.headers, 'user-agent': await this.requestManager.getDefaultUserAgent(), referer: 'https://cf.example.test/' };
              return r;
            },
            interceptResponse: async (res) => {
              if ((res.status === 403 || res.status === 503) && /just a moment/i.test(res.data)) {
                throw new Error('CLOUDFLARE BYPASS ERROR:\\nPlease go to the homepage of <https://cf.example.test> and press the cloud icon.');
              }
              return res;
            },
          },
        });
      }
      async getCloudflareBypassRequestAsync() {
        return App.createRequest({
          url: 'https://cf.example.test',
          method: 'GET',
          headers: { referer: 'https://cf.example.test/', 'user-agent': await this.requestManager.getDefaultUserAgent() },
        });
      }
      async getMangaDetails(id) { return App.createSourceManga({ id, mangaInfo: App.createMangaInfo({ titles: [id], image: '', desc: '', status: 'Ongoing' }) }); }
      async getChapters(id) { return []; }
      async getSearchResults(query, metadata) {
        ${search ?? '''
        const res = await this.requestManager.schedule(App.createRequest({
          url: 'https://cf.example.test/search', method: 'GET',
          cookies: [App.createCookie({ name: 'token', value: 't1', domain: 'cf.example.test' })],
        }), 0);
        const other = await this.requestManager.schedule(App.createRequest({ url: 'https://other.example.test/x', method: 'GET' }), 0);
        return App.createPagedResults({ results: [App.createPartialSourceManga({ mangaId: res.data, title: other.data, image: '' })] });'''}
      }
    };''';

/// A page that is challenged until [ScriptedPage.state] `solved` is set.
Object? _probe(ScriptedPage page) => <String, Object?>{
  'challenged': page.state['solved'] != true,
  'userAgent': page.userAgent ?? _browserUa,
};

/// The user solves the challenge in the shown window.
BrowserOutcome<void> _userSolves(ScriptedPage page) {
  page.state['solved'] = true;
  page.cookies['cf_clearance'] = const BrowserCookie(name: 'cf_clearance', value: 'solved', domain: '.cf.example.test');
  return const BrowserCompleted<void>(null);
}

Future<SourceFailure> _failureOf(Future<Object?> operation) async {
  try {
    await operation;
  } on PaperbackRuntimeException catch (e) {
    return e.failure;
  }
  throw StateError('The operation succeeded');
}

Future<(HostUnderTest, InProcessBrowserChannel?)> _load(String source, {ScriptedBrowserPort? port}) async {
  final InProcessBrowserChannel? channel = port == null
      ? null
      : InProcessBrowserChannel(port: port, source: _identity, interactionTimeout: const Duration(seconds: 5));
  final HostUnderTest h = await HostUnderTest.load(
    bundle08(source),
    PaperbackApiFamily.v08,
    handler: _site,
    browser: channel,
  );
  return (h, channel);
}

void main() {
  test('without a browser a challenge is interaction-required, never a source error', () async {
    final (HostUnderTest h, _) = await _load(_source());
    try {
      check(await _failureOf(h.search('q')))
          .isA<InteractionRequiredFailure>()
          .has((SourceFailure f) => f.message, 'message')
          .contains('CLOUDFLARE BYPASS ERROR');
    } finally {
      h.dispose();
    }
  });

  test('a challenge page the source fails to parse is still interaction-required', () async {
    final (HostUnderTest h, _) = await _load(
      _source(
        search: '''
        const res = await this.requestManager.schedule(App.createRequest({ url: 'https://cf.example.test/api', method: 'GET' }), 0);
        JSON.parse(res.data);
        return App.createPagedResults({ results: [] });''',
      ).replaceFirst('throw new Error', 'void '),
    );
    try {
      check(await _failureOf(h.search('q')))
          .isA<InteractionRequiredFailure>()
          .has((SourceFailure f) => f.message, 'message')
          .contains('Cloudflare challenged https://cf.example.test/api (HTTP 403)');
    } finally {
      h.dispose();
    }
  });

  test('the bypass request runs in the browser; clearance cookies and the browser user agent follow', () async {
    final port = ScriptedBrowserPort(probe: _probe, onShow: _userSolves);
    final (HostUnderTest h, InProcessBrowserChannel? channel) = await _load(_source(), port: port);
    try {
      final PaperbackSearchPage page = await h.search('q');
      final cleared = jsonDecode(page.items.single['mangaId']! as String) as Map<String, Object?>;
      final other = jsonDecode(page.items.single['title']! as String) as Map<String, Object?>;
      // The cleared domain: the browser's user agent, its clearance, the
      // challenge's own cookie, and the request's cookie.
      check(cleared['ua']).equals(_browserUa);
      check((cleared['cookie']! as String).split(';').where((String c) => c.isNotEmpty).toSet()).deepEquals(<String>{
        '__cf_bm=bm1',
        'cf_clearance=solved',
        'token=t1',
      });
      // Another domain gets neither the clearance nor the browser's user agent.
      check(other).deepEquals(<String, Object?>{'ua': null, 'cookie': ''});

      final ScriptedPage browser = port.pages.single;
      // The echoed default user agent is not forced on the browser.
      check(browser.userAgent).isNull();
      check(browser.loads.single.$1).equals(Uri.parse('https://cf.example.test'));
      check(browser.loads.single.$2).deepEquals(<String, String>{'referer': 'https://cf.example.test/'});
      // The host's cookies for the domain went into the browser first.
      check(browser.cookies.keys.toSet()).deepEquals(<String>{'__cf_bm', 'cf_clearance'});
      check(browser.shown).equals(1);
      check(port.closed).length.equals(1);
      // 1 challenged try, 1 cleared retry, 1 other-domain request.
      check(h.requests.map((http.Request r) => r.url.host).toList()).deepEquals(<String>[
        'cf.example.test',
        'cf.example.test',
        'other.example.test',
      ]);

      // The clearance lasts: the next operation needs no browser.
      await h.search('q');
      check(port.pages).length.equals(1);
    } finally {
      h.dispose();
      await channel?.close();
    }
  });

  test('a challenge that clears on its own is not shown to the user', () async {
    final port = ScriptedBrowserPort(
      probe: (ScriptedPage page) => <String, Object?>{'challenged': false, 'userAgent': _browserUa},
      setCookiesOnLoad: const <BrowserCookie>[
        BrowserCookie(name: 'cf_clearance', value: 'solved', domain: 'cf.example.test'),
      ],
    );
    final (HostUnderTest h, InProcessBrowserChannel? channel) = await _load(_source(), port: port);
    try {
      await h.search('q');
      check(port.pages.single.shown).equals(0);
    } finally {
      h.dispose();
      await channel?.close();
    }
  });

  test('an unsolved challenge: one bypass attempt, no retry, interaction-required', () async {
    final port = ScriptedBrowserPort(probe: _probe, onShow: (ScriptedPage page) => const BrowserCompleted<void>(null));
    final (HostUnderTest h, InProcessBrowserChannel? channel) = await _load(_source(), port: port);
    try {
      check(await _failureOf(h.search('q')))
          .isA<InteractionRequiredFailure>()
          .has((SourceFailure f) => f.message, 'message')
          .contains('was not solved');
      check(port.pages).length.equals(1);
      check(port.closed).length.equals(1);
      check(h.requests).length.equals(1);
    } finally {
      h.dispose();
      await channel?.close();
    }
  });

  test('a browser with no display leaves the challenge interaction-required', () async {
    final port = ScriptedBrowserPort(probe: _probe);
    final (HostUnderTest h, InProcessBrowserChannel? channel) = await _load(_source(), port: port);
    try {
      check(await _failureOf(h.search('q'))).isA<InteractionRequiredFailure>();
      check(port.pages.single.shown).equals(1);
    } finally {
      h.dispose();
      await channel?.close();
    }
  });

  test('a cleared retry that is challenged again is final (no second bypass)', () async {
    // The browser reports success but the site keeps challenging (for
    // example a clearance bound to another user agent).
    final port = ScriptedBrowserPort(
      probe: (ScriptedPage page) => <String, Object?>{'challenged': false, 'userAgent': 'Other/1.0'},
    );
    final (HostUnderTest h, InProcessBrowserChannel? channel) = await _load(_source(), port: port);
    try {
      check(await _failureOf(h.search('q'))).isA<InteractionRequiredFailure>();
      check(port.pages).length.equals(1);
      check(h.requests).length.equals(2);
      check(h.requests.last.headers['user-agent']).equals('Other/1.0');
    } finally {
      h.dispose();
      await channel?.close();
    }
  });

  test('without the CLOUDFLARE_BYPASS_REQUIRED intent the browser is not used', () async {
    final port = ScriptedBrowserPort(probe: _probe, onShow: _userSolves);
    final (HostUnderTest h, InProcessBrowserChannel? channel) = await _load(_source(intents: 1), port: port);
    try {
      check(await _failureOf(h.search('q'))).isA<InteractionRequiredFailure>();
      check(port.pages).isEmpty();
    } finally {
      h.dispose();
      await channel?.close();
    }
  });

  test('set-cookie reaches response.headers as an array; a request cookie replaces a stored one', () async {
    final HostUnderTest h = await HostUnderTest.load(
      bundle08('''
        exports.TestInfo = { name: 'Test', version: '1.0.0', language: 'en', contentRating: 'EVERYONE' };
        exports.Test = class {
          constructor() { this.requestManager = App.createRequestManager({ requestsPerSecond: 100 }); }
          async getMangaDetails(id) { return App.createSourceManga({ id, mangaInfo: App.createMangaInfo({ titles: [id], image: '', desc: '', status: 'Ongoing' }) }); }
          async getChapters(id) { return []; }
          async getSearchResults(query, metadata) {
            const first = await this.requestManager.schedule(App.createRequest({ url: 'https://example.test/a', method: 'GET' }), 0);
            const second = await this.requestManager.schedule(App.createRequest({
              url: 'https://example.test/b', method: 'GET',
              headers: { 'x-token': 'mine' },
              cookies: [App.createCookie({ name: 'token', value: 'mine', domain: 'example.test' })],
            }), 0);
            return App.createPagedResults({ results: [App.createPartialSourceManga({ mangaId: JSON.stringify(first.headers['set-cookie']), title: second.data, image: '' })] });
          }
        };'''),
      PaperbackApiFamily.v08,
      client: _SetCookieClient(),
    );
    try {
      final PaperbackSearchPage page = await h.search('q');
      check(jsonDecode(page.items.single['mangaId']! as String)).isA<List<Object?>>().deepEquals(<Object?>[
        'token=issued; Path=/',
        'other=1; Path=/',
      ]);
      // One `token`: the request's own, matching its header.
      check((page.items.single['title']! as String).split(';').where((String c) => c.isNotEmpty).toList())
        ..length.equals(2)
        ..contains('token=mine')
        ..contains('other=1');
    } finally {
      h.dispose();
    }
  });
}

/// Answers `/a` with two `Set-Cookie` values and echoes the cookie header
/// of every other request.
final class _SetCookieClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final first = request.url.path == '/a';
    final List<int> body = utf8.encode(first ? '' : request.headers['cookie'] ?? '');
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      200,
      request: request,
      // `package:http` joins repeated headers with ", "; `headersSplitValues`
      // splits `Set-Cookie` back into values.
      headers: first ? <String, String>{'set-cookie': 'token=issued; Path=/, other=1; Path=/'} : <String, String>{},
    );
  }
}
