import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/src/adapter.dart';
import 'package:paperback_plugin_loader/src/host/browser.dart';
import 'package:paperback_plugin_loader/src/host/network.dart';
import 'package:paperback_plugin_loader/src/runtime/runtime_limits.dart';
import 'package:paperback_plugin_loader/src/runtime/worker.dart';
import 'package:source_runtime/source_runtime.dart';

/// A [WorkerLauncher] that runs the Paperback worker on this isolate over
/// in-memory pipes, speaking the same protocol as the desktop executable.
///
/// It gives no hard-stop boundary (killing it only closes its input), so the
/// desktop composition root launches the built executable instead; tests use
/// this to exercise the provider, supervisor and adapter without a build.
WorkerLauncher inProcessPaperbackLauncher({
  required http.Client client,
  required PaperbackRuntimeLimits limits,
  void Function(String line)? log,
}) => (WorkerSpec spec) async {
  final stdinController = StreamController<List<int>>();
  final stdoutController = StreamController<List<int>>();
  final stderrController = StreamController<List<int>>();
  final exit = Completer<int>();
  final worker = PaperbackSourceWorker(
    input: stdinController.stream,
    output: stdoutController,
    limits: limits,
    adapterFactory: (PaperbackBrowserChannel browser) =>
        PaperbackApiAdapter(http: PaperbackHttp(client), browser: browser, log: log),
    browserEnabled: true,
    pid: pid,
    log: (String line) => log?.call(line),
  );
  unawaited(
    worker.run().then((_) async {
      await stderrController.close();
      if (!exit.isCompleted) exit.complete(0);
    }),
  );
  return _InProcessWorkerProcess(IOSink(stdinController), stdoutController.stream, stderrController.stream, exit);
};

final class _InProcessWorkerProcess implements WorkerProcess {
  _InProcessWorkerProcess(this.stdin, this.stdout, this.stderr, this._exit);

  @override
  final IOSink stdin;

  @override
  final Stream<List<int>> stdout;

  @override
  final Stream<List<int>> stderr;

  final Completer<int> _exit;

  @override
  int get pid => -1;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill() {
    unawaited(stdin.close());
    if (!_exit.isCompleted) _exit.complete(-9);
    return true;
  }
}
