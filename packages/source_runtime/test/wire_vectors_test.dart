// Writes the worker-protocol, capture and constants golden vectors in
// `fixtures/wire_vectors/` from the Dart encoders (the source of truth), and
// checks the committed files match. The Tachi worker decodes and re-encodes
// them (`tools/tachi-source-runner/src/test/kotlin/WireVectorsTest.kt`), and
// the desktop helper reads `constants.json`. Regenerate with
// `UPDATE_WIRE_VECTORS=1 flutter test packages/source_runtime/test/wire_vectors_test.dart`.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_testing/wire_vectors.dart';
import 'package:test/scaffolding.dart';

const ArtifactBinding _jar = ArtifactBinding(sha256: 'ab12', kind: 'jar', version: '1.6.4');

const SourceIdentity _source = SourceIdentity(
  ecosystem: 'tachi',
  packageId: 'eu.kanade.tachiyomi.extension.all.mangadex',
  sourceId: '2499283573021220255',
  artifact: _jar,
);

const NativeMangaRef _ref = NativeMangaRef(
  source: _source,
  mangaId: '/manga/abc',
  settingsRevision: 'rev-1',
  context: <String, Object?>{
    'url': '/manga/abc',
    'title': 'Title',
    'status': 1,
    'initialized': true,
    'memo': <String, Object?>{},
  },
);

/// One frame vector: `payloadType` names the Dart class whose `toJson` wrote
/// the frame's `payload` (or `ok`, for replies); the worker decodes it with its
/// own class of that name.
Map<String, Object?> _vector(
  String name,
  FrameType type,
  ProtocolPayload body, {
  String id = '1-1',
  String? op,
  String? pkg,
  String? of,
}) {
  final bool reply = type == FrameType.response || type == FrameType.reverseResponse;
  final frame = ProtocolFrame(
    type: type,
    id: id,
    generation: 1,
    op: op,
    packageId: pkg,
    originId: of,
    payload: reply ? null : body.toJson(),
    ok: reply ? body.toJson() : null,
  );
  return <String, Object?>{'name': name, 'payloadType': body.runtimeType.toString(), 'frame': frame.toJson()};
}

Map<String, Object?> _req(String name, WorkerRequest<ProtocolPayload> r, {String? pkg = 'pkg.a'}) =>
    _vector(name, FrameType.request, r, op: r.operation.wire, pkg: r.operation.perPackage ? pkg : null);

Map<String, Object?> _rreq(String name, HostBrowserRequest<ProtocolPayload> r) =>
    _vector(name, FrameType.reverseRequest, r, id: 'r1', op: r.operation.wire, of: '1-7');

final SettingsPayload _settings = SettingsPayload(
  values: <String, Object>{
    'lang': 'en',
    'count': 3,
    'flag': true,
    'tags': <String>['b', 'a'],
  },
  secrets: <String, String>{'token': 's3cret'},
  revision: 'rev-1',
  sources: <String, SourceScopedSettings>{
    '2499283573021220255': SourceScopedSettings(values: const <String, Object>{'lang': 'ja'}),
  },
);

