// Platform-neutral parts of the U14/U15 conversion harnesses: the scripted
// selection, the sanitized input backup, the replayed catalogs, one job run
// through the app's `ConversionService`, and the checks every published
// backup must pass. The platform harnesses (android_conversion_harness.dart,
// ios_conversion_harness.dart) supply the runtimes and the fixture paths.
//
// No request reaches a server: catalogs are served from committed captures
// and every site client the platform harness passes replays captures.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter/src/features/conversion/application/conversion_service.dart';
import 'package:mangabackupconverter/src/features/conversion/data/app_file_stores.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/testing.dart';

/// The synthesized Aidoku source list (test only; never shipped).
const String aidokuRepository = 'https://aidoku.invalid/index.json';
const String inkdexRepository =
    'https://inkdex.github.io/extensions/0.9/stable/';

const String tachiWeebCentralId = '2131019126180322627';
const String weebCentralSeries =
    '/series/01J76XYF0TGKQ7XJ4XVPV1C0BP/ONIMAI-Im-Now-Your-Sister';
const String onimaiTitle = "ONIMAI - I'm Now Your Sister!";

/// The six R5 directions.
const List<(BackupFormat, BackupFormat)> r5Directions =
    <(BackupFormat, BackupFormat)>[
      (Paperback(), Aidoku()),
      (Mihon(), Aidoku()),
      (Aidoku(), Paperback()),
      (Mihon(), Paperback()),
      (Aidoku(), Mihon()),
      (Paperback(), Mihon()),
    ];

/// Holds every response of the wrapped client while [holding], so a call is
/// certainly in flight when a test backgrounds the app or cancels it.
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

/// A hold that also works inside another isolate (the Paperback worker):
/// while the file at [path] exists, [FileHoldClient] holds every response
/// and marks `<path>.inflight`. Only the path string crosses isolates.
final class FileHold {
  FileHold(this.path);

  final String path;

  File get _marker => File('$path.inflight');

  void hold() => File(path).createSync(recursive: true);

  void release() {
    if (File(path).existsSync()) File(path).deleteSync();
  }

  /// Whether a held request is waiting.
  bool get inFlight => _marker.existsSync();
}

/// Holds every response of the wrapped client while [holdPath] exists
/// ([FileHold]).
final class FileHoldClient extends http.BaseClient {
  FileHoldClient(this._inner, this.holdPath);

  final http.Client _inner;
  final String holdPath;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (File(holdPath).existsSync()) {
      final marker = File('$holdPath.inflight')..createSync();
      while (File(holdPath).existsSync()) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      try {
        marker.deleteSync();
      } on FileSystemException {
        // Another held request already removed it.
      }
    }
    return _inner.send(request);
  }
}

/// Picks extensions whose id contains one of [picks], trusts repositories
/// once, and confirms the first hit whose title contains "onimai".
final class ScriptedSelection {
  ScriptedSelection({
    required String pick,
    List<String> alsoPick = const <String>[],
    this.query = 'Onimai',
    this.acceptPartial = false,
    this.beforeSearch,
  }) : picks = <String>[pick, ...alsoPick];

  final List<String> picks;
  final String query;
  final bool acceptPartial;

  /// Runs instead of the plain search (lifecycle cases).
  final Future<PluginSearchResult?> Function(
    Stream<PluginSearchEvent> Function(String query) onSearch,
  )?
  beforeSearch;

  final List<PluginSearchFailure> searchFailures = <PluginSearchFailure>[];
  final List<String> pickedExtensions = <String>[];
  int confirmCalls = 0;
  int mangaAsked = 0;

