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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter/src/features/conversion/application/conversion_composition.dart';
import 'package:mangabackupconverter/src/features/conversion/application/conversion_service.dart';
import 'package:mangabackupconverter/src/features/conversion/data/app_file_stores.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_ios/source_runtime_ios.dart';
import 'package:tachi_plugin_loader/testing.dart';

import '../aidoku_fixture_bundle.g.dart';

// ignore: do_not_use_environment
const String repoRoot = String.fromEnvironment('SRT_REPO_ROOT');

/// The synthesized Aidoku source list (test only; never shipped).
const String aidokuRepository = 'https://aidoku.invalid/index.json';
const String inkdexRepository =
    'https://inkdex.github.io/extensions/0.9/stable/';

const String tachiWeebCentralId = '2131019126180322627';
const String weebCentralSeries =
    '/series/01J76XYF0TGKQ7XJ4XVPV1C0BP/ONIMAI-Im-Now-Your-Sister';
const String onimaiTitle = "ONIMAI - I'm Now Your Sister!";

String get evidenceClass =>
    Platform.resolvedExecutable.contains('/CoreSimulator/')
    ? 'simulator'
    : 'device';

/// The app container's `Library/Application Support` (survives relaunches
/// of the same installation).
Directory get appSupport => Directory(
  '${Directory.systemTemp.parent.path}/Library/Application Support',
);

/// Holds every response of the wrapped client while [holding], so a call is certainly
/// in flight when a test backgrounds the app or cancels it.
final class HoldableClient extends http.BaseClient {
  HoldableClient(this._inner);

  final http.Client _inner;
  Completer<void>? _gate;
  int inFlight = 0;
  int requests = 0;

  bool get holding => _gate != null;

  void hold() => _gate ??= Completer<void>();

  void release() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    inFlight++;
    try {
      final Completer<void>? gate = _gate;
      if (gate != null) await gate.future;
      return await _inner.send(request);
    } finally {
      inFlight--;
    }
  }
}

/// Picks extensions whose id contains [pick], trusts repositories once, and
/// confirms the first hit whose title contains "onimai".
final class ScriptedSelection {
  ScriptedSelection({
    required this.pick,
    this.query = 'Onimai',
    this.acceptPartial = false,
    this.beforeSearch,
  });

  final String pick;
  final String query;
  final bool acceptPartial;

  /// Runs instead of the plain search (lifecycle cases).
  final Future<PluginSearchResult?> Function(
    Stream<PluginSearchEvent> Function(String query) onSearch,
  )?
  beforeSearch;

  final List<PluginSearchFailure> searchFailures = <PluginSearchFailure>[];
  int confirmCalls = 0;
  int mangaAsked = 0;

  SelectionPort get port => CallbackSelectionPort(
    onSelectExtensions: (List<ExtensionEntry> e) async => e
        .where((ExtensionEntry x) => x.id.toLowerCase().contains(pick))
        .toList(),
    onRepositoryTrust: (_) async => TrustDecision.trustOnce,
    onConfirmMatches: (_, List<SourceMangaData> manga, onSearch, _) async {
      confirmCalls++;
      mangaAsked += manga.length;
      if (manga.isEmpty) return const <MangaMatchConfirmation>[];
      final PluginSearchResult? hit = beforeSearch != null
          ? await beforeSearch!(onSearch)
          : await search(onSearch, query);
      return <MangaMatchConfirmation>[
        if (hit != null)
          MangaMatchConfirmation(
            sourceManga: manga.single,
            confirmedMatch: hit,
          ),
      ];
    },
    acceptPartial: acceptPartial,
  );

  /// Collects every result of one search and returns the Onimai hit.
  Future<PluginSearchResult?> search(
    Stream<PluginSearchEvent> Function(String query) onSearch,
    String query,
  ) async {
    final hits = <PluginSearchResult>[];
    await for (final PluginSearchEvent e in onSearch(query)) {
      switch (e) {
        case PluginSearchResults():
          hits.addAll(e.results);
        case PluginSearchError(:final PluginSearchFailure failure):
          searchFailures.add(failure);
        case PluginSearchStarted():
          break;
      }
    }
    return hits
        .where(
          (PluginSearchResult r) => r.title.toLowerCase().contains('onimai'),
        )
        .firstOrNull;
  }
}

/// One conversion's outcome.
final class HarnessRun {
  HarnessRun({
    required this.source,
    required this.target,
    required this.result,
    required this.published,
    required this.outputPath,
    required this.elapsed,
    required this.maxTickGap,
  });

  final BackupFormat source;
  final BackupFormat target;
  final ConversionResult result;
  final Uint8List published;
  final String outputPath;
  final Duration elapsed;

  /// Largest gap between 16 ms ticks of a root-isolate timer during the job
  /// (the main run loop never blocked if it stays small).
  final Duration maxTickGap;
}

/// The app's iOS runtimes wired to replayed captures.
final class IosConversionHarness {
  IosConversionHarness._(this.root, this.runtimes, this.aidokuSite, this.logs);

  final Directory root;
  final IosSourceRuntimes runtimes;
  final HoldableClient aidokuSite;
  final List<String> logs;

  late final ConversionService service = runtimes.service();
  final FormatRegistry formats = FormatRegistry.portable();

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
      client: _catalogClient(root, paperback),
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

