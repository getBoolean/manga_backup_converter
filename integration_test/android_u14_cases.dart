// U14: complete local conversions on Android through the app's composition
// root (R5, R9-R12, R15-R17; AE9-AE11), registered by
// source_runners_android_test.dart.
//
// Every job runs `ConversionService.convert` over `AndroidSourceRuntimes`:
// parse the input, run the destination runtime locally (Aidoku in wasm3 in
// the app process, Paperback in a QuickJS worker isolate, Tachi in the
// `:source_runtime` service), reconcile, build and validate the backup, and
// publish it in app-private storage. Every source request replays a
// committed capture (support/android_conversion_harness.dart).
//
//   flutter test integration_test/source_runners_android_test.dart \
//     -d <device> --name U14
//
// Built-app cases (a real process kill, Activity recreation) run from an
// installed debug APK in two launches of the same installation; see
// [registerU14PhaseCases]. Real backgrounding by hand (T3 device tools):
// --dart-define=SRT_MANUAL=true.
//
// Each case prints one `U14_RECEIPT {json}` line.

// ignore_for_file: avoid_print, do_not_use_environment

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter/src/features/conversion/data/app_file_stores.dart';
import 'package:source_runtime/source_runtime.dart';

import 'support/android_conversion_harness.dart';

/// Selects a built-app phase (`relaunch`, `recreate`); empty in `flutter
/// test` runs.
const String u14Phase = String.fromEnvironment('SRT_PHASE');
const bool _manual = bool.fromEnvironment('SRT_MANUAL');

Map<String, Object?> _device = const <String, Object?>{};

void _receipt(String name, Map<String, Object?> data) {
  print(
    'U14_RECEIPT ${jsonEncode(<String, Object?>{'case': name, ..._device, ...data})}',
  );
}

void _expectBaseline(AndroidConversionHarness h) {
  final Map<String, Object?> r = h.resources();
  expect(r['browserSessions'], anyOf(isNull, 0), reason: '$r');
  expect(r['tachiScopeOpen'], isFalse, reason: '$r');
  expect(r['paperbackScopeOpen'], isFalse, reason: '$r');
}

/// Waits until the service process of a closed worker has exited.
Future<List<int>> _serviceGone() async {
  try {
    await until(
      () => servicePids().isEmpty,
      timeout: const Duration(seconds: 15),
    );
  } on TimeoutException {
    // Reported by the caller.
  }
  return servicePids();
}

/// The Tachi WeebCentral hit among [hits] (a fixture package may also
/// answer "Onimai").
PluginSearchResult? _weebCentralHit(List<PluginSearchResult> hits) => hits
    .where(
      (PluginSearchResult r) => r.ref.source.sourceId == tachiWeebCentralId,
    )
    .firstOrNull;

Future<List<PluginSearchResult>> _collect(
  Stream<PluginSearchEvent> events,
  List<String> log,
) async {
  final hits = <PluginSearchResult>[];
  await for (final PluginSearchEvent e in events) {
    switch (e) {
      case PluginSearchResults():
        hits.addAll(e.results);
      case PluginSearchError(:final PluginSearchFailure failure):
        log.add('error:${failure.failure.code}:${failure.failure.message}');
      case PluginSearchStarted():
        break;
    }
  }
  return hits;
}