  SelectionPort get port => CallbackSelectionPort(
    onSelectExtensions: (List<ExtensionEntry> e) async {
      final List<ExtensionEntry> picked = e
          .where(
            (ExtensionEntry x) =>
                picks.any((String p) => x.id.toLowerCase().contains(p)),
          )
          .toList();
      pickedExtensions.addAll(picked.map((ExtensionEntry x) => x.id));
      return picked;
    },
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

/// Searches once and records the outcome in [events].
Future<PluginSearchResult?> searchOnce(
  Stream<PluginSearchEvent> Function(String query) onSearch,
  List<String> events, {
  String query = 'Onimai',
}) async {
  final hits = <PluginSearchResult>[];
  await for (final PluginSearchEvent e in onSearch(query)) {
    if (e is PluginSearchResults) hits.addAll(e.results);
    if (e is PluginSearchError) {
      events.add(
        'error:${e.failure.failure.code}:${e.failure.failure.message}',
      );
    }
  }
  return hits
      .where((PluginSearchResult r) => r.title.toLowerCase().contains('onimai'))
      .firstOrNull;
}

/// Polls [condition] every 10 ms until it holds or [timeout] passes.
Future<void> until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) throw TimeoutException('condition', timeout);
    await Future<void>.delayed(const Duration(milliseconds: 10));
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

/// Serves the synthesized Aidoku list and its `.aix` ([aidokuAix]), and the
/// pinned inkdex 0.9 catalog and bundles ([inkdex]); anything else is a 404.
http.Client fixtureCatalogClient({
  required File aidokuAix,
  required Directory inkdex,
}) => MockClient((http.Request r) async {
  final url = r.url.toString();
  if (url == aidokuRepository) {
    return http.Response(
      jsonEncode(<String, Object?>{
        'name': 'Fixture list (test only)',
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
    return http.Response.bytes(aidokuAix.readAsBytesSync(), 200);
  }
  if (url.startsWith(inkdexRepository)) {
    final file = File(
      '${inkdex.path}/${url.substring(inkdexRepository.length)}',
    );
    if (file.existsSync()) {
      return http.Response.bytes(file.readAsBytesSync(), 200);
    }
  }
  return http.Response('not found', 404);
});

/// The ecosystem whose runtime serves [format].
String ecosystemOf(BackupFormat format) => switch (format) {
  Aidoku() => 'aidoku',
  Paperback() => 'paperback',
  _ => 'tachi',
};

/// A conversion harness over the app's [ConversionService]: the platform
/// harness supplies the service (over its composition root) and the
/// directory jobs publish into.
abstract base class ConversionHarness {
  ConversionHarness(this.root, this.logPrefix);

  /// App-private scratch directory of this harness.
  final Directory root;

  /// Prefix of the progress lines (`U14`, `U15`).
  final String logPrefix;

  final FormatRegistry formats = FormatRegistry.portable();

  ConversionService get service;

  /// Extra repositories every Tachi job lists (a fixture repository).
  List<String> get extraTachiRepositories => const <String>[];

  /// The repositories the user would supply for [target].
  List<String> reposFor(BackupFormat target) => switch (target) {
    Paperback() => const <String>[inkdexRepository],
    Tachiyomi() => <String>[
      keiyoushiRepository.toString(),
      ...extraTachiRepositories,
    ],
    _ => const <String>[aidokuRepository],
  };

  /// An input backup of [format]: chapter 1 read, chapter 2 partly read,
  /// chapter 3 bookmarked, in the "Reading" category, written by the
  /// format's own writer.
  Future<Uint8List> input(BackupFormat format) {
    final String ecosystem = ecosystemOf(format);
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

  /// The directory jobs publish into.
  Directory get outDir => Directory('${root.path}/out');

  /// Runs one conversion through [service] and publishes into [outDir]
  /// inside the app's private storage.
  Future<HarnessRun> convert(
    BackupFormat source,
    BackupFormat target, {
    ScriptedSelection? selection,
    Uint8List? inputBytes,
    ConversionOutput? output,
    String? outputPath,
    JournalStore? journal,
    void Function(int decisions)? onResume,
  }) async {
    outDir.createSync(recursive: true);
    final String path =
        outputPath ??
        '${outDir.path}/${source.alias}-to-${target.alias}${target.extensions.first}';
    // Aidoku and Paperback cannot hold a Mihon bookmark, so those runs are
    // partial by design and accepted (as in the desktop six-direction test).
    final ScriptedSelection s =
        selection ??
        ScriptedSelection(pick: 'weebcentral', acceptPartial: true);
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
        onProgress: (int c, int t, String m) =>
            print('${logPrefix}_PROGRESS $c/$t $m'),
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

  /// Complete accounting and validation of [run], plus its destination
  /// checks (AE1 identities, read/partial/bookmark state). Returns the
  /// receipt fields.
  Map<String, Object?> checkRun(HarnessRun run) {
    final ConversionResult result = run.result;
    expect(run.published, result.draft.bytes, reason: 'published bytes');
    expect(
      formats
          .writerFor(run.target)!
          .validate(run.published, result.draft.plans),
      isEmpty,
    );
    final int stateful = mergeHistoryIntoChapters(
      result.input.sourceMangaDataEntries.single,
    ).$1.where((SourceChapter c) => c.hasReadingState).length;
    expect(stateful, run.source is Tachiyomi ? 3 : 2);
    expect(result.report.count(RecordKind.chapterState), stateful);
    expect(
      result.report.count(RecordKind.manga, RecordDisposition.transferred),
      1,
    );
    expect(
      result.report.count(
        RecordKind.chapterState,
        RecordDisposition.transferred,
      ),
      stateful,
    );
    final SourceIdentity runtimeIdentity =
        result.draft.plans.single.confirmation.confirmedMatch!.ref.source;
    expect(runtimeIdentity.ecosystem, ecosystemOf(run.target));
    final String emitted;
    final int chapters;
    switch (run.target) {
      case Aidoku():
        final AidokuBackup b = AidokuBackup.fromData(run.published);
        emitted = b.manga!.single.sourceId;
        chapters = b.chapters!.length;
        expect(emitted, 'en.weebcentral');
        expect(b.history, isNotEmpty);
      case Paperback():
        final b = PaperbackBackup.fromData(run.published);
        emitted = b.sourceManga!.single.sourceId;
        chapters = b.chapters!.length;
        expect(emitted, 'WeebCentral');
        expect(b.chapterProgressMarker, isNotEmpty);
      default:
        final TachiBackupManga m = TachiBackup.fromData(
          run.published,
        ).backupManga.single;
        emitted = m.source.toString();
        chapters = m.chapters.length;
        // AE1: the loaded source's exact int64 ID and its own URLs.
        expect(emitted, tachiWeebCentralId);
        expect(m.url, weebCentralSeries);
        expect(m.chapters.every((c) => !c.url.startsWith('http')), isTrue);
        final TachiBackupChapter partial = m.chapters.singleWhere(
          (c) => c.lastPageRead > 0,
        );
        expect(partial.lastPageRead, 4);
        expect(partial.read, isFalse);
    }
    // The emitted identity is the one the local runtime enumerated.
    expect(emitted, runtimeIdentity.sourceId);
    expect(chapters, greaterThan(100));
    final int transferred = result.report.count(
      RecordKind.chapterState,
      RecordDisposition.transferred,
    );
    return <String, Object?>{
      'direction': '${run.source.alias} -> ${run.target.alias}',
      'runtime': ecosystemOf(run.target),
      'emittedSourceId': emitted,
      'runtimeSourceId': runtimeIdentity.sourceId,
      'artifactSha256': runtimeIdentity.artifact.sha256,
      'artifactKind': runtimeIdentity.artifact.kind,
      'chapters': chapters,
      'statefulChapters': stateful,
      'transferred': transferred,
      'losses': result.report.count(RecordKind.chapterState) - transferred,
      'outputBytes': run.published.length,
      'outputSha256': sha256Hex(run.published),
      'publishedInAppStorage': run.outputPath.startsWith(root.path),
      'elapsedMs': run.elapsed.inMilliseconds,
      'maxMainLoopGapMs': run.maxTickGap.inMilliseconds,
    };
  }
}