List<Map<String, Object?>> _workerFrames() => <Map<String, Object?>>[
  _req(
    'handshake',
    const HandshakeRequest(
      protocolVersions: <int>[1],
      maxFrameBytes: protocolMaxFrameBytes,
      protocolMinor: protocolMinorVersion,
    ),
  ),
  _req(
    'artifact.prepare',
    ArtifactPrepareRequest(
      artifact: const ArtifactBinding(sha256: 'cd34', kind: 'apk', version: '1.6.4'),
      inputPath: '/cache/in.apk',
      outputPath: '/cache/staged/out.jar',
      trustedSigners: <String>['9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2'],
    ),
  ),
  _vector(
    'artifact.prepare reply',
    FrameType.response,
    const ArtifactPrepareResponse(
      artifact: _jar,
      producer: 'tachi-jvm/apk-dex2jar',
      converterVersion: 'dex2jar.2+tachi-host.1',
    ),
  ),
  _req(
    'package.load',
    PackageLoadRequest(artifact: _jar, path: '/cache/staged/out.jar', settings: _settings, apiFamily: 'tachi-1.6'),
  ),
  _vector(
    'package.load reply',
    FrameType.response,
    PackageLoadResponse(
      sources: <LoadedSource>[
        LoadedSource(
          sourceId: '2499283573021220255',
          name: 'MangaDex',
          language: 'en',
          capabilities: SourceCapabilities(
            operations: const <SourceOperation>{
              SourceOperation.search,
              SourceOperation.mangaDetails,
              SourceOperation.chapterList,
            },
            apiFamilies: const <String>{'tachi-1.6'},
            requiresBrowser: true,
          ),
        ),
        LoadedSource(
          sourceId: '7',
          name: 'All',
          capabilities: SourceCapabilities(operations: const <SourceOperation>{SourceOperation.search}),
        ),
      ],
    ),
  ),
  _req('settings.update', SettingsUpdateRequest(settings: _settings)),
  _req(
    'search',
    const WorkerSearchRequest(
      source: _source,
      settingsRevision: 'rev-1',
      request: SearchRequest(query: 'one piece', cursor: '2'),
    ),
  ),
  _req(
    'search first page',
    const WorkerSearchRequest(
      source: _source,
      settingsRevision: 'rev-1',
      request: SearchRequest(query: 'x'),
    ),
  ),
  _req('details', const WorkerDetailsRequest(source: _source, settingsRevision: 'rev-1', ref: _ref, handle: 'h1')),
  _req('dispose handles', DisposeRequest(source: _source, handles: <String>['h1', 'h2'])),
  _req('dispose session', DisposeRequest(source: _source)),
  _req('package.unload', const PackageUnloadRequest()),
  _req('shutdown', const ShutdownRequest()),
  _rreq('host.browser.open', const HostBrowserOpen(sourceId: '2499283573021220255', userAgent: 'Mozilla/5.0 Test')),
  _vector(
    'host.browser.open reply',
    FrameType.reverseResponse,
    HostBrowserOpened(
      session: 'b1',
      capabilities: BrowserCapabilities(
        available: const <BrowserFeature>{BrowserFeature.pageStartScripts, BrowserFeature.observeNavigations},
        unavailable: const <BrowserFeature, String>{BrowserFeature.replaceRequests: 'WKWebView has no replace tier'},
      ),
    ),
    id: 'r1',
  ),
  _rreq(
    'host.browser.load',
    HostBrowserLoad(
      session: 'b1',
      url: Uri.parse('https://example.test/a?b=1'),
      headers: <String, String>{'Referer': 'https://example.test/'},
    ),
  ),
  _vector(
    'host.browser.load reply',
    FrameType.reverseResponse,
    HostBrowserPage(finalUrl: Uri.parse('https://example.test/final'), status: 403),
    id: 'r1',
  ),
  _rreq(
    'host.browser.loadData',
    HostBrowserLoadData(session: 'b1', html: '<p>x</p>', baseUrl: Uri.parse('https://example.test/')),
  ),
  _rreq('host.browser.evaluate', const HostBrowserEvaluate(session: 'b1', script: 'navigator.userAgent')),
  _vector(
    'host.browser.evaluate reply',
    FrameType.reverseResponse,
    const HostBrowserEvaluated(result: '"Mozilla/5.0"', scriptError: 'TypeError: x'),
    id: 'r1',
  ),
  _rreq(
    'host.browser.setMessageHandler',
    const HostBrowserSetMessageHandler(session: 'b1', name: 'ipc', enabled: true),
  ),
  _rreq('host.browser.getCookies', HostBrowserGetCookies(session: 'b1', url: Uri.parse('https://example.test/'))),
  _vector(
    'host.browser.getCookies reply',
    FrameType.reverseResponse,
    HostBrowserCookies(
      cookies: <BrowserCookie>[
        BrowserCookie(
          name: 'cf_clearance',
          value: 'v',
          domain: '.example.test',
          path: '/',
          expires: DateTime.utc(2030),
          secure: true,
          httpOnly: true,
        ),
        const BrowserCookie(name: 'plain', value: ''),
      ],
    ),
    id: 'r1',
  ),
  _rreq(
    'host.browser.setCookie',
    HostBrowserSetCookie(
      session: 'b1',
      url: Uri.parse('https://example.test/'),
      cookie: BrowserCookie(
        name: 'a',
        value: 'b',
        domain: 'example.test',
        path: '/',
        expires: DateTime.utc(2030),
        secure: true,
      ),
    ),
  ),
  _rreq('host.browser.setUserAgent', const HostBrowserSetUserAgent(session: 'b1', userAgent: 'Other/2.0')),
  _rreq('host.browser.show', const HostBrowserShow(session: 'b1')),
  _vector(
    'host.browser.show reply',
    FrameType.reverseResponse,
    const HostBrowserShown(outcome: BrowserInteractionEnd.completedByPage),
    id: 'r1',
  ),
  _vector('host.browser.show reply from 1.2', FrameType.reverseResponse, const HostBrowserShown(), id: 'r1'),
  _rreq('host.browser.close', const HostBrowserClose(session: 'b1')),
  _rreq('host.browser.addPageStartScript', const HostBrowserAddPageStartScript(session: 'b1', script: 'window.x = 1;')),
  _rreq(
    'host.browser.setRequestInterception',
    const HostBrowserSetRequestInterception(session: 'b1', mode: HostBrowserInterception.observe),
  ),
  _rreq(
    'host.browser.respond',
    HostBrowserRespond(
      session: 'b1',
      requestId: 'q1',
      response: BrowserReplacement(
        status: 200,
        headers: const <String, String>{'content-type': 'text/plain'},
        body: utf8.encode('ok'),
      ),
    ),
  ),
  _rreq('host.browser.respond proceed', const HostBrowserRespond(session: 'b1', requestId: 'q1')),
  _rreq('host.browser.endInteraction', const HostBrowserEndInteraction(session: 'b1')),
  _vector(
    'host.browser.message',
    FrameType.event,
    const HostBrowserMessage(session: 'b1', name: 'ipc', message: '{"done":true}'),
    id: 'e1',
    op: HostBrowserMessage.op,
  ),
  _vector(
    'host.browser.request held',
    FrameType.event,
    HostBrowserRequestEvent(
      session: 'b1',
      requestId: 'q1',
      request: BrowserRequest(
        url: Uri.parse('https://example.test/api'),
        method: 'post',
        headers: const <String, String>{'content-type': 'application/json'},
        body: utf8.encode('{"a":1}'),
        mainFrame: true,
        context: BrowserRequestContext.document,
      ),
    ),
    id: 'e4',
    op: HostBrowserRequestEvent.op,
  ),
  _vector(
    'host.browser.request observed',
    FrameType.event,
    HostBrowserRequestEvent(
      session: 'b1',
      request: BrowserRequest(url: Uri.parse('https://example.test/img.png'), bodyOmitted: true, redirect: true),
    ),
    id: 'e5',
    op: HostBrowserRequestEvent.op,
  ),
  _vector(
    'interaction.started',
    FrameType.event,
    const WorkerInteractionStarted(of: '1-7', timeout: Duration(minutes: 5)),
    id: 'e2',
    op: WorkerInteractionStarted.op,
  ),
  _vector(
    'interaction.ended',
    FrameType.event,
    const WorkerInteractionEnded(of: '1-7', paused: Duration(seconds: 42)),
    id: 'e3',
    op: WorkerInteractionEnded.op,
  ),
  <String, Object?>{
    'name': 'cancel',
    'frame': const ProtocolFrame(type: FrameType.cancel, id: '1-7', generation: 1).toJson(),
  },
  <String, Object?>{
    'name': 'error reply',
    'frame': const ProtocolFrame(
      type: FrameType.response,
      id: '1-7',
      generation: 1,
      error: <String, Object?>{
        'code': 'capability-unavailable',
        'message': 'no browser',
        'operation': 'host.browser.open',
      },
    ).toJson(),
  },
];