  /// Serves the synthesized Aidoku list and `.aix`, and the pinned inkdex
  /// catalog and bundles; anything else is a 404.
  static http.Client _catalogClient(
    Directory root,
    Directory paperback,
  ) => MockClient((http.Request r) async {
    final url = r.url.toString();
    if (url == aidokuRepository) {
      return http.Response(
        jsonEncode(<String, Object?>{
          'name': 'U15 fixture list (test only)',
          'sources': <Object?>[
            <String, Object?>{
              'id': 'en.weebcentral',
              'name': 'Weeb Central',
              'version': 6,
              'iconURL': 'icon.png',
              'downloadURL': 'sources/en.weebcentral-v6.aix',
              'languages': <String>['en'],
            },
          ],
        }),
        200,
      );
    }
    if (url == 'https://aidoku.invalid/sources/en.weebcentral-v6.aix') {
      return http.Response.bytes(
        File('${root.path}/aidoku/aix/en.weebcentral-v6.aix').readAsBytesSync(),
        200,
      );
    }
    if (url.startsWith(inkdexRepository)) {
      final file = File(
        '${paperback.path}/inkdex-0.9/${url.substring(inkdexRepository.length)}',
      );
      if (file.existsSync()) {
        return http.Response.bytes(file.readAsBytesSync(), 200);
      }
    }
    return http.Response('not found', 404);
  });

  /// The repositories the user would supply for [target].
  static List<String> reposFor(BackupFormat target) => switch (target) {
    Paperback() => const <String>[inkdexRepository],
    Tachiyomi() => <String>[keiyoushiRepository.toString()],
    _ => const <String>[aidokuRepository],
  };

  /// An input backup of [format]: chapter 1 read, chapter 2 partly read,
  /// chapter 3 bookmarked, written by the format's own writer.
  Future<Uint8List> input(BackupFormat format) {
    final String ecosystem = switch (format) {
      Aidoku() => 'aidoku',
      Paperback() => 'paperback',
      _ => 'tachi',
    };
    final identity = SourceIdentity(
      ecosystem: ecosystem,
      packageId: 'origin',
      sourceId: ecosystem == 'tachi' ? '1234567890123456789' : 'en.origin',
      artifact: const ArtifactBinding(
        sha256: 'abc',
        kind: 'test',
        version: '1',
      ),
    );
    final ref = NativeMangaRef(
      source: identity,
      mangaId: 'origin-manga',
      settingsRevision: 'rev',
    );
    final manga = SourceMangaData(
      details: MangaSearchDetails(title: onimaiTitle),
      categories: const <String>['Reading'],
      chapters: <SourceChapter>[
        SourceChapter(
          title: 'Step 1',
          chapterKey: 'o1',
          chapterNumber: 1,
          isRead: true,
          dateRead: DateTime.utc(2024),
        ),
        SourceChapter(
          title: 'Step 2',
          chapterKey: 'o2',
          chapterNumber: 2,
          lastPageRead: 4,
          totalPages: 18,
        ),
        SourceChapter(
          title: 'Step 3',
          chapterKey: 'o3',
          chapterNumber: 3,
          isBookmarked: true,
        ),
      ],
    );
    final MangaMatchConfirmation c =
        MangaMatchConfirmation(
          sourceManga: manga,
          confirmedMatch: PluginSearchResult(ref: ref, title: onimaiTitle),
        ).withDestination(
          FetchedManga(
            MangaSnapshot(
              ref: ref,
              metadata: const MangaMetadata(title: onimaiTitle),
              chapters: <NativeChapter>[
                for (var i = 1; i <= 3; i++)
                  NativeChapter(
                    chapterId: 'origin-$i',
                    sourceOrder: 3 - i,
                    chapterNumber: i.toDouble(),
                    title: 'Step $i',
                    language: 'en',
                  ),
              ],
            ),
          ),
        );
    return formats.writerFor(format)!.build(<MangaConversionPlan>[
      planConversion(c),
    ]).toData();
  }

  /// The extension id fragment that selects WeebCentral in each ecosystem.
  static String weebCentralPick(BackupFormat target) => 'weebcentral';

  /// Runs one conversion through [service] and publishes into
  /// `<root>/out/` inside the app sandbox.
  Future<HarnessRun> convert(
    BackupFormat source,
    BackupFormat target, {
    ScriptedSelection? selection,
    Uint8List? inputBytes,
    ConversionOutput? output,
    JournalStore? journal,
    void Function(int decisions)? onResume,
  }) async {
    final outDir = Directory('${root.path}/out')..createSync(recursive: true);
    final path =
        '${outDir.path}/${source.alias}-to-${target.alias}${target.extensions.first}';
    // Aidoku and Paperback cannot hold a Mihon bookmark, so those runs are
    // partial by design and accepted (as in the desktop six-direction test).
    final ScriptedSelection s =
        selection ??
        ScriptedSelection(pick: weebCentralPick(target), acceptPartial: true);
    var last = DateTime.now();
    Duration maxGap = Duration.zero;
    final ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final now = DateTime.now();
      final Duration gap = now.difference(last);
      if (gap > maxGap) maxGap = gap;
      last = now;
    });
    final watch = Stopwatch()..start();
    try {
      final ConversionResult result = await service.convert(
        ConversionRequest(
          input: inputBytes ?? await input(source),
          sourceFormat: source,
          targetFormat: target,
          repoUrls: reposFor(target),
        ),
        selection: s.port,
        output: output ?? AppFileConversionOutput(path),
        journal: journal,
        onResume: onResume,
        onProgress: (int c, int t, String m) => print('U15_PROGRESS $c/$t $m'),
      );
      final out = File(path);
      return HarnessRun(
        source: source,
        target: target,
        result: result,
        published: out.existsSync() ? out.readAsBytesSync() : Uint8List(0),
        outputPath: path,
        elapsed: watch.elapsed,
        maxTickGap: maxGap,
      );
    } finally {
      ticker.cancel();
    }
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
