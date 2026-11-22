// Android background gate (KTD18): Aidoku (U13), Paperback (U12 isolate)
// and Tachi (U11 service) calls inside real conversion jobs, registered by
// source_runners_android_test.dart.
//
// One lifecycle signal (`AndroidAppForeground`) drives the shared
// `BackgroundGate` and the browser port. Each case holds a call in flight,
// backgrounds the app, and asserts:
// - the held call answers `cancelled: app-backgrounded` at once;
// - a new call is refused the same way while backgrounded;
// - a job left without a match publishes nothing (partial declined);
// - after the app returns, a new call succeeds and the job publishes exactly
//   one validated backup.
//
// The programmatic cases background through the signal's test seam
// (`setBackgroundedOverride`). The real cases need the device driven from
// outside (T3 device tools: agent-device `home` at `BG_HOLDING`, `open
// <package>` at `BG_BACKGROUNDED`); run them with
//   flutter test integration_test/source_runners_android_test.dart \
//     -d <device> --name "BG real" --dart-define=SRT_MANUAL=true
//
// Each case prints one `BG_RECEIPT {json}` line.

// ignore_for_file: avoid_print, do_not_use_environment

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_runtime.dart';

import 'support/android_conversion_harness.dart';

const bool _manual = bool.fromEnvironment('SRT_MANUAL');
const String _backgrounded = 'error:cancelled:$appBackgroundedReason';

/// How one ecosystem's call is held in flight.
final class _Hold {
  const _Hold({
    required this.ecosystem,
    required this.source,
    required this.target,
    required this.query,
    required this.hold,
    required this.release,
    required this.inFlight,
    this.alsoPick = const <String>[],
  });

  final String ecosystem;
  final BackupFormat source;
  final BackupFormat target;

  /// The query whose call is held.
  final String query;
  final void Function(AndroidConversionHarness h) hold;
  final void Function(AndroidConversionHarness h) release;
  final Future<void> Function(AndroidConversionHarness h) inFlight;
  final List<String> alsoPick;
}

final List<_Hold> _holds = <_Hold>[
  _Hold(
    ecosystem: 'aidoku',
    source: const Mihon(),
    target: const Aidoku(),
    query: 'Onimai',
    hold: (h) => h.aidokuSite.hold(),
    release: (h) => h.aidokuSite.release(),
    inFlight: (h) => until(() => h.aidokuSite.inFlight > 0),
  ),
  _Hold(
    ecosystem: 'paperback',
    source: const Mihon(),
    target: const Paperback(),
    query: 'Onimai',
    hold: (h) => h.paperbackSite.hold(),
    release: (h) => h.paperbackSite.release(),
    inFlight: (h) => until(
      () => h.paperbackSite.inFlight,
      timeout: const Duration(minutes: 1),
    ),
  ),
  // The U11 `busy` fixture loops on the query "busy"; cooperative cancel
  // cannot stop it, so after the gate answers, the operation deadline kills
  // and restarts the worker (as in AE10) and the job continues.
  _Hold(
    ecosystem: 'tachi',
    source: const Aidoku(),
    target: const Mihon(),
    query: 'busy',
    alsoPick: const <String>['fixture.android.busy'],
    hold: (_) {},
    release: (_) {},
    inFlight: (h) async {
      await until(
        () => h.tachiSupervisor?.pid != null,
        timeout: const Duration(minutes: 1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 800));
    },
  ),
];

void _receipt(String name, Map<String, Object?> data) => print(
  'BG_RECEIPT ${jsonEncode(<String, Object?>{'case': name, ...data})}',
);

Future<List<PluginSearchResult>> _search(
  Stream<PluginSearchEvent> Function(String query) onSearch,
  String query,
  List<String> events,
) async {
  final hits = <PluginSearchResult>[];
  await for (final PluginSearchEvent e in onSearch(query)) {
    switch (e) {
      case PluginSearchResults():
        hits.addAll(e.results);
      case PluginSearchError(:final PluginSearchFailure failure):
        events.add('error:${failure.failure.code}:${failure.failure.message}');
      case PluginSearchStarted():
        break;
    }
  }
  return hits;
}

PluginSearchResult? _onimai(List<PluginSearchResult> hits) => hits
    .where((PluginSearchResult r) => r.title.toLowerCase().contains('onimai'))
    .firstOrNull;