/// Canonical capture keys (`CaptureKey.canonicalUrl`), which the Kotlin replay
/// transport reimplements over OkHttp's URL model.
List<Map<String, Object?>> _canonicalUrls() => <Map<String, Object?>>[
  for (final (String url, Set<String> volatile) in <(String, Set<String>)>[
    ('https://example.test/path', <String>{}),
    ('https://Example.TEST/a/b?z=1&a=2&a=1', <String>{}),
    ('https://example.test/s?q=one+piece&x=a%20b', <String>{}),
    ('https://example.test/s?q=caf%C3%A9&n=%E6%BC%AB%E7%94%BB', <String>{}),
    ('https://example.test/s?empty=&flag&k=v', <String>{}),
    ('https://example.test/s?b=%2B%26%3D&a=*~()!%27', <String>{}),
    ('https://example.test:443/default-port?x=1', <String>{}),
    ('http://example.test:80/default-port', <String>{}),
    ('https://example.test:8443/port?x=1', <String>{}),
    ('https://example.test/frag?x=1#section', <String>{}),
    ('https://example.test/frag#only', <String>{}),
    ('https://example.test/vol?t=1712345678&q=a', <String>{'t'}),
    ('https://example.test/r?k=2&k=1&k=10', <String>{}),
    ('https://example.test/caf%C3%A9/manga', <String>{}),
  ])
    <String, Object?>{
      'url': url,
      'volatile': volatile.toList()..sort(),
      'canonical': CaptureKey.canonicalUrl(Uri.parse(url), volatile: volatile),
    },
];

