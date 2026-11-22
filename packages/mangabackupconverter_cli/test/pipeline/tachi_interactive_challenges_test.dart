// The CLI composition passes `--interactive-challenges` to the JVM worker
// only in interactive runs with a browser (the worker then shows Cloudflare
// challenges in the helper's window); unattended runs and runs without a
// browser never pass it. No worker is started: a recording launcher captures
// the spec and refuses to launch.
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_tachi.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:test/scaffolding.dart';

/// A browser port nothing calls: only its presence matters here.
final class _UnusedPort implements BrowserPort {
  @override
  Future<BrowserOutcome<BrowserSession>> openSession(BrowserSessionRequest request, {CancellationToken? cancel}) =>
      throw UnimplementedError();

  @override
  Future<BrowserOutcome<void>> wipeAllSourceData() => throw UnimplementedError();

  @override
  Future<void> fence(int generation) async {}
}

void main() {
  Future<List<String>> launchedArguments({required bool interactive, required bool browser}) async {
    final Directory temp = Directory.systemTemp.createTempSync('tachi-flags-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final specs = <WorkerSpec>[];
    final runtime = DesktopTachiRuntime(
      locate: () => const SourceSuccess<TachiWorkerLocation>(
        TachiWorkerLocation(java: 'java', classpathDirectory: 'lib', handshakeDeadline: Duration(seconds: 5)),
      ),
      cacheDirectory: temp,
      fetch: (Uri url) async => Uint8List(0),
      launcher: (WorkerSpec spec) async {
        specs.add(spec);
        throw const ProcessException('java', <String>[], 'not launched in this test');
      },
      browserPort: browser ? _UnusedPort() : null,
      interactionTimeout: const Duration(minutes: 5),
      interactiveChallenges: interactive,
    );
    final owner = ConversionOwner();
    await runtime.attach(owner);
    try {
      check(runtime.runtime()).isA<SourceSuccess<TachiRuntime>>();
      await runtime.scope!.worker(WorkerKind.jvm);
    } finally {
      await owner.close();
    }
    return specs.single.arguments;
  }

  test('interactive runs with a browser pass the interaction bound as --interactive-challenges', () async {
    final List<String> args = await launchedArguments(interactive: true, browser: true);
    final int i = args.indexOf('--interactive-challenges');
    check(i).isGreaterOrEqual(0);
    check(args[i + 1]).equals('${const Duration(minutes: 5).inMilliseconds}');
  });

  test('unattended runs never pass --interactive-challenges', () async {
    check(await launchedArguments(interactive: false, browser: true))
        .not((Subject<List<String>> it) => it.contains('--interactive-challenges'));
  });

  test('runs without a browser never pass --interactive-challenges', () async {
    check(await launchedArguments(interactive: true, browser: false))
        .not((Subject<List<String>> it) => it.contains('--interactive-challenges'));
  });
}
