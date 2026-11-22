// U15 harness: runs real conversion jobs through the app's iOS composition
// root (`IosSourceRuntimes`, `ConversionService`) with replayed captures, so
// no request reaches a server.
//
// - Source traffic: Aidoku replays fixtures/source_captures/aidoku (embedded
//   in aidoku_fixture_bundle.g.dart); Paperback replays fixtures/
//   source_captures/paperback inside the worker isolate; Tachi replays the
//   captures staged into the runtime payload (`stage_runtime.sh <sdk>
//   --test`) inside the embedded JVM.
// - Repository catalogs: the committed Tachi repo.json/index.json captures
//   and pinned inkdex 0.9 catalog are served from the repository checkout;
//   the Aidoku source list is synthesized here, because Aidoku has no
//   committed catalog capture. It only points at the committed `.aix`.
// - The WKWebView port runs in offline mode: every http(s) load is blocked.
//
// Fixture files are read from the host checkout (SRT_REPO_ROOT), which only
// a simulator can do; a device run needs them bundled (open item).

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:mangabackupconverter/src/features/conversion/application/conversion_composition.dart';
import 'package:mangabackupconverter/src/features/conversion/application/conversion_service.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_ios/source_runtime_ios.dart';
import 'package:tachi_plugin_loader/testing.dart';

import '../aidoku_fixture_bundle.g.dart';
import 'conversion_harness.dart';

export 'conversion_harness.dart';

// ignore: do_not_use_environment
const String repoRoot = String.fromEnvironment('SRT_REPO_ROOT');

String get evidenceClass =>
    Platform.resolvedExecutable.contains('/CoreSimulator/')
    ? 'simulator'
    : 'device';

/// The app container's `Library/Application Support` (survives relaunches
/// of the same installation).
Directory get appSupport => Directory(
  '${Directory.systemTemp.parent.path}/Library/Application Support',
);

/// The app's iOS runtimes wired to replayed captures.
final class IosConversionHarness extends ConversionHarness {
  IosConversionHarness._(
    Directory root,
    this.runtimes,
    this.aidokuSite,
    this.logs,
  ) : super(root, 'U15');

  final IosSourceRuntimes runtimes;
  final HoldableClient aidokuSite;
  final List<String> logs;

  @override
  late final ConversionService service = runtimes.service();

  /// Builds the runtimes. [tachiNativeDeadline] and [tachiReplayHang] let a
  /// case force the engine deadline.
  static Future<IosConversionHarness> create({
    Duration tachiNativeDeadline = const Duration(minutes: 9),
    List<String> tachiReplayHang = const <String>[],
    String label = 'u15',
  }) async {
    if (repoRoot.isEmpty) {
      throw StateError('Pass --dart-define=SRT_REPO_ROOT=<repository root>');
    }
    final bundle = BundledRuntime.prepare();
    final String? testData = bundle.testData;
    if (testData == null) {
      throw StateError('Stage the payload with stage_runtime.sh <sdk> --test');
    }
    final Directory root = Directory.systemTemp.createTempSync('$label-');
    aidokuFixtureBundle.forEach((String path, String b64) {
      File('${root.path}/aidoku/$path')
        ..createSync(recursive: true)
        ..writeAsBytesSync(base64.decode(b64));
    });
    final logs = <String>[];
    final aidokuSite = HoldableClient(
      ReplayHttpClient(
        loadCaptureSet(
          Directory('${root.path}/aidoku/captures/en.weebcentral'),
        ),
      ),
    );
    final paperback = Directory(
      '$repoRoot/fixtures/source_captures/paperback',
    );
    final String paperbackSites = paperback.path;
    final fetch = FixtureFetch(<FixtureRepository>[
      FixtureRepository(
        baseUrl: keiyoushiRepository,
        captures: tachiCaptures(Directory(repoRoot)),
      ),
    ]);
    final config = IosConversionConfig(
      storageRoot: Directory('${root.path}/storage')..createSync(),
      tachiLimits: IosTachiLimits(
        supervisor: SupervisorLimits(
          maxConcurrentPackages: 2,
          operationDeadline: tachiNativeDeadline + const Duration(minutes: 1),
          cancelGrace: const Duration(seconds: 5),
          interactionTimeout: const Duration(seconds: 30),
          shutdownGrace: const Duration(seconds: 10),
        ),
        nativeDeadline: tachiNativeDeadline,
      ),
      interactionTimeout: const Duration(seconds: 30),
      client: fixtureCatalogClient(
        aidokuAix: File('${root.path}/aidoku/aix/en.weebcentral-v6.aix'),
        inkdex: Directory('${paperback.path}/inkdex-0.9'),
      ),
      aidokuSiteClient: aidokuSite,
      paperbackSiteClient: () => MultiReplayHttpClient.load(<Directory>[
        Directory('$paperbackSites/weebcentral'),
        Directory('$paperbackSites/mangafire'),
      ]),
      tachiFetch: fetch.call,
      tachiReplay: <String>[
        for (final String s in tachiCaptureSources) '$testData/$s',
      ],
      tachiReplayHang: tachiReplayHang,
      browser: WKWebViewBrowserConfig(
        allowInteraction: false,
        offlineAllowedHosts: const <String>{},
        storageDeletionTimeout: const Duration(seconds: 10),
        onLog: logs.add,
      ),
      onLog: (String line) {
        logs.add(line);
        print('U15_LOG $line');
      },
    );
    final SourceOutcome<IosSourceRuntimes> started =
        await IosSourceRuntimes.start(config);
    final IosSourceRuntimes runtimes =
        started.valueOrNull ??
        (throw StateError('iOS runtimes: ${started.failureOrNull}'));
    return IosConversionHarness._(root, runtimes, aidokuSite, logs);
  }

  /// Resource counters that must return to their baseline after each job.
  Map<String, Object?> resources() => <String, Object?>{
    'browserSessions': runtimes.browserPort?.sessions.length,
    'aidokuPendingCalls': runtimes.aidoku?.pendingCalls,
    'liveVmWorkers': InVmWorkerProcess.liveWorkers,
    'armedDeadlines': InVmWorkerProcess.armedDeadlines,
    'jniGlobalRefs': runtimes.jvm?.globalRefCount,
    'vmCount': runtimes.jvm?.createdVmCount(),
  };

  Future<void> close() async {
    await runtimes.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
