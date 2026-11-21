// U14 harness: runs real conversion jobs through the app's Android
// composition root (`AndroidSourceRuntimes`, `ConversionService`) with
// replayed captures, so no request reaches a server.
//
// - Aidoku replays fixtures/source_captures/aidoku (embedded in
//   aidoku_fixture_bundle.g.dart) in the app process.
// - Paperback replays fixtures/source_captures/paperback inside the worker
//   isolate; the captures and the pinned inkdex 0.9 catalog reach the device
//   through the plugin's debug-only asset folder.
// - Tachi runs in the `:source_runtime` service with `--replay` over the
//   pinned keiyoushi APK captures (debug asset folder) and
//   `--offline-browser`; catalogs and APKs are served from the same
//   captures. The synthetic U11 fixture repository (test-only signer) is
//   added for the AE10 cases.
// - The app-process WebView port runs in replay mode: every http(s) load
//   goes to a loopback refuser (no DNS, no network).
//
// Everything staged here is test-only and lives in the debug variant; the
// release APK carries none of it (scripts/android_package_check.sh).

// ignore_for_file: avoid_print, do_not_use_environment

import 'dart:convert';
import 'dart:io';

import 'package:mangabackupconverter/src/features/conversion/application/conversion_composition.dart';
import 'package:mangabackupconverter/src/features/conversion/application/conversion_service.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_android/source_runtime_android.dart';
import 'package:tachi_plugin_loader/testing.dart';

import '../aidoku_fixture_bundle.g.dart';
import 'conversion_harness.dart';

export 'conversion_harness.dart';

/// The app's package name; the service process is `<package>:source_runtime`.
const String appPackage = 'dev.getboolean.mangabackupconverter';
const String serviceProcessName = '$appPackage:source_runtime';

/// The app's data directory (`/data/user/0/<package>`): survives relaunches
/// of the same installation, and `run-as` reaches it from the host.
Directory get appDataDirectory => Directory.systemTemp.parent;

/// Device facts every receipt carries (Evidence Identity, Android).
Future<Map<String, Object?>> deviceFacts() async {
  Future<String> prop(String name) async =>
      ((await Process.run('getprop', <String>[name])).stdout as String).trim();
  final emulator = await prop('ro.kernel.qemu') == '1';
  return <String, Object?>{
    'evidenceClass': emulator ? 'emulator' : 'device',
    'sdk': int.tryParse(await prop('ro.build.version.sdk')),
    'release': await prop('ro.build.version.release'),
    'abi': await prop('ro.product.cpu.abi'),
    'model': await prop('ro.product.model'),
    'buildType': const bool.fromEnvironment('dart.vm.product')
        ? 'release'
        : 'debug',
  };
}

/// PIDs of this app's processes named [name] (same UID, so `/proc` shows
/// them).
List<int> processIds(String name) {
  final pids = <int>[];
  for (final FileSystemEntity e in Directory('/proc').listSync()) {
    final int? pid = int.tryParse(
      e.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    );
    if (pid == null) continue;
    try {
      final String cmd = File('/proc/$pid/cmdline').readAsStringSync();
      if (cmd.split('\u0000').first == name) pids.add(pid);
    } on FileSystemException {
      // The process ended or is not ours.
    }
  }
  return pids;
}

/// The live `:source_runtime` service processes.
List<int> servicePids() => processIds(serviceProcessName);

/// The app's Android runtimes wired to replayed captures.
final class AndroidConversionHarness extends ConversionHarness {
  AndroidConversionHarness._(
    Directory root,
    this.runtimes,
    this.aidokuSite,
    this.logs,
    this.fixtureRepositoryUrl,
  ) : super(root, 'U14');

  final AndroidSourceRuntimes runtimes;
  final HoldableClient aidokuSite;
  final List<String> logs;

  /// The synthetic fixture repository, when the harness serves it.
  final String? fixtureRepositoryUrl;

  @override
  late final ConversionService service = runtimes.service();

  @override
  List<String> get extraTachiRepositories => <String>[
    ?fixtureRepositoryUrl,
  ];

