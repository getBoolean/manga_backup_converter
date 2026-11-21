@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_testing/source_runtime_testing.dart';
import 'package:test/scaffolding.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('capture_test'));
  tearDown(() => temp.deleteSync(recursive: true));

  /// Records through a MockClient (no network) and writes a capture directory.
  Future<Directory> record({required String body, Set<String> volatile = const <String>{}}) async {
    final upstream = MockClient(
      (http.Request r) async => http.Response(
        body,
        200,
        headers: <String, String>{
          'content-type': 'text/html',
          'set-cookie': 'session=leak',
          'content-encoding': 'gzip',
        },
      ),
    );
    final recorder = RecordingHttpClient(
      upstream,
      minInterval: Duration.zero,
      licence: 'test licence',
      volatileQueryParameters: volatile,
    );
    await recorder.get(Uri.parse('https://source.test/search?q=onimai&ts=1&page=1'));
    await recorder.post(
      Uri.parse('https://source.test/api'),
      body: '{"a":1}',
      headers: <String, String>{'cookie': 'c=1'},
    );
    final dir = Directory(p.join(temp.path, 'test', 'src'));
    recorder.writeTo(dir, ecosystem: 'test', source: 'src');
    return dir;
  }

  test('records provenance per artifact and never stores cookies or framing headers', () async {
    final Directory dir = await record(body: '<html>ok</html>');
    final String manifest = File(p.join(dir.path, captureManifestFileName)).readAsStringSync();
    check(manifest).not((Subject<String> it) => it.contains('session=leak'));
    check(manifest).not((Subject<String> it) => it.contains('c=1'));
    check(manifest).not((Subject<String> it) => it.contains('content-encoding'));
    final parsed = CaptureManifest.fromJson(jsonDecode(manifest) as Map<String, Object?>);
    for (final CaptureExchange e in parsed.exchanges) {
      check(e.artifact.licence).equals('test licence');
      check(e.artifact.sourceUrl).startsWith('https://source.test/');
      check(e.artifact.sha256).equals(sha256Hex(File(p.join(dir.path, e.bodyFile)).readAsBytesSync()));
    }
  });

  test('replay serves committed captures with query order ignored', () async {
    final Directory dir = await record(body: '<html>ok</html>');
    final replay = ReplayHttpClient(loadCaptureSet(dir));
    final http.Response r = await replay.get(Uri.parse('https://source.test/search?page=1&ts=1&q=onimai'));
    check(r.body).equals('<html>ok</html>');
    final http.Response post = await replay.post(Uri.parse('https://source.test/api'), body: '{"a":1}');
    check(post.statusCode).equals(200);
    check(replay.misses).isEmpty();
  });

  test('replay fails any request without a capture and records the miss', () async {
    final Directory dir = await record(body: 'x');
    final replay = ReplayHttpClient(loadCaptureSet(dir));
    await check(replay.get(Uri.parse('https://source.test/other'))).throws<CaptureMissException>();
    await check(replay.post(Uri.parse('https://source.test/api'), body: '{"a":2}')).throws<CaptureMissException>();
    check(replay.misses).length.equals(2);
  });

  test('volatile query parameters match by name only', () async {
    final Directory dir = await record(body: 'x', volatile: <String>{'ts'});
    final replay = ReplayHttpClient(loadCaptureSet(dir));
    check((await replay.get(Uri.parse('https://source.test/search?q=onimai&ts=999&page=1'))).body).equals('x');
    await check(replay.get(Uri.parse('https://source.test/search?q=other&ts=1&page=1'))).throws<CaptureMissException>();
  });

  test('a body that no longer matches its recorded SHA-256 refuses to load', () async {
    final Directory dir = await record(body: 'original');
    final File body = Directory(p.join(dir.path, captureBodiesDirName)).listSync().whereType<File>().first;
    body.writeAsStringSync('changed');
    check(() => loadCaptureSet(dir)).throws<FormatException>();
  });

  test('the recorder refuses URLs that carry credentials', () async {
    final recorder = RecordingHttpClient(
      MockClient((_) async => http.Response('', 200)),
      minInterval: Duration.zero,
      licence: 'l',
    );
    await check(recorder.get(Uri.parse('https://source.test/x?access_token=abc'))).throws<StateError>();
  });

  test('the fake BrowserPort replays captured pages and fails uncaptured ones', () async {
    final Directory dir = await record(body: '<html><title>captured</title></html>');
    final port = FakeBrowserPort.replay(loadCaptureSet(dir));
    final BrowserSession s = (await port.openSession(
      const BrowserSessionRequest(
        source: SourceIdentity(
          ecosystem: 'test',
          packageId: 'p',
          sourceId: 's',
          artifact: ArtifactBinding(sha256: '0', kind: 't', version: '1'),
        ),
        generation: 1,
      ),
    )).valueOrNull!;
    check(
      await s.loadUrl(Uri.parse('https://source.test/search?q=onimai&ts=1&page=1')),
    ).isA<BrowserCompleted<BrowserPage>>();
    check((await s.evaluate('document.title')).valueOrNull).equals('"captured"');
    check(await s.loadUrl(Uri.parse('https://source.test/uncaptured'))).isA<BrowserNavigationFailed<BrowserPage>>();
    check(port.misses).length.equals(1);
  });

  test('committed Aidoku captures load and verify', () {
    for (final source in <String>['multi.mangadex', 'multi.mangafire']) {
      final Directory? dir = findCaptureDir('aidoku', source);
      check(because: 'fixtures/source_captures/aidoku/$source', dir).isNotNull();
      final CaptureSet set = loadCaptureSet(dir!);
      check(set.manifest.exchanges).isNotEmpty();
      for (final CaptureExchange e in set.manifest.exchanges) {
        check(e.artifact.licence).isNotEmpty();
        check(Uint8List.fromList(utf8.encode(e.artifact.sourceUrl))).isNotEmpty();
      }
    }
  });

  group('protocol 1.3 capture cookies and challenge headers', () {
    const token = 'tok-9f8e7d6c5b4a';
    final Uri search = Uri.parse('https://mangahub.test/search?q=onimai');

    MockClient upstream() => MockClient((http.Request r) async {
      if (r.url.path == '/search') {
        return http.Response(
          '<html>results</html>',
          200,
          headers: <String, String>{
            'content-type': 'text/html',
            // package:http joins repeated Set-Cookie headers with commas; the
            // Expires date has a comma of its own.
            'set-cookie': <String>[
              'mhub_access=$token; Path=/; Domain=mangahub.test; Expires=Wed, 21 Oct 2026 07:28:00 GMT; HttpOnly',
              'consent=yes; Path=/',
              'tracker=abc; Max-Age=60',
            ].join(','),
          },
        );
      }
      return http.Response('challenge', 403, headers: <String, String>{'cf-mitigated': 'challenge'});
    });

    test('splits a joined Set-Cookie header without breaking Expires dates', () {
      final List<ParsedSetCookie> cookies = parseSetCookieHeader(
        'a=1; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT, b=2; Domain=x.test,c=3',
      );
      check(cookies.map((ParsedSetCookie c) => c.name)).deepEquals(<String>['a', 'b', 'c']);
      check(cookies[0]).equals((name: 'a', value: '1', path: '/', domain: null));
      check(cookies[1]).equals((name: 'b', value: '2', path: null, domain: 'x.test'));
      check(parseSetCookieHeader('novalue; Path=/')).isEmpty();
    });

    test('records only allow-listed cookies, redacted where asked, and keeps cf-mitigated', () async {
      final recorder = RecordingHttpClient(
        upstream(),
        minInterval: Duration.zero,
        licence: 'test licence',
        setCookieAllowList: const <String, CapturedCookieValue>{
          'mhub_access': CapturedCookieValue.redact,
          'consent': CapturedCookieValue.keep,
        },
      );
      final http.Response live = await recorder.get(search);
      // The live scenario keeps working with the real token.
      check(live.headers['set-cookie']).equals('mhub_access=$token; Path=/; Domain=mangahub.test, consent=yes; Path=/');
      final http.Response challenged = await recorder.get(Uri.parse('https://mangahub.test/manga/onimai'));
      check(challenged.headers['cf-mitigated']).equals('challenge');
      // The token is now a known secret: a URL carrying it aborts the recording.
      await check(recorder.get(Uri.parse('https://mangahub.test/api?access=$token'))).throws<StateError>();

      final dir = Directory(p.join(temp.path, 'mangahub'));
      recorder.writeTo(dir, ecosystem: 'test', source: 'mangahub');
      final String manifest = File(p.join(dir.path, captureManifestFileName)).readAsStringSync();
      check(manifest).not((Subject<String> it) => it.contains(token));
      check(manifest).not((Subject<String> it) => it.contains('tracker'));
      check(manifest).not((Subject<String> it) => it.contains('Expires'));

      final CaptureSet set = loadCaptureSet(dir);
      check(set.manifest.setCookieAllowList).deepEquals(<String, CapturedCookieValue>{
        'mhub_access': CapturedCookieValue.redact,
        'consent': CapturedCookieValue.keep,
      });
      final CapturedResponse r = set.lookup(set.manifest.keyFor('GET', search, null));
      check(r.setCookies).deepEquals(const <CapturedCookie>[
        CapturedCookie(
          name: 'mhub_access',
          value: CapturedCookie.redactedValue,
          path: '/',
          domain: 'mangahub.test',
          redacted: true,
        ),
        CapturedCookie(name: 'consent', value: 'yes', path: '/'),
      ]);

      final replay = ReplayHttpClient(set);
      final http.Response replayed = await replay.get(search);
      check(replayed.headers['set-cookie'])
          .equals('mhub_access=redacted; Path=/; Domain=mangahub.test, consent=yes; Path=/');
      final http.Response replayedChallenge = await replay.get(Uri.parse('https://mangahub.test/manga/onimai'));
      check(replayedChallenge.statusCode).equals(403);
      check(replayedChallenge.headers['cf-mitigated']).equals('challenge');
      check(replay.misses).isEmpty();
    });

    test('records no cookie by default, and a manifest without cookies encodes as before', () async {
      final recorder = RecordingHttpClient(upstream(), minInterval: Duration.zero, licence: 'test licence');
      check(recorder.setCookieAllowList).isEmpty();
      final http.Response live = await recorder.get(search);
      check(live.headers.containsKey('set-cookie')).isFalse();
      final dir = Directory(p.join(temp.path, 'plain'));
      recorder.writeTo(dir, ecosystem: 'test', source: 'plain');
      final json =
          jsonDecode(File(p.join(dir.path, captureManifestFileName)).readAsStringSync()) as Map<String, Object?>;
      check(json.containsKey('setCookieAllowList')).isFalse();
      final exchange = (json['exchanges']! as List<Object?>).single! as Map<String, Object?>;
      check((exchange['response']! as Map<String, Object?>).containsKey('setCookies')).isFalse();
      check(json['format']).equals(captureFormatVersion);
    });

    test('every committed capture loads, verifies and re-encodes unchanged', () {
      final Directory root = findCaptureDir('aidoku', 'multi.mangadex')!.parent.parent;
      final dirs = <Directory>[
        for (final FileSystemEntity eco in root.listSync().whereType<Directory>())
          for (final FileSystemEntity src in (eco as Directory).listSync().whereType<Directory>())
            if (File(p.join(src.path, captureManifestFileName)).existsSync()) src as Directory,
      ];
      check(because: 'Aidoku, Paperback and Tachi captures', dirs.length).isGreaterOrEqual(9);
      for (final dir in dirs) {
        final CaptureSet set = loadCaptureSet(dir);
        check(because: dir.path, set.manifest.exchanges).isNotEmpty();
        final String text = File(p.join(dir.path, captureManifestFileName)).readAsStringSync();
        final committed = jsonDecode(text) as Map<String, Object?>;
        final reencoded = jsonDecode(set.manifest.encode()) as Map<String, Object?>;
        // Other recorders (the Kotlin and Paperback tools) sign their own name.
        reencoded['recordedBy'] = committed['recordedBy'];
        // They also write timestamps with other precision; compare instants.
        check(
          because: dir.path,
          DateTime.parse(reencoded['recordedAt']! as String),
        ).equals(DateTime.parse(committed['recordedAt']! as String));
        reencoded['recordedAt'] = committed['recordedAt'];
        check(because: dir.path, reencoded).deepEquals(committed);
      }
    });

    test('the fake BrowserPort replay stores a captured cookie in the session jar', () async {
      final recorder = RecordingHttpClient(
        upstream(),
        minInterval: Duration.zero,
        licence: 'test licence',
        setCookieAllowList: const <String, CapturedCookieValue>{'mhub_access': CapturedCookieValue.redact},
      );
      await recorder.get(search);
      final dir = Directory(p.join(temp.path, 'browser'));
      recorder.writeTo(dir, ecosystem: 'test', source: 'browser');
      final port = FakeBrowserPort.replay(loadCaptureSet(dir));
      final BrowserSession s = (await port.openSession(
        const BrowserSessionRequest(
          source: SourceIdentity(
            ecosystem: 'test',
            packageId: 'p',
            sourceId: 's',
            artifact: ArtifactBinding(sha256: '0', kind: 't', version: '1'),
          ),
          generation: 1,
        ),
      )).valueOrNull!;
      check(await s.loadUrl(search)).isA<BrowserCompleted<BrowserPage>>();
      final List<BrowserCookie> cookies = (await s.getCookies(search)).valueOrNull!;
      check(cookies.map((BrowserCookie c) => '${c.name}=${c.value}')).deepEquals(<String>['mhub_access=redacted']);
    });
  });
}