/// `Set-Cookie` header values and what `parseSetCookieHeader` keeps.
List<Map<String, Object?>> _setCookies() => <Map<String, Object?>>[
  for (final String header in <String>[
    'session=abc; Path=/; HttpOnly',
    'a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/x, b=2; Domain=.example.test',
    'token=x=y==; Max-Age=60',
    'noequals; Path=/',
    '=nameless',
    ' spaced = value ; path = /p ; DOMAIN = example.test',
    'c=; Secure',
  ])
    <String, Object?>{
      'header': header,
      'cookies': <Object?>[
        for (final ParsedSetCookie c in parseSetCookieHeader(header))
          <String, Object?>{'name': c.name, 'value': c.value, 'path': c.path, 'domain': c.domain},
      ],
    },
];

/// A capture manifest as Dart writes it, with its one body.
Map<String, Object?> _captureRecord() {
  final List<int> body = utf8.encode('{"data":[]}');
  final String digest = sha256Hex(body);
  final manifest = CaptureManifest(
    ecosystem: 'tachi',
    source: 'all.mangadex',
    recordedAt: DateTime.utc(2026, 11, 1, 12),
    notes: 'golden vector',
    volatileQueryParameters: <String>{'t'},
    setCookieAllowList: <String, CapturedCookieValue>{
      'mhub_access': CapturedCookieValue.redact,
      'consent': CapturedCookieValue.keep,
    },
    exchanges: <CaptureExchange>[
      CaptureExchange(
        key: CaptureKey(
          method: 'get',
          url: Uri.parse('https://api.example.test/manga?t=99&title=one%20piece'),
          volatile: const <String>{'t'},
        ),
        status: 200,
        headers: const <String, String>{'content-type': 'application/json', 'retry-after': '5'},
        bodyFile: 'bodies/$digest.bin',
        artifact: CaptureArtifact(
          sourceUrl: 'https://api.example.test/manga',
          sha256: digest,
          size: body.length,
          licence: 'test',
        ),
        setCookies: const <CapturedCookie>[
          CapturedCookie(name: 'mhub_access', value: CapturedCookie.redactedValue, path: '/', redacted: true),
          CapturedCookie(name: 'consent', value: 'yes', domain: '.example.test'),
        ],
      ),
    ],
  );
  return <String, Object?>{
    'manifest': manifest.toJson(),
    'bodies': <String, Object?>{'bodies/$digest.bin': base64Encode(body)},
  };
}

void main() {
  test('worker protocol frames', () async {
    await checkWireVectors('worker_protocol.json', <String, Object?>{
      'comment':
          'Written by packages/source_runtime/test/wire_vectors_test.dart from the Dart protocol types; decoded and '
          're-encoded by tools/tachi-source-runner/src/test/kotlin/WireVectorsTest.kt. See README.md.',
      'frames': _workerFrames(),
    });
  });

  test('capture canonicalisation and records', () async {
    await checkWireVectors('capture.json', <String, Object?>{
      'comment':
          'Written by packages/source_runtime/test/wire_vectors_test.dart from capture_format.dart; the Kotlin replay '
          'transport (CaptureFormat.kt) must agree. See README.md.',
      'canonicalUrls': _canonicalUrls(),
      'setCookies': _setCookies(),
      'record': _captureRecord(),
    });
  });

  test('constants shared across languages', () async {
    await checkWireVectors('constants.json', <String, Object?>{
      'comment':
          'Written by packages/source_runtime/test/wire_vectors_test.dart; the Kotlin worker and the Rust helper '
          'assert their copies equal these. See README.md.',
      'protocolVersion': protocolVersion,
      'protocolMinorVersion': protocolMinorVersion,
      'protocolMaxFrameBytes': protocolMaxFrameBytes,
      'hostBrowserMaxForwardedBodyBytes': hostBrowserMaxForwardedBodyBytes,
      'recordedResponseHeaders': recordedResponseHeaders.toList()..sort(),
      'captureFormatVersion': captureFormatVersion,
      'workerOperations': <Object?>[
        for (final WorkerOperation o in WorkerOperation.values)
          <String, Object?>{
            'wire': o.wire,
            'perPackage': o.perPackage,
            'requiresLoadedPackage': o.requiresLoadedPackage,
          },
      ],
      'hostBrowserOperations': <Object?>[
        for (final HostBrowserOperation o in HostBrowserOperation.values)
          <String, Object?>{'wire': o.wire, 'sinceMinor': o.sinceMinor},
      ],
    });
  });
}
