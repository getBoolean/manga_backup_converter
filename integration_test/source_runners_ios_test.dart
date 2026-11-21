// U15: complete local conversions on iOS through the app's composition root
// (R5, R9-R14, R17; AE7, AE8, AE11).
//
// Every job runs `ConversionService.convert` over `IosSourceRuntimes`: parse
// the input, run the destination runtime locally (Aidoku in wasm3, Paperback
// in a QuickJS worker isolate, Tachi in the embedded JVM), reconcile, build
// and validate the backup, and publish it inside the app sandbox. No desktop
// worker or helper endpoint exists in the app; every source request replays
// a committed capture (see support/ios_conversion_harness.dart).
//
//   tools/tachi-source-runner/ios/scripts/stage_runtime.sh iphonesimulator --test
//   flutter test integration_test/source_runners_ios_test.dart -d <udid> \
//     --dart-define=SRT_REPO_ROOT=$PWD
//
// Kill-and-relaunch runs in two launches of the same installation:
//   (built app, see the group; `flutter test` reinstalls between launches)
// Real backgrounding by hand (T3 device tools): --dart-define=SRT_MANUAL=true.
//
// Each case prints one `U15_RECEIPT {json}` line.

// ignore_for_file: avoid_print, do_not_use_environment

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter/src/features/conversion/data/app_file_stores.dart';
import 'package:source_runtime/source_runtime.dart';

import 'support/ios_conversion_harness.dart';

const String _phase = String.fromEnvironment('SRT_PHASE');
const bool _manual = bool.fromEnvironment('SRT_MANUAL');

final List<Map<String, Object?>> _receipts = <Map<String, Object?>>[];

void _receipt(String name, Map<String, Object?> data) {
  final r = <String, Object?>{
    'case': name,
    'evidenceClass': evidenceClass,
    ...data,
  };
  _receipts.add(r);
  print('U15_RECEIPT ${jsonEncode(r)}');
}

String _ecosystemOf(BackupFormat f) => switch (f) {
  Aidoku() => 'aidoku',
  Paperback() => 'paperback',
  _ => 'tachi',
};