/// [deadline] bounds the Tachi `busy` loop: short for the programmatic
/// cases, long enough for the real cases to background the app by hand
/// before the deadline ends the held call. After the gate answers, the next
/// call of that package waits for this deadline to restart the worker.
Future<AndroidConversionHarness> _harness(
  _Hold hold,
  String label, {
  Duration deadline = const Duration(seconds: 15),
}) => AndroidConversionHarness.create(
  label: label,
  fixtureRepository: hold.ecosystem == 'tachi',
  tachiArguments: hold.ecosystem == 'tachi'
      ? <String>[
          '--limit',
          'operationDeadlineMs=${deadline.inMilliseconds}',
          '--limit',
          'cancelGraceMs=500',
        ]
      : const <String>[],
);

/// Holds a call, backgrounds the app with [background], checks the named
/// outcome and the refusal, then returns to the foreground with
/// [foreground] when [resume] and searches again.
Future<PluginSearchResult?> _backgroundDuringSearch(
  AndroidConversionHarness h,
  _Hold hold,
  Stream<PluginSearchEvent> Function(String query) onSearch,
  List<String> events, {
  required Future<void> Function() background,
  required Future<void> Function() foreground,
  required bool resume,
}) async {
  hold.hold(h);
  final heldEvents = <String>[];
  final Future<List<PluginSearchResult>> held = _search(
    onSearch,
    hold.query,
    heldEvents,
  );
  await hold.inFlight(h);
  events.add('in-flight');
  await background();
  final watch = Stopwatch()..start();
  events.add('backgrounded');
  final List<PluginSearchResult> heldHits = await held;
  events
    ..add('held-answered-ms:${watch.elapsedMilliseconds}')
    ..addAll(heldEvents.map((String e) => 'held:$e'))
    ..add('held-hits:${heldHits.length}');
  final refusedEvents = <String>[];
  final List<PluginSearchResult> refused = await _search(
    onSearch,
    'Onimai',
    refusedEvents,
  );
  events
    ..addAll(refusedEvents.map((String e) => 'refused:$e'))
    ..add('refused-hits:${refused.length}')
    ..add('gated-pending:${h.runtimes.backgroundGate.pendingCalls}');
  if (!resume) {
    hold.release(h);
    return null;
  }
  await foreground();
  events.add('foregrounded');
  hold.release(h);
  final retryEvents = <String>[];
  final PluginSearchResult? hit = _onimai(
    await _search(onSearch, 'Onimai', retryEvents),
  );
  events
    ..addAll(retryEvents.map((String e) => 'retry:$e'))
    ..add('retry-hit:${hit?.ref.source.sourceId}');
  return hit;
}

void _expectNamedOutcome(List<String> events) {
  expect(events, contains('held:$_backgrounded'), reason: '$events');
  final int ms = int.parse(
    events
        .firstWhere((String e) => e.startsWith('held-answered-ms:'))
        .split(':')
        .last,
  );
  expect(
    ms,
    lessThan(2000),
    reason: 'the held call answers at the transition: $events',
  );
  expect(events, contains('refused:$_backgrounded'), reason: '$events');
  expect(events, contains('refused-hits:0'), reason: '$events');
  expect(events, contains('gated-pending:0'), reason: '$events');
}