  /// Builds the runtimes. [tachiArguments] adds worker arguments (`--limit`,
  /// `--challenge-once`); [fixtureRepository] serves the U11 synthetic
  /// fixture repository beside keiyoushi; [root] keeps state across app
  /// launches (journal cases).
  static Future<AndroidConversionHarness> create({
    String label = 'u14',
    List<String> tachiArguments = const <String>[],
    bool fixtureRepository = false,
    Directory? root,
  }) async {
    final Directory dir =
        root ?? Directory.systemTemp.createTempSync('$label-');
    dir.createSync(recursive: true);
    aidokuFixtureBundle.forEach((String path, String b64) {
      File('${dir.path}/aidoku/$path')
        ..createSync(recursive: true)
        ..writeAsBytesSync(base64.decode(b64));
    });
    final logs = <String>[];
    final aidokuSite = HoldableClient(
      ReplayHttpClient(
        loadCaptureSet(Directory('${dir.path}/aidoku/captures/en.weebcentral')),
      ),
    );
    final String paperback = copyFixtureAssetDirectory(
      'source_captures/paperback',
    );
    final repositories = <FixtureRepository>[
      FixtureRepository(
        baseUrl: keiyoushiRepository,
        captures: <TachiCapture>[
          for (final String name in tachiCaptureSources)
            TachiCapture(Directory(copyFixtureAssetDirectory(name))),
        ],
      ),
    ];
    String? fixtureUrl;
    if (fixtureRepository) {
      final String fixtures = copyFixtureAssetDirectory('android-fixtures');
      final summary = jsonDecode(
        File('$fixtures/fixtures.json').readAsStringSync(),
      ) as Map<String, Object?>;
      fixtureUrl = summary['repository']! as String;
      repositories.add(
        FixtureRepository(
          baseUrl: Uri.parse(fixtureUrl),
          name: 'U11 fixtures',
          fingerprint: summary['signingKeyFingerprint']! as String,
          captures: <TachiCapture>[
            for (final String pkg
                in (summary['packages']! as Map<String, Object?>).keys)
              TachiCapture(Directory('$fixtures/$pkg')),
          ],
        ),
      );
    }
    void log(String line) {
      logs.add(line);
      print('U14_LOG $line');
    }

    final config = AndroidConversionConfig(
      storageRoot: Directory('${dir.path}/storage')
        ..createSync(recursive: true),
      interactionTimeout: const Duration(seconds: 30),
      // Unattended: challenges and interactions answer interaction-required.
      interactive: false,
      client: fixtureCatalogClient(
        aidokuAix: File('${dir.path}/aidoku/aix/en.weebcentral-v6.aix'),
        inkdex: Directory('$paperback/inkdex-0.9'),
      ),
      aidokuSiteClient: aidokuSite,
      paperbackSiteClient: () => MultiReplayHttpClient.load(<Directory>[
        Directory('$paperback/weebcentral'),
        Directory('$paperback/mangafire'),
      ]),
      tachiFetch: FixtureFetch(repositories).call,
      tachiWorkerArguments: <String>[
        for (final String name in tachiCaptureSources) ...<String>[
          '--replay',
          name,
        ],
        '--offline-browser',
        ...tachiArguments,
      ],
      browser: AndroidBrowserConfig(
        allowInteraction: false,
        offline: true,
        onLog: log,
      ),
      onLog: log,
    );
    final SourceOutcome<AndroidSourceRuntimes> started =
        await AndroidSourceRuntimes.start(config);
    final AndroidSourceRuntimes runtimes =
        started.valueOrNull ??
        (throw StateError('Android runtimes: ${started.failureOrNull}'));
    return AndroidConversionHarness._(
      dir,
      runtimes,
      aidokuSite,
      logs,
      fixtureUrl,
    );
  }

  /// The current conversion's Tachi supervisor, once its worker started.
  WorkerSupervisor? get tachiSupervisor =>
      runtimes.tachiScope?.supervisors[WorkerKind.jvm];

  /// Resource counters that must return to their baseline after each job.
  Map<String, Object?> resources() => <String, Object?>{
    'browserSessions': runtimes.browserPort?.sessions.length,
    'tachiScopeOpen': runtimes.tachiScope != null,
    'paperbackScopeOpen': runtimes.paperbackScope != null,
    'servicePids': servicePids(),
  };

  /// Replay misses reported by any runtime (none may occur).
  int get replayMisses =>
      logs.where((String l) => l.contains('capture miss')).length;

  Future<void> close({bool deleteRoot = true}) async {
    await runtimes.close();
    if (deleteRoot && root.existsSync()) root.deleteSync(recursive: true);
  }
}