/// Complete accounting and validation of [run], plus its destination checks.
Map<String, Object?> _checkRun(IosConversionHarness h, HarnessRun run) {
  final ConversionResult result = run.result;
  expect(run.published, result.draft.bytes, reason: 'published bytes');
  expect(
    h.formats
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
  expect(runtimeIdentity.ecosystem, _ecosystemOf(run.target));
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
  return <String, Object?>{
    'direction': '${run.source.alias} -> ${run.target.alias}',
    'runtime': _ecosystemOf(run.target),
    'emittedSourceId': emitted,
    'runtimeSourceId': runtimeIdentity.sourceId,
    'artifactSha256': runtimeIdentity.artifact.sha256,
    'artifactKind': runtimeIdentity.artifact.kind,
    'chapters': chapters,
    'statefulChapters': stateful,
    'transferred': result.report.count(
      RecordKind.chapterState,
      RecordDisposition.transferred,
    ),
    'losses':
        result.report.count(RecordKind.chapterState) -
        result.report.count(
          RecordKind.chapterState,
          RecordDisposition.transferred,
        ),
    'outputBytes': run.published.length,
    'publishedInSandbox': run.outputPath.startsWith(
      Directory.systemTemp.parent.path,
    ),
    'elapsedMs': run.elapsed.inMilliseconds,
    'maxMainLoopGapMs': run.maxTickGap.inMilliseconds,
  };
}

void _expectBaseline(IosConversionHarness h) {
  final Map<String, Object?> r = h.resources();
  expect(r['browserSessions'], anyOf(isNull, 0), reason: '$r');
  expect(r['aidokuPendingCalls'], 0, reason: '$r');
  expect(r['liveVmWorkers'], 0, reason: '$r');
  expect(r['armedDeadlines'], 0, reason: '$r');
  expect(r['vmCount'], 1, reason: '$r');
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final platformMessages = <String>{};

  tearDownAll(() {
    binding.reportData = <String, dynamic>{'receipts': _receipts};
  });

  group(
    'R5: six directions on the local iOS runtimes',
    skip: _phase.isNotEmpty,
    () {
      late IosConversionHarness h;
      late int baselineRefs;

      setUpAll(() async {
        h = await IosConversionHarness.create();
        baselineRefs = h.runtimes.jvm!.globalRefCount;
        binding.defaultBinaryMessenger.allMessagesHandler =
            (String channel, MessageHandler? handler, ByteData? message) {
              platformMessages.add(channel);
              return binding.defaultBinaryMessenger.delegate.send(
                channel,
                message,
              );
            };
        _receipt('start', <String, Object?>{
          'paperbackSizing': h.runtimes.paperbackPlan.sizing.toJson(),
          'jvmStart': h.runtimes.jvm!.startEvent.payload,
          'aidokuRegistered': h.runtimes.aidoku != null,
          'browserPort': h.runtimes.browserPort != null,
          'os': Platform.operatingSystemVersion,
          'dart': Platform.version,
        });
      });

      tearDownAll(() async {
        binding.defaultBinaryMessenger.allMessagesHandler = null;
        _receipt('six-directions-summary', <String, Object?>{
          'platformMessages': platformMessages.toList(),
          'resources': h.resources(),
          'baselineJniGlobalRefs': baselineRefs,
          'replayMisses': h.logs
              .where((l) => l.contains('capture miss'))
              .length,
        });
        await h.close();
      });

      for (final (BackupFormat source, BackupFormat target)
          in const <(BackupFormat, BackupFormat)>[
            (Paperback(), Aidoku()),
            (Mihon(), Aidoku()),
            (Aidoku(), Paperback()),
            (Mihon(), Paperback()),
            (Aidoku(), Mihon()),
            (Paperback(), Mihon()),
          ]) {
        test('${source.alias} -> ${target.alias}', () async {
          final HarnessRun run = await h.convert(source, target);
          final Map<String, Object?> data = _checkRun(h, run);
          _expectBaseline(h);
          expect(h.runtimes.jvm!.globalRefCount, baselineRefs);
          expect(run.maxTickGap, lessThan(const Duration(milliseconds: 500)));
          _receipt('r5', <String, Object?>{
            ...data,
            'resources': h.resources(),
          });
        }, timeout: const Timeout(Duration(minutes: 10)));
      }

      test('no platform channel carried a source operation', () {
        // Flutter's own lifecycle/system channels may appear; no source or
        // runtime channel exists (KTD23).
        expect(
          platformMessages.where(
            (String c) => c.contains('source') || c.contains('runtime'),
          ),
          isEmpty,
        );
      });
    },
  );

  group('AE8: lifecycle inside conversion jobs', skip: _phase.isNotEmpty, () {
    late IosConversionHarness h;

    setUpAll(
      () async => h = await IosConversionHarness.create(label: 'u15-ae8'),
    );
    tearDownAll(() => h.close());

    test('backgrounding mid-search cancels once, refuses work, then the job '
        'completes in the foreground and publishes one result', () async {
      final events = <String>[];
      final selection = ScriptedSelection(
        pick: 'weebcentral',
        acceptPartial: true,
        beforeSearch: (onSearch) async {
          h.aidokuSite.hold();
          final Future<PluginSearchResult?> first = searchOnce(
            onSearch,
            events,
          );
          await _until(() => h.aidokuSite.inFlight > 0);
          h.runtimes.setBackgrounded(true);
          final PluginSearchResult? stale = await first;
          events.add('first:${stale?.title}');
          // While backgrounded new work is refused, not queued.
          final PluginSearchResult? refused = await searchOnce(
            onSearch,
            events,
          );
          events.add('refused:${refused?.title}');
          h.runtimes.setBackgrounded(false);
          h.aidokuSite.release();
          return searchOnce(onSearch, events);
        },
      );
      final HarnessRun run = await h.convert(
        const Mihon(),
        const Aidoku(),
        selection: selection,
      );
      final Map<String, Object?> data = _checkRun(h, run);
      expect(events.first, startsWith('error:cancelled'));
      expect(events, contains('first:null'));
      expect(events, contains('refused:null'));
      expect(
        Directory(File(run.outputPath).parent.path).listSync(),
        hasLength(1),
      );
      _expectBaseline(h);
      _receipt('ae8-background', <String, Object?>{...data, 'events': events});
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('cancelling an in-flight search leaves the session usable', () async {
      final selection = ScriptedSelection(
        pick: 'weebcentral',
        beforeSearch: (onSearch) async {
          h.aidokuSite.hold();
          final StreamSubscription<PluginSearchEvent> sub = onSearch('Onimai')
              .listen((_) {});
          await _until(() => h.aidokuSite.inFlight > 0);
          final watch = Stopwatch()..start();
          await sub.cancel();
          h.aidokuSite.release();
          final PluginSearchResult? hit = await searchOnce(
            onSearch,
            <String>[],
          );
          _receipt('ae8-cancel-latency', <String, Object?>{
            'cancelToNextResultMs': watch.elapsedMilliseconds,
          });
          return hit;
        },
      );
      final HarnessRun run = await h.convert(
        const Paperback(),
        const Aidoku(),
        selection: selection,
      );
      _receipt('ae8-cancel', _checkRun(h, run));
      _expectBaseline(h);
    }, timeout: const Timeout(Duration(minutes: 5)));

    test('repeated jobs open and close every session and worker', () async {
      final int refs = h.runtimes.jvm!.globalRefCount;
      final rounds = <Map<String, Object?>>[];
      for (var i = 0; i < 2; i++) {
        for (final (BackupFormat s, BackupFormat t)
            in const <(BackupFormat, BackupFormat)>[
              (Aidoku(), Mihon()),
              (Mihon(), Paperback()),
              (Paperback(), Aidoku()),
            ]) {
          final HarnessRun run = await h.convert(s, t);
          _checkRun(h, run);
          _expectBaseline(h);
          rounds.add(<String, Object?>{
            'round': i,
            'direction': '${s.alias} -> ${t.alias}',
            'elapsedMs': run.elapsed.inMilliseconds,
            ...h.resources(),
          });
        }
      }
      expect(h.runtimes.jvm!.globalRefCount, refs);
      _receipt('ae8-repeated', <String, Object?>{'rounds': rounds});
    }, timeout: const Timeout(Duration(minutes: 15)));

    test('real backgrounding during a job (manual, device tools)', () async {
      // Background the app with the T3 device tools while U15_HOLDING is
      // printed (agent-device `home`), then reopen it (`open <bundle>`).
      h.runtimes.bindToAppLifecycle();
      final events = <String>[];
      final selection = ScriptedSelection(
        pick: 'weebcentral',
        acceptPartial: true,
        beforeSearch: (onSearch) async {
          h.aidokuSite.hold();
          final Future<PluginSearchResult?> first = searchOnce(
            onSearch,
            events,
          );
          await _until(() => h.aidokuSite.inFlight > 0);
          print('U15_HOLDING background the app now');
          await _until(
            () => h.runtimes.aidoku!.isBackgrounded,
            timeout: const Duration(minutes: 3),
          );
          events.add('backgrounded');
          await first;
          await _until(
            () => !h.runtimes.aidoku!.isBackgrounded,
            timeout: const Duration(minutes: 3),
          );
          events.add('foregrounded');
          h.aidokuSite.release();
          return searchOnce(onSearch, events);
        },
      );
      final HarnessRun run = await h.convert(
        const Mihon(),
        const Aidoku(),
        selection: selection,
      );
      print('U15_EVENTS $events');
      final Map<String, Object?> data = _checkRun(h, run);
      // The held search was answered once, as cancelled by the lifecycle
      // gate, between the transition to the background and the return.
      expect(events, hasLength(3), reason: '$events');
      expect(events[0], 'backgrounded');
      expect(events[1], startsWith('error:cancelled:'));
      expect(events[1], contains('app-backgrounded'));
      expect(events[2], 'foregrounded');
      _receipt('ae8-real-background', <String, Object?>{
        ...data,
        'events': events,
      });
    }, skip: _manual ? false : 'Manual: --dart-define=SRT_MANUAL=true');
  });

  group('AE8: engine deadline inside a job', skip: _phase.isNotEmpty, () {
    test('a Tachi call that never answers ends at the native deadline; '
        'nothing is published', () async {
      final IosConversionHarness h = await IosConversionHarness.create(
        label: 'u15-deadline',
        tachiNativeDeadline: const Duration(milliseconds: 1500),
        tachiReplayHang: const <String>['weebcentral.com'],
      );
      try {
        final selection = ScriptedSelection(pick: 'weebcentral');
        final watch = Stopwatch()..start();
        Object? error;
        try {
          await h.convert(const Aidoku(), const Mihon(), selection: selection);
        } on PartialConversionDeclined catch (e) {
          error = e;
        }
        expect(error, isA<PartialConversionDeclined>());
        expect(selection.searchFailures, isNotEmpty);
        final SourceFailure f = selection.searchFailures.first.failure;
        expect(f, isA<TimeoutFailure>(), reason: '$f');
        expect(Directory('${h.root.path}/out').listSync(), isEmpty);
        _expectBaseline(h);
        _receipt('ae8-engine-deadline', <String, Object?>{
          'failure': f.code,
          'message': f.message,
          'nativeDeadlineMs': 1500,
          'jobMs': watch.elapsedMilliseconds,
          'published': false,
          'resources': h.resources(),
        });
      } finally {
        await h.close();
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });

  group(
    'AE11: browser path inside a conversion job',
    skip: _phase.isNotEmpty,
    () {
      test('Paperback MangaFire 0.9 runs executeInWebView on WKWebView '
          '(offline replay; outcome recorded)', () async {
        final IosConversionHarness h = await IosConversionHarness.create(
          label: 'u15-ae11',
        );
        var maxSessions = 0;
        final poll = Timer.periodic(const Duration(milliseconds: 20), (_) {
          final int n = h.runtimes.browserPort!.sessions.length;
          if (n > maxSessions) maxSessions = n;
        });
        try {
          final selection = ScriptedSelection(pick: 'mangafire');
          Object? error;
          try {
            await h.convert(
              const Aidoku(),
              const Paperback(),
              selection: selection,
            );
          } on PartialConversionDeclined catch (e) {
            error = e;
          }
          poll.cancel();
          // The browser path ran inside the job. Offline, the page cannot load
          // MangaFire's scripts, so the source reports a named error; the live
          // challenge path stays open (M3).
          expect(maxSessions, greaterThan(0));
          expect(error, isA<PartialConversionDeclined>());
          expect(selection.searchFailures, isNotEmpty);
          expect(Directory('${h.root.path}/out').listSync(), isEmpty);
          // Late WebView callbacks: every session closed with the job.
          expect(h.runtimes.browserPort!.sessions, isEmpty);
          _expectBaseline(h);
          _receipt('ae11-mangafire-paperback', <String, Object?>{
            'browserSessionsOpened': maxSessions,
            'failures': <Object?>[
              for (final PluginSearchFailure f in selection.searchFailures)
                <String, Object?>{
                  'code': f.failure.code,
                  'message': f.failure.message,
                },
            ],
            'outcome': 'blocked-offline (named source error); live path open',
            'sessionsLeftOpen': h.runtimes.browserPort!.sessions.length,
          });
          // The port is usable for the next job.
          final HarnessRun next = await h.convert(
            const Mihon(),
            const Paperback(),
          );
          _checkRun(h, next);
        } finally {
          poll.cancel();
          await h.close();
        }
      }, timeout: const Timeout(Duration(minutes: 10)));
    },
  );

  group('Kill and relaunch resumes from the journal', () {
    // One installation, two launches (`flutter test` reinstalls the app and
    // wipes its container, so this case is driven from a built app):
    //   flutter build ios --simulator --debug \
    //     -t integration_test/source_runners_ios_test.dart \
    //     --dart-define=SRT_REPO_ROOT=$PWD --dart-define=SRT_PHASE=relaunch
    //   agent-device install / open  -> first launch dies at publication
    //   agent-device open            -> second launch resumes
    // Each launch writes its receipt into the container's u15-resume/.
    final dir = Directory('${appSupport.path}/u15-resume');
    final journalPath = '${dir.path}/journal.json';
    final outPath = '${dir.path}/out/resumed.aib';
    final killed = File('${dir.path}/killed.json');

    test(
      'the first launch dies at publication with the decisions journaled; '
      'the relaunch reuses them and publishes exactly one output',
      () async {
        if (!killed.existsSync()) {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
          dir.createSync(recursive: true);
          final IosConversionHarness h = await IosConversionHarness.create(
            label: 'u15-kill',
          );
          final Uint8List input = await h.input(const Mihon());
          File('${dir.path}/input.tachibk').writeAsBytesSync(input);
          await h.convert(
            const Mihon(),
            const Aidoku(),
            inputBytes: input,
            journal: AppFileJournalStore(journalPath),
            output: _KillingOutput(journalPath, killed),
          );
          fail('the app should have been killed at publication');
        }
        final result = File('${dir.path}/resume-receipt.json');
        try {
          expect(File(journalPath).existsSync(), isTrue);
          expect(Directory('${dir.path}/out').existsSync(), isFalse);
          final IosConversionHarness h = await IosConversionHarness.create(
            label: 'u15-resume',
          );
          try {
            var resumed = 0;
            final selection = ScriptedSelection(
              pick: 'weebcentral',
              acceptPartial: true,
            );
            final HarnessRun run = await h.convert(
              const Mihon(),
              const Aidoku(),
              selection: selection,
              inputBytes: File('${dir.path}/input.tachibk').readAsBytesSync(),
              journal: AppFileJournalStore(journalPath),
              output: AppFileConversionOutput(outPath),
              onResume: (int d) => resumed = d,
            );
            expect(resumed, greaterThan(0));
            expect(
              selection.mangaAsked,
              0,
              reason: 'decisions came from the journal',
            );
            expect(
              File(journalPath).existsSync(),
              isFalse,
              reason: 'journal cleared',
            );
            final List<FileSystemEntity> outputs = Directory(
              '${dir.path}/out',
            ).listSync();
            expect(outputs, hasLength(1));
            final Uint8List published = File(outPath).readAsBytesSync();
            expect(published, run.result.draft.bytes);
            expect(
              AidokuBackup.fromData(published).manga!.single.sourceId,
              'en.weebcentral',
            );
            final data = <String, Object?>{
              'pass': true,
              'killedAt': jsonDecode(killed.readAsStringSync()),
              'journaledDecisionsReused': resumed,
              'mangaAskedAgain': selection.mangaAsked,
              'searchesAfterRelaunch': selection.confirmCalls,
              'outputs': outputs.length,
              'outputBytes': published.length,
              'aidokuRequestsAfterRelaunch': h.aidokuSite.requests,
            };
            result.writeAsStringSync(jsonEncode(data));
            _receipt('kill-relaunch', data);
          } finally {
            await h.close();
          }
        } on Object catch (e) {
          if (!result.existsSync()) {
            result.writeAsStringSync(
              jsonEncode(<String, Object?>{'pass': false, 'error': '$e'}),
            );
          }
          rethrow;
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
      skip: _phase == 'relaunch'
          ? false
          : 'Built-app case: --dart-define=SRT_PHASE=relaunch',
    );
  });
}

/// Searches once and records the outcome in [events].
Future<PluginSearchResult?> searchOnce(
  Stream<PluginSearchEvent> Function(String query) onSearch,
  List<String> events,
) async {
  final hits = <PluginSearchResult>[];
  await for (final PluginSearchEvent e in onSearch('Onimai')) {
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

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > timeout) throw TimeoutException('condition', timeout);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Records that publication was reached with the journal on disk, then
/// kills this process with SIGKILL (`raise`, through FFI: `Process.killPid`
/// on the own pid does nothing on iOS) before writing anything.
final class _KillingOutput implements ConversionOutput {
  _KillingOutput(this.journalPath, this.marker);

  final String journalPath;
  final File marker;

  @override
  Future<void> publish(Uint8List bytes) async {
    final journal = jsonDecode(
      File(journalPath).readAsStringSync(),
    ) as Map<String, Object?>;
    marker.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'journalBytes': File(journalPath).lengthSync(),
        'journalKeys': journal.keys.toList(),
        'outputBytesNotWritten': bytes.length,
      }),
      flush: true,
    );
    print('U15_KILL journal on disk; killing the app');
    final int Function(int) raise = DynamicLibrary.process()
        .lookupFunction<Int32 Function(Int32), int Function(int)>('raise');
    raise(9);
    await Completer<void>().future;
  }
}