/// Registers the U14 cases of a `flutter test` run.
void registerU14Cases() {
  setUpAll(() async => _device = await deviceFacts());

  group('U14 R5: six directions on the local Android runtimes', () {
    late AndroidConversionHarness h;

    setUpAll(() async {
      _device = await deviceFacts();
      expect(servicePids(), isEmpty, reason: 'nothing runs before a job');
      h = await AndroidConversionHarness.create();
      expect(
        servicePids(),
        isEmpty,
        reason: 'starting the runtimes binds no service',
      );
      _receipt('start', <String, Object?>{
        'paperbackSizing': h.runtimes.paperbackPlan.sizing.toJson(),
        'aidokuRegistered': h.runtimes.aidoku != null,
        'browserPort': h.runtimes.browserPort?.info,
        'browserUnavailable': h.runtimes.browserUnavailable?.message,
        'webViewOfflineUnavailable': h.webViewOfflineUnavailableReason,
        'tachiArguments': h.runtimes.tachi.arguments,
        'tachiHandshakeDeadlineMs':
            h.runtimes.tachi.handshakeDeadline.inMilliseconds,
        'dart': Platform.version,
      });
    });

    tearDownAll(() async {
      _receipt('six-directions-summary', <String, Object?>{
        'resources': h.resources(),
        'replayMisses': h.replayMisses,
      });
      expect(h.replayMisses, 0);
      await h.close();
    });

    for (final (BackupFormat source, BackupFormat target) in r5Directions) {
      test('U14 ${source.alias} -> ${target.alias}', () async {
        final HarnessRun run = await h.convert(source, target);
        final Map<String, Object?> data = h.checkRun(run);
        _expectBaseline(h);
        expect(
          await _serviceGone(),
          isEmpty,
          reason: 'the service ends with the conversion',
        );
        // Debug (JIT) builds on an emulator: the first job of a run compiles
        // the pipeline; the gap is recorded in every receipt.
        expect(run.maxTickGap, lessThan(const Duration(seconds: 1)));
        expect(
          h.outDir.listSync().whereType<File>().where(
            (File f) => f.path.endsWith('.tmp'),
          ),
          isEmpty,
        );
        // Kept for the restore spot check (pulled with `run-as`).
        final kept = Directory('${appDataDirectory.path}/u14-outputs')
          ..createSync(recursive: true);
        File(run.outputPath).copySync(
          '${kept.path}/${File(run.outputPath).uri.pathSegments.last}',
        );
        _receipt('r5', <String, Object?>{...data, 'resources': h.resources()});
      }, timeout: const Timeout(Duration(minutes: 10)));
    }
  });

  group('U14 AE10: Tachi service death and a hung call inside a job', () {
    test(
      'U14 AE10: a killed service and a deadline-killed CPU loop are fenced; '
      'packages rehydrate; the job publishes one complete backup',
      () async {
        final AndroidConversionHarness h =
            await AndroidConversionHarness.create(
              label: 'u14-ae10',
              fixtureRepository: true,
              tachiArguments: const <String>[
                '--limit',
                'operationDeadlineMs=4000',
                '--limit',
                'cancelGraceMs=500',
              ],
            );
        final events = <String>[];
        var restarts = <WorkerRestartedEvent>[];
        int? firstPid;
        try {
          final selection = ScriptedSelection(
            pick: 'weebcentral',
            alsoPick: const <String>['fixture.android.busy'],
            beforeSearch: (onSearch) async {
              // A search fans out to every picked package; WeebCentral's
              // replay has no capture for "busy" and fails closed (a named
              // capture miss), which is expected here.
              //
              // 1. Service death while a call is in flight: the busy source
              //    loops on "busy"; the app kills the service process.
              final Future<List<PluginSearchResult>> killed = _collect(
                onSearch('busy'),
                events,
              );
              await until(() => h.tachiSupervisor?.pid != null);
              await Future<void>.delayed(const Duration(milliseconds: 800));
              final int victim = firstPid = h.tachiSupervisor!.pid!;
              expect(servicePids(), contains(victim));
              events.add('kill');
              Process.killPid(victim, ProcessSignal.sigkill);
              await killed;
              events.add('after-kill');
              // 2. A hung call: the loop runs into the 4 s operation
              //    deadline, cooperative cancel cannot settle it, and the
              //    supervisor kills the PID and restarts.
              await _collect(onSearch('busy'), events);
              events.add('after-deadline');
              // 3. The job goes on in the rehydrated worker.
              final List<PluginSearchResult> hits = await _collect(
                onSearch('Onimai'),
                events,
              );
              restarts = h.tachiSupervisor!.events
                  .whereType<WorkerRestartedEvent>()
                  .toList();
              return _weebCentralHit(hits);
            },
          );
          final HarnessRun run = await h.convert(
            const Aidoku(),
            const Mihon(),
            selection: selection,
          );
          final Map<String, Object?> data = h.checkRun(run);
          expect(
            h.tachiSupervisor,
            isNull,
            reason: 'the job closed its worker',
          );
          expect(h.outDir.listSync(), hasLength(1));
          // One restart for the death, at least one for the deadline.
          expect(restarts.length, greaterThanOrEqualTo(2), reason: '$restarts');
          expect(
            restarts.expand((WorkerRestartedEvent r) => r.reloadFailures),
            isEmpty,
            reason: 'every hosted package rehydrated',
          );
          expect(
            events.where((String e) => e.startsWith('error:timeout')),
            isNotEmpty,
            reason: '$events',
          );
          _expectBaseline(h);
          _receipt('ae10-death-and-deadline', <String, Object?>{
            ...data,
            'firstServicePidKilled': firstPid != null,
            'restarts': <Object?>[
              for (final WorkerRestartedEvent r in restarts)
                <String, Object?>{
                  'reason': r.reason,
                  'requeued': r.requeued,
                  'failed': r.failed,
                  'reloadFailures': r.reloadFailures,
                },
            ],
            'searchEvents': events,
            'pickedExtensions': selection.pickedExtensions,
            'serviceAfterJob': await _serviceGone(),
          });
        } finally {
          print('U14_AE10_EVENTS $events');
          await h.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 8)),
    );
  });

  group('U14 AE11: browser paths inside conversion jobs', () {
    test('U14 AE11: Paperback MangaFire 0.9 runs executeInWebView on the '
        'app-process WebView (offline replay; outcome recorded)', () async {
      final AndroidConversionHarness h = await AndroidConversionHarness.create(
        label: 'u14-ae11-pb',
      );
      if (h.webViewOfflineUnavailableReason case final String reason) {
        await h.close();
        _receipt('ae11-skipped', <String, Object?>{'reason': reason});
        markTestSkipped('WebView network cannot be blocked here: $reason');
        return;
      }
      var maxSessions = 0;
      final poll = Timer.periodic(const Duration(milliseconds: 20), (_) {
        final int n = h.runtimes.browserPort?.sessions.length ?? 0;
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
        expect(h.runtimes.browserPort, isNotNull);
        expect(maxSessions, greaterThan(0));
        expect(error, isA<PartialConversionDeclined>());
        expect(selection.searchFailures, isNotEmpty);
        expect(h.outDir.listSync(), isEmpty);
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
          'published': false,
        });
        // The port serves the next job.
        h.checkRun(await h.convert(const Mihon(), const Paperback()));
      } finally {
        poll.cancel();
        await h.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('U14 AE11: Tachi MangaFire runWebViewBlocking runs in the service '
        'inside a job (replayed challenge; outcome recorded)', () async {
      final AndroidConversionHarness h = await AndroidConversionHarness.create(
        label: 'u14-ae11-tachi',
        tachiArguments: const <String>['--challenge-once', '/api/titles'],
      );
      if (h.webViewOfflineUnavailableReason case final String reason) {
        await h.close();
        _receipt('ae11-skipped', <String, Object?>{'reason': reason});
        markTestSkipped('WebView network cannot be blocked here: $reason');
        return;
      }
      try {
        final selection = ScriptedSelection(pick: 'mangafire');
        Object? error;
        try {
          await h.convert(const Aidoku(), const Mihon(), selection: selection);
        } on PartialConversionDeclined catch (e) {
          error = e;
        }
        expect(error, isA<PartialConversionDeclined>());
        expect(selection.searchFailures, isNotEmpty);
        expect(h.outDir.listSync(), isEmpty);
        _expectBaseline(h);
        _receipt('ae11-mangafire-tachi', <String, Object?>{
          'pickedExtensions': selection.pickedExtensions,
          'failures': <Object?>[
            for (final PluginSearchFailure f in selection.searchFailures)
              <String, Object?>{
                'code': f.failure.code,
                'message': f.failure.message,
              },
          ],
          'outcome': 'blocked-offline (named source error); live path open',
          'published': false,
        });
      } finally {
        await h.close();
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('U14 real backgrounding during a job (manual, device tools)', () {
    test(
      'U14 background: browser work is refused while backgrounded; the '
      'job completes in the foreground and publishes one result',
      () async {
        // Background the app with the device tools while U14_HOLDING is
        // printed (agent-device `home`), then reopen it (`open <package>`).
        final AndroidConversionHarness h =
            await AndroidConversionHarness.create(
              label: 'u14-bg',
            );
        final events = <String>[];
        try {
          final selection = ScriptedSelection(
            pick: 'weebcentral',
            acceptPartial: true,
            beforeSearch: (onSearch) async {
              h.aidokuSite.hold();
              final Future<PluginSearchResult?> first = searchOnce(
                onSearch,
                events,
              );
              await until(() => h.aidokuSite.inFlight > 0);
              print('U14_HOLDING background the app now');
              await until(
                () => h.runtimes.browserPort!.isBackgrounded,
                timeout: const Duration(minutes: 3),
              );
              events.add('backgrounded');
              final BrowserOutcome<BrowserSession> refused = await h
                  .runtimes
                  .browserPort!
                  .openSession(
                    const BrowserSessionRequest(
                      source: SourceIdentity(
                        ecosystem: 'paperback',
                        packageId: 'probe',
                        sourceId: 'probe',
                        artifact: ArtifactBinding(
                          sha256: 'probe',
                          kind: 'test',
                          version: '1',
                        ),
                      ),
                      generation: 1 << 30,
                    ),
                  );
              events.add('openSession:${refused.runtimeType}');
              events.add('aidokuInFlight:${h.aidokuSite.inFlight}');
              print('U14_BACKGROUNDED reopen the app now');
              await until(
                () => !h.runtimes.browserPort!.isBackgrounded,
                timeout: const Duration(minutes: 3),
              );
              events.add('foregrounded');
              h.aidokuSite.release();
              final PluginSearchResult? held = await first;
              events.add('held:${held?.title}');
              return held ?? searchOnce(onSearch, events);
            },
          );
          final HarnessRun run = await h.convert(
            const Mihon(),
            const Aidoku(),
            selection: selection,
          );
          print('U14_EVENTS $events');
          final Map<String, Object?> data = h.checkRun(run);
          expect(events.first, 'backgrounded', reason: '$events');
          expect(
            events,
            contains('openSession:BrowserInteractionRequired<BrowserSession>'),
          );
          expect(events, contains('foregrounded'));
          expect(h.outDir.listSync(), hasLength(1));
          _receipt('real-background', <String, Object?>{
            ...data,
            'events': events,
            'drivenBy': 'T3 device tools (agent-device home / open)',
          });
        } finally {
          await h.close();
        }
      },
      timeout: const Timeout(Duration(minutes: 10)),
      skip: _manual ? false : 'Manual: --dart-define=SRT_MANUAL=true',
    );
  });
}

/// The built-app cases. One installation, two launches:
///
///   flutter build apk --debug \
///     -t integration_test/source_runners_android_test.dart \
///     --dart-define=SRT_PHASE=relaunch        (or recreate)
///   adb install -r build/app/outputs/flutter-apk/app-debug.apk
///   agent-device open <package>   -> launch 1 holds at publication and
///                                     prints U14_INTERRUPT_READY
///   relaunch: adb shell run-as <package> kill -9 <app pid>
///   recreate: "Don't keep activities" on, agent-device home, then open
///   agent-device open <package>   -> launch 2 (if the first died) resumes
///
/// Each launch writes its receipt into `<app data>/u14-<phase>/`.
void registerU14PhaseCases() {
  final dir = Directory('${appDataDirectory.path}/u14-$u14Phase');
  final journalPath = '${dir.path}/journal.json';
  final outPath = '${dir.path}/out/resumed.tachibk';
  final interrupted = File('${dir.path}/interrupted.json');
  final receipt = File('${dir.path}/receipt.json');

  test('U14 $u14Phase: the job is interrupted at publication with its '
      'decisions journaled; exactly one output is published', () async {
    _device = await deviceFacts();
    if (!interrupted.existsSync()) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      final AndroidConversionHarness h = await AndroidConversionHarness.create(
        root: Directory('${dir.path}/harness'),
      );
      final Uint8List input = await h.input(const Aidoku());
      File('${dir.path}/input.aib').writeAsBytesSync(input);
      final selection = ScriptedSelection(pick: 'weebcentral');
      final HarnessRun run = await h.convert(
        const Aidoku(),
        const Mihon(),
        selection: selection,
        inputBytes: input,
        journal: AppFileJournalStore(journalPath),
        output: _InterruptedOutput(
          phase: u14Phase,
          journalPath: journalPath,
          marker: interrupted,
          target: outPath,
          servicePid: servicePids,
        ),
        outputPath: outPath,
      );
      // Reached only when the Dart isolate survived the interruption (the
      // recreate phase with an engine that outlives its Activity).
      final data = <String, Object?>{
        'ok': true,
        'path': 'same-isolate',
        ...h.checkRun(run),
        'interruptedAt': jsonDecode(interrupted.readAsStringSync()),
        'outputs': Directory('${dir.path}/out').listSync().length,
        'journalCleared': !File(journalPath).existsSync(),
      };
      receipt.writeAsStringSync(jsonEncode(data));
      _receipt('$u14Phase-interrupt', data);
      await h.close(deleteRoot: false);
      return;
    }
    try {
      final interruptedAt =
          jsonDecode(interrupted.readAsStringSync()) as Map<String, Object?>;
      expect(File(journalPath).existsSync(), isTrue);
      expect(File(outPath).existsSync(), isFalse);
      final List<int> oldService =
          (interruptedAt['servicePids']! as List<Object?>).cast<int>();
      final List<int> liveService = servicePids();
      final AndroidConversionHarness h = await AndroidConversionHarness.create(
        root: Directory('${dir.path}/harness'),
      );
      try {
        var resumed = 0;
        final selection = ScriptedSelection(pick: 'weebcentral');
        final HarnessRun run = await h.convert(
          const Aidoku(),
          const Mihon(),
          selection: selection,
          inputBytes: File('${dir.path}/input.aib').readAsBytesSync(),
          journal: AppFileJournalStore(journalPath),
          outputPath: outPath,
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
        final List<FileSystemEntity> outputs = Directory('${dir.path}/out')
            .listSync();
        expect(outputs, hasLength(1), reason: '$outputs');
        final Map<String, Object?> checked = h.checkRun(run);
        final data = <String, Object?>{
          'ok': true,
          'path': 'relaunch-resumed',
          ...checked,
          'interruptedAt': interruptedAt,
          'servicePidsAtInterrupt': oldService,
          'servicePidsAtRelaunch': liveService,
          'journaledDecisionsReused': resumed,
          'mangaAskedAgain': selection.mangaAsked,
          'outputs': outputs.length,
          'appPid': pid,
        };
        receipt.writeAsStringSync(jsonEncode(data));
        _receipt('$u14Phase-resume', data);
      } finally {
        await h.close(deleteRoot: false);
      }
    } on Object catch (e) {
      if (!receipt.existsSync()) {
        receipt.writeAsStringSync(
          jsonEncode(<String, Object?>{'ok': false, 'error': '$e'}),
        );
      }
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// Records that publication was reached with the journal on disk, then
/// waits for the interruption: a process kill from the host (`relaunch`)
/// never returns; for `recreate`, the output publishes only if this Dart
/// isolate sees the app resume again after being paused.
final class _InterruptedOutput implements ConversionOutput {
  _InterruptedOutput({
    required this.phase,
    required this.journalPath,
    required this.marker,
    required this.target,
    required this.servicePid,
  });

  final String phase;
  final String journalPath;
  final File marker;
  final String target;
  final List<int> Function() servicePid;

  @override
  Future<void> publish(Uint8List bytes) async {
    final journal = jsonDecode(
      File(journalPath).readAsStringSync(),
    ) as Map<String, Object?>;
    marker.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'phase': phase,
        'appPid': pid,
        'servicePids': servicePid(),
        'journalBytes': File(journalPath).lengthSync(),
        'journalKeys': journal.keys.toList(),
        'outputBytesNotWritten': bytes.length,
      }),
      flush: true,
    );
    print('U14_INTERRUPT_READY pid=$pid phase=$phase');
    if (phase != 'recreate') {
      await Completer<void>().future;
    }
    final paused = Completer<void>();
    final resumed = Completer<void>();
    final listener = AppLifecycleListener(
      onPause: () => paused.isCompleted ? null : paused.complete(),
      onResume: () {
        if (paused.isCompleted && !resumed.isCompleted) resumed.complete();
      },
    );
    try {
      await resumed.future;
    } finally {
      listener.dispose();
    }
    print('U14_SURVIVED the isolate outlived the Activity; publishing');
    await writeAppFileAtomically(target, bytes);
  }
}
