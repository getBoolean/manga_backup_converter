// Round-trips every protocol v1 payload through real frame bytes
// (encodeFrame → FrameDecoder → fromJson), so decoded JSON types
// (Map<String, dynamic>, List<dynamic>) are what the decoders see.
import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

/// Above 2^53: a JSON number would lose it, a decimal string must not.
const String bigSourceId = '9223372036854775807';

const artifact = ArtifactBinding(sha256: 'ab12', kind: 'jar', version: '1.4.2');
const source = SourceIdentity(ecosystem: 'tachi', packageId: 'eu.kanade.x', sourceId: bigSourceId, artifact: artifact);

Future<ProtocolFrame> _throughBytes(ProtocolFrame frame) async =>
    Stream<List<int>>.value(encodeFrame(frame)).transform(const FrameDecoder()).single;

/// Sends [payload] as a request (`payload`) and returns what the peer decodes.
Future<Map<String, Object?>> _asRequest(
  ProtocolPayload payload,
  String op, {
  FrameType type = FrameType.request,
}) async {
  final ProtocolFrame frame = await _throughBytes(
    ProtocolFrame(type: type, id: '7-1', generation: 7, op: op, payload: payload.toJson()),
  );
  check(frame.op).equals(op);
  return frame.payload!;
}

/// Sends [payload] as a reply (`ok`) and returns what the peer decodes.
Future<Map<String, Object?>> _asReply(ProtocolPayload payload, {FrameType type = FrameType.response}) async {
  final ProtocolFrame frame = await _throughBytes(
    ProtocolFrame(type: type, id: '7-1', generation: 7, ok: payload.toJson()),
  );
  return frame.ok!;
}

String _json(ProtocolPayload p) => jsonEncode(p.toJson());

/// Round-trips a worker request and its reply; returns the decoded pair.
Future<(WorkerRequest<ProtocolPayload>, ProtocolPayload)> _workerRoundTrip<R extends ProtocolPayload>(
  WorkerRequest<R> request,
  R reply,
) async {
  final WorkerOperation? op = WorkerOperation.fromWire(request.operation.wire);
  check(op).equals(request.operation);
  final WorkerRequest<ProtocolPayload> decoded = WorkerRequest.fromWire(op!, await _asRequest(request, op.wire));
  check(decoded.runtimeType).equals(request.runtimeType);
  check(_json(decoded)).equals(_json(request));
  final R decodedReply = request.decodeResponse(await _asReply(reply));
  check(_json(decodedReply)).equals(_json(reply));
  return (decoded, decodedReply);
}

/// Round-trips a reverse request and its reply; returns the decoded pair.
Future<(HostBrowserRequest<ProtocolPayload>, ProtocolPayload)> _browserRoundTrip<R extends ProtocolPayload>(
  HostBrowserRequest<R> request,
  R reply,
) async {
  final HostBrowserOperation? op = HostBrowserOperation.fromWire(request.operation.wire);
  check(op).equals(request.operation);
  final HostBrowserRequest<ProtocolPayload> decoded = HostBrowserRequest.fromWire(
    op!,
    await _asRequest(request, op.wire, type: FrameType.reverseRequest),
  );
  check(decoded.runtimeType).equals(request.runtimeType);
  check(_json(decoded)).equals(_json(request));
  final R decodedReply = request.decodeResponse(await _asReply(reply, type: FrameType.reverseResponse));
  check(_json(decodedReply)).equals(_json(reply));
  return (decoded, decodedReply);
}

