/// End-to-end: the `source_runtime` supervisor speaking protocol 1.1 to the
/// real Tachi JVM worker (`./gradlew installDist`). It lives here because
/// `tools/tachi-source-runner` is not a Dart package; this package already
/// hosts the Paperback end-to-end tests.
///
/// Prerequisites, from `tools/tachi-source-runner/`:
///
///     ./gradlew installDist fixtureJar_prefs
///
/// and Java 21.0.13.1+ in `TACHI_JAVA_HOME`, the default Corretto path, or
/// `JAVA_HOME`. Without them the tests are skipped with the reason. No test contacts a server: `prepare`
/// uses the committed keiyoushi capture JAR and the `prefs` fixture answers
/// search from its preferences.
@TestOn('vm')
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import 'e2e_support.dart';

/// keiyoushi's published signing certificate SHA-256 (the qualification pin).
const String _keiyoushiSigner = '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2';

final Directory _root = repoRoot();
final String _runner = '${_root.path}/tools/tachi-source-runner';
final Directory _installLib = Directory(
  '$_runner/build/install/tachi-source-runner/lib',
);
final File _prefsJar = File('$_runner/build/fx/fixture-prefs.jar');
final File _weebCentralJar = File(
  '${_root.path}/fixtures/source_captures/tachi/en.weebcentral/tachiyomi-en.weebcentral-v1.6.27.jar',
);

String? _javaExecutable() {
  final exe = Platform.isWindows ? 'java.exe' : 'java';
  for (final home in <String?>[
    Platform.environment['TACHI_JAVA_HOME'],
    // The README's Corretto install comes before JAVA_HOME, which may name a JDK below the worker's floor.
    if (Platform.isWindows) r'C:\Program Files\Amazon Corretto\jdk21.0.13_1',
    Platform.environment['JAVA_HOME'],
  ]) {
    if (home == null) continue;
    final file = File('$home/bin/$exe');
    if (file.existsSync()) return file.path;
  }
  return null;
}

String? _skipReason() {
  if (_javaExecutable() == null) {
    return 'No Java 21 (set JAVA_HOME or TACHI_JAVA_HOME)';
  }
  if (!_installLib.existsSync()) {
    return 'Tachi worker not built: run ./gradlew installDist in tools/tachi-source-runner';
  }
  if (!_prefsJar.existsSync()) {
    return 'fixture-prefs.jar not built: run ./gradlew fixtureJar_prefs';
  }
  return null;
}

