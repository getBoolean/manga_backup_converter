// KTD6 bundle trust and admission: changed, substituted or untrusted bytes
// are refused before any JavaScript initialisation or host request, on first
// admission, on cache hits, and at the worker.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:quickjs/quickjs.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import 'support/host_harness.dart';
import 'support/paperback_scenarios.dart';

void main() {
  final PinnedRepository inkdex = PinnedRepository.load('inkdex-0.9');
  final PinnedRepository numby = PinnedRepository.load('numby-0.8');
  final Uint8List mangadex09 = inkdex.bundle('MangaDex');
  final Uint8List weebcentral08 = numby.bundle('WeebCentral');

  group('admitBundle', () {
    test('accepts the pinned bytes under their family', () {
      check(admitBundle(mangadex09, bindingFor(mangadex09, PaperbackApiFamily.v09))).equals(PaperbackApiFamily.v09);
      check(admitBundle(weebcentral08, bindingFor(weebcentral08, PaperbackApiFamily.v08))).equals(PaperbackApiFamily.v08);
    });

    test('refuses changed bytes', () {
      final changed = Uint8List.fromList(mangadex09)..[100] ^= 1;
      check(() => admitBundle(changed, bindingFor(mangadex09, PaperbackApiFamily.v09)))
          .throws<BundleAdmissionException>()
          .has((BundleAdmissionException e) => e.failure, 'failure')
          .isA<ArtifactIncompatibleFailure>();
    });

    test('refuses a bundle bound to the other API family', () {
      check(() => admitBundle(weebcentral08, bindingFor(weebcentral08, PaperbackApiFamily.v09)))
          .throws<BundleAdmissionException>()
          .has((BundleAdmissionException e) => e.failure, 'failure')
          .isA<ArtifactIncompatibleFailure>();
    });

    test('refuses an unsupported artifact kind as unsupported-api', () {
      check(() => admitBundle(mangadex09, ArtifactBinding(sha256: bundleDigest(mangadex09), kind: 'paperback-bundle-0.7', version: '1')))
          .throws<BundleAdmissionException>()
          .has((BundleAdmissionException e) => e.failure, 'failure')
          .isA<UnsupportedApiFailure>();
    });
  });

  test('a substituted bundle fails before any JavaScript initialisation or host request', () async {
    final requests = <http.Request>[];
    final runtime = SourceJsRuntime(limits: testLimits());
    final host = PaperbackSourceHost(
      runtime: runtime,
      http: PaperbackHttp(MockClient((http.Request r) async {
        requests.add(r);
        return http.Response('', 200);
      })),
    );
    try {
      Object? error;
      try {
        // The bytes of one bundle, presented under another's admitted digest.
        await host.load(weebcentral08, bindingFor(mangadex09, PaperbackApiFamily.v09), emptySettings());
      } on PaperbackRuntimeException catch (e) {
        error = e.failure;
      }
      check(error).isA<ArtifactIncompatibleFailure>();
      check(requests).isEmpty();
      // Nothing was installed or evaluated: not even the host primitives.
      final JsValue probe = runtime.context.eval('typeof __pbHost + "/" + typeof Application + "/" + typeof App');
      try {
        check(probe.toDartString()).equals('undefined/undefined/undefined');
      } finally {
        probe.dispose();
      }
    } finally {
      runtime.dispose();
    }
  });

  group('provider admission and cache hits', () {
    late Directory cacheDir;
    late List<(Uri, String)> asked;
    late bool answer;
    late PaperbackSourceProvider provider;

    setUp(() {
      cacheDir = Directory.systemTemp.createTempSync('paperback_admission');
      asked = <(Uri, String)>[];
      answer = true;
      provider = PaperbackSourceProvider(
        client: MockClient((_) async => http.Response('', 404)),
        cache: ArtifactCache(cacheDir),
        trust: (Uri key, String fingerprint) async {
          asked.add((key, fingerprint));
          return answer;
        },
        worker: () async => const SourceFailed<WorkerSupervisor>(RuntimeUnavailableFailure('no worker in this test')),
      );
    });
    tearDown(() => cacheDir.deleteSync(recursive: true));

    test('binds the trust decision to the digest and family under a per-bundle key', () async {
      final SourceOutcome<ArtifactLease> a = await provider.admit(inkdex.entry('MangaDex'), mangadex09);
      final SourceOutcome<ArtifactLease> b = await provider.admit(inkdex.entry('WeebCentral'), inkdex.bundle('WeebCentral'));
      check(a).isA<SourceSuccess<ArtifactLease>>();
      check(b).isA<SourceSuccess<ArtifactLease>>();
      check(asked.map(((Uri, String) q) => q.$1.toString()).toList()).deepEquals(<String>[
        'https://inkdex.github.io/extensions/0.9/stable/#MangaDex',
        'https://inkdex.github.io/extensions/0.9/stable/#WeebCentral',
      ]);
      check(asked.first.$2).equals('paperback-0.9:sha256:${inkdex.pinnedSha256('MangaDex')}');
      check((a as SourceSuccess<ArtifactLease>).value.binding.kind).equals('paperback-bundle-0.9');
    });

    test('an untrusted bundle is refused before it is staged', () async {
      answer = false;
      final SourceOutcome<ArtifactLease> a = await provider.admit(inkdex.entry('MangaDex'), mangadex09);
      check(a).isA<SourceFailed<ArtifactLease>>().has((SourceFailed<ArtifactLease> f) => f.failure, 'failure').isA<ArtifactIncompatibleFailure>();
      check(Directory('${cacheDir.path}/objects').existsSync()).isFalse();
    });

    test('bytes catalogued for one family are refused for the other', () async {
      // numby's 0.8 bundle presented as if the 0.9 catalog listed it.
      final SourceOutcome<ArtifactLease> a = await provider.admit(inkdex.entry('WeebCentral'), weebcentral08);
      check(a).isA<SourceFailed<ArtifactLease>>().has((SourceFailed<ArtifactLease> f) => f.failure, 'failure').isA<ArtifactIncompatibleFailure>();
      check(asked).isEmpty();
    });

    test('a cache hit re-hashes and re-asks trust; modified cached bytes are dropped', () async {
      final lease = (await provider.admit(inkdex.entry('MangaDex'), mangadex09) as SourceSuccess<ArtifactLease>).value;
      final String path = lease.path;
      lease.release();
      asked.clear();
      final SourceOutcome<ArtifactLease>? hit = await provider.cached(inkdex.entry('MangaDex'), inkdex.pinnedSha256('MangaDex'));
      check(hit).isNotNull().isA<SourceSuccess<ArtifactLease>>();
      check(asked).length.equals(1);
      (hit! as SourceSuccess<ArtifactLease>).value.release();

      // Trust withdrawn: the cached bytes are not served.
      answer = false;
      check(await provider.cached(inkdex.entry('MangaDex'), inkdex.pinnedSha256('MangaDex'))).isNotNull().isA<SourceFailed<ArtifactLease>>();

      // Tampered on disk: the entry is dropped, never loaded.
      answer = true;
      final bytes = File(path).readAsBytesSync()..[10] ^= 1;
      File(path).writeAsBytesSync(bytes);
      check(await provider.cached(inkdex.entry('MangaDex'), inkdex.pinnedSha256('MangaDex'))).isNull();
      check(File(path).existsSync()).isFalse();
    });

    test('bytes changed after admission fail at load, before the worker sees them', () async {
      final requests = <http.Request>[];
      final client = MockClient((http.Request r) async {
        requests.add(r);
        return http.Response('', 404);
      });
      final supervisor = WorkerSupervisor(
        spec: const WorkerSpec(label: 'paperback', executable: 'in-process'),
        limits: const SupervisorLimits(
          maxConcurrentPackages: 1,
          operationDeadline: Duration(seconds: 20),
          cancelGrace: Duration(seconds: 2),
          interactionTimeout: Duration(seconds: 2),
          shutdownGrace: Duration(seconds: 2),
        ),
        launcher: inProcessPaperbackLauncher(client: client, limits: testLimits()),
      );
      final p = PaperbackSourceProvider(
        client: client,
        cache: ArtifactCache(cacheDir),
        trust: (_, _) async => true,
        worker: () async => (await supervisor.start()).map((_) => supervisor),
      );
      try {
        final lease = (await p.admit(inkdex.entry('MangaDex'), mangadex09) as SourceSuccess<ArtifactLease>).value;
        final bytes = File(lease.path).readAsBytesSync()..[10] ^= 1;
        File(lease.path).writeAsBytesSync(bytes);
        final SourceOutcome<SourcePackage> opened = await p.openPackage(lease, SettingsSnapshot());
        check(opened).isA<SourceFailed<SourcePackage>>().has((SourceFailed<SourcePackage> f) => f.failure, 'failure').isA<ArtifactIncompatibleFailure>();
        check(requests).isEmpty();
        lease.release();
      } finally {
        await supervisor.close();
      }
    });

    test('an artifact not admitted by the provider is refused', () async {
      final SourceOutcome<SourcePackage> opened = await provider.openPackage(_ForeignArtifact(mangadex09), SettingsSnapshot());
      check(opened).isA<SourceFailed<SourcePackage>>().has((SourceFailed<SourcePackage> f) => f.failure, 'failure').isA<ArtifactIncompatibleFailure>();
    });
  });
}

final class _ForeignArtifact implements VerifiedArtifact {
  _ForeignArtifact(this._bytes);

  final Uint8List _bytes;

  @override
  ArtifactBinding get binding => bindingFor(_bytes, PaperbackApiFamily.v09);

  @override
  Future<Uint8List> readVerified() async => _bytes;
}