void main() {
  final settings = SettingsPayload(
    values: const <String, Object>{'lang': 'en', 'nsfw': false, 'pageSize': 20},
    secrets: const <String, String>{'token': 's3cr3t'},
    revision: 'rev-1',
  );
  const ref = NativeMangaRef(
    source: source,
    mangaId: '/manga/onimai',
    settingsRevision: 'rev-1',
    context: <String, Object?>{'url': '/manga/onimai', 'initialized': true},
  );

  group('worker operations round-trip through frame bytes', () {
    test('every operation has a wire name and a typed request', () {
      check(WorkerOperation.values.map((WorkerOperation o) => o.wire).toList()).deepEquals(<String>[
        'handshake',
        'artifact.prepare',
        'package.load',
        'package.unload',
        'settings.update',
        'search',
        'details',
        'dispose',
        'shutdown',
      ]);
      check(WorkerOperation.fromWire('nope')).isNull();
    });

    test('handshake', () async {
      final (_, ProtocolPayload reply) = await _workerRoundTrip(
        const HandshakeRequest(protocolVersions: <int>[1], maxFrameBytes: protocolMaxFrameBytes),
        HandshakeResponse(
          protocolVersion: 1,
          worker: 'tachi-jvm',
          workerVersion: '0.1.0',
          pid: 4242,
          capabilities: WorkerCapabilities(apiFamilies: const <String>{'tachi-1.5', 'tachi-1.4'}, browser: true),
        ),
      );
      final r = reply as HandshakeResponse;
      check(r.capabilities.apiFamilies).deepEquals(<String>{'tachi-1.4', 'tachi-1.5'});
      check(r.capabilities.browser).isTrue();
    });

    test('artifact.prepare', () async {
      final (WorkerRequest<ProtocolPayload> req, ProtocolPayload reply) = await _workerRoundTrip(
        const ArtifactPrepareRequest(
          artifact: ArtifactBinding(sha256: 'apk1', kind: 'apk', version: '1.4.2'),
          inputPath: '/staging/in.apk',
          outputPath: '/staging/out.jar',
        ),
        const ArtifactPrepareResponse(artifact: artifact, producer: 'tachi-dex2jar', converterVersion: '2.4'),
      );
      check((req as ArtifactPrepareRequest).artifact.kind).equals('apk');
      check((reply as ArtifactPrepareResponse).artifact).equals(artifact);
    });

    test('package.load carries typed settings and secrets', () async {
      final (WorkerRequest<ProtocolPayload> req, ProtocolPayload reply) = await _workerRoundTrip(
        PackageLoadRequest(artifact: artifact, path: '/staging/x.jar', settings: settings),
        PackageLoadResponse(
          sources: <LoadedSource>[
            LoadedSource(
              sourceId: bigSourceId,
              name: 'X (EN)',
              language: 'en',
              capabilities: SourceCapabilities(
                operations: const <SourceOperation>{SourceOperation.search, SourceOperation.mangaDetails},
                requiresBrowser: true,
              ),
            ),
          ],
        ),
      );
      final SettingsPayload s = (req as PackageLoadRequest).settings;
      check(s.values['nsfw']).isA<bool>().isFalse();
      check(s.values['pageSize']).isA<int>().equals(20);
      check(s.secrets).deepEquals(<String, String>{'token': 's3cr3t'});
      final LoadedSource loaded = (reply as PackageLoadResponse).sources.single;
      check(loaded.sourceId).equals(bigSourceId);
      check(loaded.capabilities.requiresBrowser).isTrue();
    });

    test('package.unload', () async {
      await _workerRoundTrip(const PackageUnloadRequest(), const EmptyPayload());
    });

    test('settings.update', () async {
      final (WorkerRequest<ProtocolPayload> req, _) = await _workerRoundTrip(
        SettingsUpdateRequest(settings: settings),
        const EmptyPayload(),
      );
      check((req as SettingsUpdateRequest).settings.revision).equals('rev-1');
    });

    test('settings payloads mirror a snapshot', () {
      final snapshot = SettingsSnapshot(
        values: const <String, Object>{'nsfw': true},
        secrets: const <String, String>{'password': 'p'},
      );
      final payload = SettingsPayload.fromSnapshot(snapshot);
      check(payload.revision).equals(snapshot.revision);
      check(payload.values).deepEquals(<String, Object>{'nsfw': true});
      check(payload.secrets).deepEquals(<String, String>{'password': 'p'});
    });

    test('search', () async {
      final (WorkerRequest<ProtocolPayload> req, ProtocolPayload reply) = await _workerRoundTrip(
        const WorkerSearchRequest(
          source: source,
          settingsRevision: 'rev-1',
          request: SearchRequest(query: 'onimai', cursor: 'page-2'),
        ),
        WorkerSearchResponse(
          hits: <WorkerSearchHit>[
            const WorkerSearchHit(
              hit: SearchHit(ref: ref, title: 'Onimai', coverUrl: 'https://x.test/c.jpg', authors: <String>['A']),
              handle: 'h-1',
            ),
            const WorkerSearchHit(
              hit: SearchHit(ref: ref, title: 'No handle'),
            ),
          ],
          nextCursor: 'page-3',
          warnings: const <String>['[CB] selector failed'],
        ),
      );
      check((req as WorkerSearchRequest).source.sourceId).equals(bigSourceId);
      check(req.request.cursor).equals('page-2');
      final r = reply as WorkerSearchResponse;
      check(r.hits.first.handle).equals('h-1');
      check(r.hits.first.hit.ref.source.sourceId).equals(bigSourceId);
      check(r.hits.first.hit.ref.context['initialized']).equals(true);
      check(r.hits.last.handle).isNull();
    });

    test('details', () async {
      final (WorkerRequest<ProtocolPayload> req, ProtocolPayload reply) = await _workerRoundTrip(
        const WorkerDetailsRequest(source: source, settingsRevision: 'rev-1', ref: ref, handle: 'h-1'),
        WorkerDetailsResponse(
          metadata: const MangaMetadata(
            title: 'Onimai',
            authors: <String>['Nekotofu'],
            status: PublishingStatus.ongoing,
            contentRating: ContentRatingLevel.suggestive,
          ),
          chapters: <NativeChapter>[
            NativeChapter(
              chapterId: '/c/1',
              sourceOrder: 0,
              chapterNumber: 1,
              scanlators: const <String>['A', 'B'],
              dateUploaded: DateTime.utc(2024, 1, 2),
            ),
          ],
        ),
      );
      check((req as WorkerDetailsRequest).ref.mangaId).equals('/manga/onimai');
      check(req.handle).equals('h-1');
      final r = reply as WorkerDetailsResponse;
      check(r.metadata.status).equals(PublishingStatus.ongoing);
      check(r.chapters.single.scanlators).deepEquals(<String>['A', 'B']);
      check(r.chapters.single.dateUploaded).equals(DateTime.utc(2024, 1, 2));
    });

    test('dispose, with and without explicit handles', () async {
      await _workerRoundTrip(DisposeRequest(source: source, handles: const <String>['h-1']), const EmptyPayload());
      final (WorkerRequest<ProtocolPayload> all, _) = await _workerRoundTrip(
        DisposeRequest(source: source),
        const EmptyPayload(),
      );
      check((all as DisposeRequest).handles).isNull();
    });

    test('shutdown', () async {
      await _workerRoundTrip(const ShutdownRequest(), const EmptyPayload());
    });
  });

  group('host.browser.* round-trip through frame bytes', () {
    test('every reverse operation has a wire name', () {
      check(HostBrowserOperation.values.map((HostBrowserOperation o) => o.wire).toList()).deepEquals(<String>[
        'host.browser.open',
        'host.browser.load',
        'host.browser.loadData',
        'host.browser.evaluate',
        'host.browser.setMessageHandler',
        'host.browser.getCookies',
        'host.browser.setCookie',
        'host.browser.setUserAgent',
        'host.browser.show',
        'host.browser.close',
      ]);
    });

    test('open', () async {
      await _browserRoundTrip(
        const HostBrowserOpen(sourceId: bigSourceId, userAgent: 'UA/1'),
        const HostBrowserOpened(session: 's-1'),
      );
    });

    test('load and loadData', () async {
      final (HostBrowserRequest<ProtocolPayload> load, ProtocolPayload page) = await _browserRoundTrip(
        HostBrowserLoad(
          session: 's-1',
          url: Uri.parse('https://x.test/a?b=1'),
          headers: const <String, String>{'Referer': 'https://x.test/'},
        ),
        HostBrowserPage(finalUrl: Uri.parse('https://x.test/b'), status: 200),
      );
      check((load as HostBrowserLoad).headers).deepEquals(<String, String>{'Referer': 'https://x.test/'});
      check((page as HostBrowserPage).status).equals(200);
      await _browserRoundTrip(
        HostBrowserLoadData(session: 's-1', html: '<p>漫画</p>', baseUrl: Uri.parse('https://x.test/')),
        HostBrowserPage(finalUrl: Uri.parse('https://x.test/')),
      );
    });

    test('evaluate', () async {
      await _browserRoundTrip(
        const HostBrowserEvaluate(session: 's-1', script: 'document.title'),
        const HostBrowserEvaluated(result: '"ok"'),
      );
    });

    test('setMessageHandler, setUserAgent, show and close', () async {
      await _browserRoundTrip(
        const HostBrowserSetMessageHandler(session: 's-1', name: 'bridge', enabled: true),
        const EmptyPayload(),
      );
      await _browserRoundTrip(const HostBrowserSetUserAgent(session: 's-1', userAgent: 'UA/2'), const EmptyPayload());
      await _browserRoundTrip(const HostBrowserShow(session: 's-1'), const EmptyPayload());
      await _browserRoundTrip(const HostBrowserClose(session: 's-1'), const EmptyPayload());
    });

    test('getCookies and setCookie', () async {
      final cookie = BrowserCookie(
        name: 'cf_clearance',
        value: 'v',
        domain: 'x.test',
        path: '/',
        expires: DateTime.utc(2030),
        secure: true,
        httpOnly: true,
      );
      final (_, ProtocolPayload cookies) = await _browserRoundTrip(
        HostBrowserGetCookies(session: 's-1', url: Uri.parse('https://x.test/')),
        HostBrowserCookies(cookies: <BrowserCookie>[cookie]),
      );
      check((cookies as HostBrowserCookies).cookies.single.expires).equals(DateTime.utc(2030));
      await _browserRoundTrip(
        HostBrowserSetCookie(session: 's-1', url: Uri.parse('https://x.test/'), cookie: cookie),
        const EmptyPayload(),
      );
    });

    test('the host.browser.message event', () async {
      const event = HostBrowserMessage(session: 's-1', name: 'bridge', message: '{"ready":true}');
      final Map<String, Object?> decoded = await _asRequest(event, HostBrowserMessage.op, type: FrameType.event);
      check(_json(HostBrowserMessage.fromJson(decoded))).equals(_json(event));
    });
  });

  group('error objects', () {
    test('every failure code round-trips through an err object', () async {
      final failures = <SourceFailure>[
        const TimeoutFailure('t'),
        const CancelledFailure('c'),
        const UnsupportedApiFailure('u'),
        const InteractionRequiredFailure('i'),
        const StaleReferenceFailure('s'),
        const ArtifactIncompatibleFailure('a'),
        const WorkerRestartedFailure('w'),
        const SourceErrorFailure('e'),
        const CapabilityUnavailableFailure('host.browser.show', 'no display'),
        const ProtocolViolationFailure('p'),
        const RuntimeUnavailableFailure('r'),
      ];
      for (final failure in failures) {
        final ProtocolFrame frame = await _throughBytes(
          ProtocolFrame(type: FrameType.response, id: '1', generation: 1, error: failure.toWire()),
        );
        final Map<String, Object?> err = frame.error!;
        final decoded = SourceFailure.fromWire(
          err['code']! as String,
          err['message']! as String,
          operation: err['operation'] as String?,
        );
        check(decoded.runtimeType).equals(failure.runtimeType);
        check(decoded.toString()).equals(failure.toString());
      }
    });
  });

  group('strict decoding', () {
    test('a missing required field is a FormatException', () {
      check(
        () => HandshakeResponse.fromJson(const <String, Object?>{'protocolVersion': 1, 'worker': 'x'}),
      ).throws<FormatException>().has((FormatException e) => e.message, 'message').contains('capabilities');
      check(() => HostBrowserLoad.fromJson(const <String, Object?>{'session': 's'})).throws<FormatException>();
      check(
        () => WorkerDetailsResponse.fromJson(const <String, Object?>{'chapters': <Object?>[]}),
      ).throws<FormatException>();
    });

    test('a source ID sent as a JSON number is rejected', () {
      check(
        () => WorkerSearchRequest.fromJson(<String, Object?>{
          'source': <String, Object?>{...source.toJson(), 'sourceId': 9223372036854775807},
          'settingsRevision': 'r',
          'query': 'q',
        }),
      ).throws<FormatException>();
      check(
        () => LoadedSource.fromJson(<String, Object?>{
          'sourceId': 1,
          'name': 'n',
          'capabilities': <String, Object?>{'operations': <Object?>[]},
        }),
      ).throws<FormatException>();
    });

    test('wrong JSON types are rejected, unknown fields are ignored', () {
      check(
        () => PackageLoadRequest.fromJson(<String, Object?>{
          'artifact': artifact.toJson(),
          'path': '/p',
          'settings': <String, Object?>{
            'values': <String, Object?>{'ratio': 1.5},
            'secrets': <String, Object?>{},
            'revision': 'r',
          },
        }),
      ).throws<FormatException>();
      check(
        () => WorkerSearchResponse.fromJson(const <String, Object?>{'hits': 'none'}),
      ).throws<FormatException>();
      final opened = HostBrowserOpened.fromJson(const <String, Object?>{
        'session': 's',
        'debug': 'extra',
      });
      check(opened.session).equals('s');
    });
  });
}