WorkerSupervisor _supervisor(Directory state) => WorkerSupervisor(
  spec: WorkerSpec(
    label: 'jvm',
    executable: _javaExecutable()!,
    arguments: <String>[
      '-cp',
      '${_installLib.path}${Platform.isWindows ? r'\*' : '/*'}',
      'mangabackup.tachi.MainKt',
      '--state-dir',
      state.path,
      '--no-browser',
      // Small explicit limits for a test (KTD25); the worker adopts them as overrides.
      for (final String limit in const <String>[
        'poolSize=2',
        'operationDeadlineMs=60000',
        'cancelGraceMs=2000',
        'interactionTimeoutMs=10000',
        'shutdownGraceMs=5000',
      ]) ...<String>['--limit', limit],
    ],
    environment: scrubbedEnvironment(),
  ),
  // Every limit comes from the worker's handshake.
  limits: const AdoptWorkerLimits(handshakeDeadline: Duration(minutes: 1)),
  onLog: (String line) => stderr.writeln('[tachi-e2e] $line'),
);

const ArtifactProfile _rawProfile = ArtifactProfile(
  producer: 'test',
  converterVersion: '1',
  hostCompatibility: 'test',
);

void main() {
  final String? skip = _skipReason();
  group('Tachi worker over protocol 1.1', skip: skip, () {
    late Directory temp;
    late ArtifactCache cache;
    late WorkerSupervisor supervisor;

    setUp(() async {
      temp = Directory.systemTemp.createTempSync('tachi_e2e_');
      cache = ArtifactCache(Directory('${temp.path}/cache'));
      supervisor = _supervisor(Directory('${temp.path}/state')..createSync());
      final SourceOutcome<HandshakeResponse> started = await supervisor.start();
      final HandshakeResponse handshake = (started as SourceSuccess<HandshakeResponse>).value;
      check(handshake.worker).equals('tachi-jvm');
      check(handshake.protocolMinor).equals(1);
      check(supervisor.limits!.maxConcurrentPackages).equals(2);
      check(supervisor.limits!.operationDeadline).equals(const Duration(minutes: 1));
    });

    tearDown(() async {
      await supervisor.close();
      temp.deleteSync(recursive: true);
    });

    Future<ArtifactLease> admitRaw(File file) {
      final Uint8List bytes = file.readAsBytesSync();
      return cache.admit(
        bytes,
        binding: ArtifactBinding(
          sha256: sha256Hex(bytes),
          kind: 'jar',
          version: '1',
        ),
        profile: _rawProfile,
        verifier: (Uint8List b, ArtifactBinding a) {},
      );
    }

    test('artifact.prepare verifies the capture JAR against the trusted signer and the result loads', () async {
      final ArtifactLease input = await admitRaw(_weebCentralJar);
      final SourceOutcome<ArtifactLease> prepared = await supervisor.prepareArtifact(
        packageId: 'eu.kanade.tachiyomi.extension.en.weebcentral',
        input: input,
        trust: ArtifactTrustAnchor(
          signerFingerprints: <String>[_keiyoushiSigner.toUpperCase()],
        ),
        cache: cache,
        hostCompatibility: 'tachi-host.1',
      );
      final ArtifactLease lease = (prepared as SourceSuccess<ArtifactLease>).value;
      check(lease.binding.kind).equals('jar');

      final SourceOutcome<PackageLoadResponse> load = await supervisor.loadPackage(
        WorkerPackage(
          packageId: 'eu.kanade.tachiyomi.extension.en.weebcentral',
          artifact: lease,
          settings: SettingsSnapshot(),
        ),
      );
      check(
        (load as SourceSuccess<PackageLoadResponse>).value.sources.map(
          (LoadedSource s) => s.name,
        ),
      ).contains(
        'Weeb Central',
      );
    });

    test(
      'artifact.prepare refuses a JAR signed by anyone but the trusted signers',
      () async {
        final ArtifactLease input = await admitRaw(_weebCentralJar);
        final SourceOutcome<ArtifactLease> prepared = await supervisor.prepareArtifact(
          packageId: 'eu.kanade.tachiyomi.extension.en.weebcentral',
          input: input,
          trust: ArtifactTrustAnchor(
            signerFingerprints: <String>['ab' * 32],
          ),
          cache: cache,
          hostCompatibility: 'tachi-host.1',
        );
        check((prepared as SourceFailed<ArtifactLease>).failure).isA<ArtifactIncompatibleFailure>();
      },
    );

    test('string sets and per-source scopes seed each source_<id> store, on load and on settings.update', () async {
      final ArtifactLease lease = await admitRaw(_prefsJar);
      final settings = SettingsSnapshot(
        values: const <String, Object>{
          'lang': 'en',
          'tags': <String>['b', 'a', 'b'],
        },
        sources: <String, SourceScopedSettings>{
          '102': SourceScopedSettings(
            values: const <String, Object>{
              'lang': 'ja',
              'tags': <String>['z'],
            },
            secrets: const <String, String>{'password': 'e2e-secret'},
          ),
        },
      );
      final SourceOutcome<PackageLoadResponse> load = await supervisor.loadPackage(
        WorkerPackage(
          packageId: 'fixture.prefs',
          artifact: lease,
          settings: settings,
        ),
      );
      check(
        (load as SourceSuccess<PackageLoadResponse>).value.sources.map(
          (LoadedSource s) => s.sourceId,
        ),
      ).unorderedEquals(<String>['101', '102']);

      Future<String> title(String sourceId, String revision) async {
        final SourceOutcome<WorkerSearchResponse> reply = await supervisor.send(
          'fixture.prefs',
          WorkerSearchRequest(
            source: SourceIdentity(
              ecosystem: 'tachi',
              packageId: 'fixture.prefs',
              sourceId: sourceId,
              artifact: lease.binding,
            ),
            settingsRevision: revision,
            request: const SearchRequest(query: 'q'),
          ),
        );
        return (reply as SourceSuccess<WorkerSearchResponse>).value.hits.single.hit.title;
      }

      check(await title('101', settings.revision)).equals('lang=en;tags=a,b;password=unset');
      check(await title('102', settings.revision)).equals('lang=ja;tags=z;password=set');

      final updated = SettingsSnapshot(
        values: const <String, Object>{'lang': 'fr'},
        sources: <String, SourceScopedSettings>{
          '101': SourceScopedSettings(
            values: const <String, Object>{
              'tags': <String>['c'],
            },
          ),
        },
      );
      check(await supervisor.updateSettings('fixture.prefs', updated)).isA<SourceSuccess<EmptyPayload>>();
      check(await title('101', updated.revision)).equals('lang=fr;tags=c;password=unset');
      check(await title('102', updated.revision)).equals('lang=fr;tags=;password=unset');
    });
  });
}
