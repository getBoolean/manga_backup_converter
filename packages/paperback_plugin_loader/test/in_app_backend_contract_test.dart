// The in-app worker-isolate path (U10 iOS, U12 Android) on the desktop VM:
// the same provider -> supervisor -> protocol -> worker -> adapter -> QuickJS
// path as source_execution_test.dart, with the worker in a Dart isolate of
// this process instead of a subprocess. The iOS Simulator runs the same
// cases from integration_test/source_runners_ios_paperback_test.dart.
@TestOn('vm')
@Timeout(Duration(minutes: 30))
library;

import 'dart:async';

import 'package:checks/checks.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

import 'runtime/test_support.dart';
import 'support/in_app_support.dart';
import 'support/paperback_scenarios.dart';
import 'support/scripted_browser_port.dart';

const SupervisorLimits _supervisorLimits = SupervisorLimits(
  maxConcurrentPackages: 1,
  operationDeadline: Duration(minutes: 15),
  cancelGrace: Duration(seconds: 5),
  interactionTimeout: Duration(seconds: 5),
  shutdownGrace: Duration(seconds: 5),
);

PaperbackIsolateWorkerConfig _loopConfig({required Duration deadline}) => PaperbackIsolateWorkerConfig(
  limits: testLimits(operationDeadline: deadline),
  clientFactory: fakeHttp,
  adapterFactory: (_, _, _) => const LoopingAdapter(),
);

void main() {
  test('WeebCentral: 0.9 and both 0.8 bundles run search, details and chapters in a worker isolate', () async {
    final InAppSiteRun run = await runSiteInIsolate(
      'weebcentral',
      limits: testLimits(operationDeadline: const Duration(minutes: 15)),
      supervisorLimits: _supervisorLimits,
    );
    check(run.misses).isEmpty();
    check(run.runs.map((BundleRun r) => r.family).toList()).deepEquals(<PaperbackApiFamily>[
      PaperbackApiFamily.v09,
      PaperbackApiFamily.v08,
      PaperbackApiFamily.v08,
    ]);
    for (final BundleRun r in run.runs) {
      final SearchPage page = (r.page1! as SourceSuccess<SearchPage>).value;
      check(page.hits.first.ref.mangaId).equals('01J76XYF0TGKQ7XJ4XVPV1C0BP');
      final MangaSnapshot s = (r.details! as SourceSuccess<MangaSnapshot>).value;
      check(s.metadata.title).equals("ONIMAI - I'm Now Your Sister!");
      check(s.chapters).length.equals(114);
      check(s.chapters.first.chapterId).equals('01KWM07QYFJMAP46S1A3ZVDWYG');
    }
  });

  test('MangaDex: 0.9 and 0.8 (community 3.0.6) complete the chapter feed in a worker isolate', () async {
    final InAppSiteRun run = await runSiteInIsolate(
      'mangadex',
      limits: testLimits(operationDeadline: const Duration(minutes: 15)),
      supervisorLimits: _supervisorLimits,
    );
    check(run.misses).isEmpty();
    final BundleRun inkdex = run.runs.firstWhere((BundleRun r) => r.family == PaperbackApiFamily.v09);
    final MangaSnapshot s = (inkdex.details! as SourceSuccess<MangaSnapshot>).value;
    check(s.metadata.title).equals("ONIMAI: I'm Now Your Sister!");
    check(s.chapters).length.equals(223);
    final BundleRun community = run.runs.firstWhere((BundleRun r) => r.family == PaperbackApiFamily.v08);
    final MangaSnapshot c = (community.details! as SourceSuccess<MangaSnapshot>).value;
    check(c.metadata.authors).deepEquals(<String>['Nekotoufu']);
    check(c.chapters).length.equals(223);
  });

  test('MangaFire 0.9: executeInWebView reaches the BrowserPort from the worker isolate', () async {
    final port = ScriptedBrowserPort(respond: (ScriptedPage page) => '{"matched":"","all":[]}');
    final InAppSiteRun run = await runSiteInIsolate(
      'mangafire',
      limits: testLimits(operationDeadline: const Duration(minutes: 15)),
      supervisorLimits: _supervisorLimits,
      port: port,
    );
    check(run.misses).isEmpty();
    check(run.runs.single.page1)
        .isA<SourceFailed<SearchPage>>()
        .has((SourceFailed<SearchPage> f) => f.failure, 'failure')
        .isA<SourceErrorFailure>()
        .has((SourceErrorFailure f) => f.message, 'message')
        .contains('VRF capture timed out');
    check(port.pages).isNotEmpty();
    check(port.closed).length.equals(port.pages.length);
  });

  for (final mode in <String>['sync', 'jobs']) {
    test('a $mode JS loop ends at the native deadline although the worker isolate cannot read the cancel', () async {
      final IsolateWorkerHarness h = await IsolateWorkerHarness.start(
        _loopConfig(deadline: const Duration(milliseconds: 400)),
      );
      await h.handshake();
      check((await h.loadLoopPackage()).error).isNull();
      final watch = Stopwatch()..start();
      final String id = h.search(mode);
      // Sent while JS spins: the isolate reads it only after the engine
      // stops at the deadline (a sync loop never yields to Dart; a job loop
      // yields once per job slice, so it may be read and cancel instead).
      await Future<void>.delayed(const Duration(milliseconds: 100));
      h.cancel(id);
      final ProtocolFrame reply = await h.reply(id).timeout(const Duration(seconds: 10));
      watch.stop();
      final code = reply.error!['code']! as String;
      if (mode == 'sync') {
        check(code).equals('timeout');
      } else {
        check(<String>{'timeout', 'cancelled'}.contains(code)).isTrue();
      }
      check(watch.elapsed).isLessThan(const Duration(seconds: 5));
      // The runtime is still usable after the interrupt.
      final ProtocolFrame next = await h.reply(h.search('again')).timeout(const Duration(seconds: 10));
      check(next.ok!['warnings']).isA<List<Object?>>().deepEquals(<String>['ok:again']);
      check(await h.shutdown()).equals(0);
    });
  }

  test('kill interrupts JS from the launching isolate through the adopted interrupt token', () async {
    final IsolateWorkerHarness h = await IsolateWorkerHarness.start(_loopConfig(deadline: const Duration(minutes: 5)));
    await h.handshake();
    check((await h.loadLoopPackage()).error).isNull();
    h.search('sync');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final watch = Stopwatch()..start();
    check(h.process.kill()).isTrue();
    final int exit = await h.process.exitCode.timeout(const Duration(seconds: 10));
    watch.stop();
    check(exit).equals(-9);
    check(watch.elapsed).isLessThan(const Duration(seconds: 2));
  });

  test('a host call that never completes is bounded by the deadline', () async {
    final IsolateWorkerHarness h = await IsolateWorkerHarness.start(
      _loopConfig(deadline: const Duration(milliseconds: 300)),
    );
    await h.handshake();
    check((await h.loadLoopPackage()).error).isNull();
    final ProtocolFrame reply = await h.reply(h.search('host')).timeout(const Duration(seconds: 10));
    check(reply.error!['code']).equals('timeout');
    check(await h.shutdown()).equals(0);
  });
}