/// Registers the background gate cases of a `flutter test` run.
void registerBackgroundCases() {
  group('BG programmatic: the background gate inside conversion jobs', () {
    for (final _Hold hold in _holds) {
      test(
        'BG ${hold.ecosystem}: a backgrounded job without a match publishes nothing',
        () async {
          final AndroidConversionHarness h = await _harness(
            hold,
            'bg-${hold.ecosystem}-declined',
          );
          final events = <String>[];
          try {
            final selection = ScriptedSelection(
              pick: 'weebcentral',
              alsoPick: hold.alsoPick,
              beforeSearch: (onSearch) => _backgroundDuringSearch(
                h,
                hold,
                onSearch,
                events,
                background: () async =>
                    h.runtimes.appForeground!.setBackgroundedOverride(true),
                foreground: () async {},
                resume: false,
              ),
            );
            Object? error;
            try {
              await h.convert(hold.source, hold.target, selection: selection);
            } on PartialConversionDeclined catch (e) {
              error = e;
            }
            print('BG_EVENTS $events');
            _expectNamedOutcome(events);
            expect(error, isA<PartialConversionDeclined>(), reason: '$events');
            expect(
              h.outDir.listSync(),
              isEmpty,
              reason: 'nothing partial is published',
            );
            h.runtimes.appForeground!.setBackgroundedOverride(null);
            expect(h.runtimes.isBackgrounded, isFalse);
            // The same runtimes serve the next job in the foreground.
            h.checkRun(await h.convert(hold.source, hold.target));
            expect(h.outDir.listSync(), hasLength(1));
            expect(h.resources()['tachiScopeOpen'], isFalse);
            expect(h.resources()['paperbackScopeOpen'], isFalse);
            _receipt('programmatic-declined', <String, Object?>{
              'ecosystem': hold.ecosystem,
              'events': events,
              'resources': h.resources(),
            });
          } finally {
            h.runtimes.appForeground?.setBackgroundedOverride(null);
            await h.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 10)),
      );

      test(
        'BG ${hold.ecosystem}: work resumes in the foreground; one output',
        () async {
          final AndroidConversionHarness h = await _harness(
            hold,
            'bg-${hold.ecosystem}-resume',
          );
          final events = <String>[];
          try {
            final selection = ScriptedSelection(
              pick: 'weebcentral',
              alsoPick: hold.alsoPick,
              acceptPartial: true,
              beforeSearch: (onSearch) => _backgroundDuringSearch(
                h,
                hold,
                onSearch,
                events,
                background: () async =>
                    h.runtimes.appForeground!.setBackgroundedOverride(true),
                foreground: () async =>
                    h.runtimes.appForeground!.setBackgroundedOverride(null),
                resume: true,
              ),
            );
            final HarnessRun run = await h.convert(
              hold.source,
              hold.target,
              selection: selection,
            );
            print('BG_EVENTS $events');
            _expectNamedOutcome(events);
            final Map<String, Object?> data = h.checkRun(run);
            expect(h.outDir.listSync(), hasLength(1));
            _receipt('programmatic-resume', <String, Object?>{
              ...data,
              'ecosystem': hold.ecosystem,
              'events': events,
              'resources': h.resources(),
            });
          } finally {
            h.runtimes.appForeground?.setBackgroundedOverride(null);
            await h.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 10)),
      );
    }
  });

  group('BG real: backgrounding the app with the device tools', () {
    for (final _Hold hold in _holds) {
      test(
        'BG real ${hold.ecosystem}: Home cancels the held call as app-backgrounded; '
        'reopening resumes the job; one output',
        () async {
          final AndroidConversionHarness h = await _harness(
            hold,
            'bg-real-${hold.ecosystem}',
            deadline: const Duration(seconds: 90),
          );
          final events = <String>[];
          try {
            final selection = ScriptedSelection(
              pick: 'weebcentral',
              alsoPick: hold.alsoPick,
              acceptPartial: true,
              beforeSearch: (onSearch) => _backgroundDuringSearch(
                h,
                hold,
                onSearch,
                events,
                background: () async {
                  print('BG_HOLDING ${hold.ecosystem}: background the app now');
                  final asked = Stopwatch()..start();
                  await until(
                    () => h.runtimes.isBackgrounded,
                    timeout: const Duration(minutes: 5),
                  );
                  events.add(
                    'port-backgrounded:${h.runtimes.browserPort?.isBackgrounded}',
                  );
                  events.add(
                    'detected-after-ask-ms:${asked.elapsedMilliseconds}',
                  );
                },
                foreground: () async {
                  print(
                    'BG_BACKGROUNDED ${hold.ecosystem}: reopen the app now',
                  );
                  await until(
                    () => !h.runtimes.isBackgrounded,
                    timeout: const Duration(minutes: 5),
                  );
                },
                resume: true,
              ),
            );
            final HarnessRun run = await h.convert(
              hold.source,
              hold.target,
              selection: selection,
            );
            print('BG_EVENTS $events');
            _expectNamedOutcome(events);
            if (h.runtimes.browserPort != null) {
              expect(events, contains('port-backgrounded:true'));
            }
            final Map<String, Object?> data = h.checkRun(run);
            expect(h.outDir.listSync(), hasLength(1));
            _receipt('real-background', <String, Object?>{
              ...data,
              'ecosystem': hold.ecosystem,
              'events': events,
              'drivenBy': 'T3 device tools (agent-device home / open)',
              'resources': h.resources(),
            });
          } finally {
            await h.close();
          }
        },
        timeout: const Timeout(Duration(minutes: 15)),
        skip: _manual ? false : 'Manual: --dart-define=SRT_MANUAL=true',
      );
    }
  });
}
