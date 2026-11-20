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
}
