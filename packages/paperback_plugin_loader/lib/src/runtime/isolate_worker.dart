import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/src/adapter.dart';
import 'package:paperback_plugin_loader/src/host/browser.dart';
import 'package:paperback_plugin_loader/src/host/network.dart';
import 'package:paperback_plugin_loader/src/runtime/limit_sizing.dart';
import 'package:paperback_plugin_loader/src/runtime/quickjs_runtime.dart';
import 'package:paperback_plugin_loader/src/runtime/runtime_limits.dart';
import 'package:paperback_plugin_loader/src/runtime/worker.dart';
import 'package:paperback_plugin_loader/src/worker_plan.dart';
import 'package:quickjs/quickjs.dart';
import 'package:source_runtime/source_runtime.dart';

/// Creates the worker's HTTP client inside the worker isolate (a client is
/// not sendable). Live in production; `MultiReplayHttpClient` in tests.
typedef PaperbackClientFactory = http.Client Function();

/// Builds the package adapter inside the worker isolate. The default is the
/// real [PaperbackApiAdapter] over [PaperbackIsolateWorkerConfig.clientFactory].
typedef PaperbackIsolateAdapterFactory = PaperbackPackageAdapter Function(
  PaperbackBrowserChannel browser,
  http.Client client,
  void Function(String) log,
);

/// What one in-app Paperback worker isolate runs with (KTD12, KTD13).
///
/// Every field must be sendable to another isolate of this group: the
/// factories are closures that capture only sendable state.
final class PaperbackIsolateWorkerConfig {
  const PaperbackIsolateWorkerConfig({
    required this.limits,
    required this.clientFactory,
    this.deadlineHeadroom = Duration.zero,
    this.adapterFactory,
    this.browserEnabled = true,
    this.debugName = 'paperback-worker',
  });

  /// The QuickJS limits (KTD25), from [planPaperbackIsolateWorker] in
  /// production.
  final PaperbackRuntimeLimits limits;

  /// Added to the engine deadline in the handshake (see `reportedLimits`).
  final Duration deadlineHeadroom;
  final PaperbackClientFactory clientFactory;
  final PaperbackIsolateAdapterFactory? adapterFactory;

  /// Whether the handshake advertises `capabilities.browser`.
  final bool browserEnabled;
  final String debugName;
}

/// A [WorkerLauncher] that runs the Paperback worker in a new Dart isolate of
/// this process, speaking protocol v1 over isolate ports (U10, KTD13): the
/// in-app path for iOS (and Android, U12), where no Dart subprocess can be
/// launched.
///
/// - **Same host as desktop:** the isolate runs [PaperbackSourceWorker] with
///   the U5 promise bridge and the U6 0.8/0.9 adapters unchanged; only the
///   byte transport differs. The supervisor (`WorkerSupervisor`) and the
///   browser bridge stay on the launching isolate.
/// - **Execution termination (KTD12):** JS loops are bounded inside the
///   engine by the operation deadline, which the interrupt handler checks
///   natively, so it fires even when the worker isolate cannot process a
///   message. Each package runtime's interrupt token is published to the
///   launching isolate as soon as the runtime exists, and adopted there
///   (a native reference), so [WorkerProcess.kill] interrupts running JS
///   from this isolate before it kills the worker isolate. `Isolate.kill`
///   alone could not stop JS: it takes effect only when the isolate returns
///   from native code.
/// - **No hard-stop boundary for native hangs:** a QuickJS crash ends the
///   app process; process-level isolation is not claimed on mobile (KTD12).
WorkerLauncher isolatePaperbackLauncher(PaperbackIsolateWorkerConfig config) => (WorkerSpec spec) async {
  final fromWorker = ReceivePort('${config.debugName} messages');
  final exitPort = ReceivePort('${config.debugName} exit');
  final errorPort = ReceivePort('${config.debugName} errors');
  final process = _IsolateWorkerProcess(fromWorker, exitPort, errorPort);
  try {
    process._isolate = await Isolate.spawn<(PaperbackIsolateWorkerConfig, SendPort)>(
      _workerMain,
      (config, fromWorker.sendPort),
      onExit: exitPort.sendPort,
      onError: errorPort.sendPort,
      debugName: config.debugName,
    );
  } on Object {
    process._closePorts();
    rethrow;
  }
  return process;
};

/// Measures this device for the KTD25 sizing rule on a worker isolate's
/// thread (the thread stack the runtime will actually have), then plans the
/// worker with [planPaperbackWorker].
Future<PaperbackWorkerPlan> planPaperbackIsolateWorker({
  int concurrentRuntimes = 1,
  Duration hostWaitAllowance = paperbackHostWaitAllowance,
  int calibrationRuns = 15,
}) async {
  final Map<String, Object?> measured = await Isolate.run(
    () => DeviceCapability.measure(processors: Platform.numberOfProcessors, calibrationRuns: calibrationRuns).toJson(),
    debugName: 'paperback-device-measure',
  );
  return planPaperbackWorker(
    device: DeviceCapability.fromJson(measured),
    concurrentRuntimes: concurrentRuntimes,
    hostWaitAllowance: hostWaitAllowance,
  );
}

// --- Worker side --------------------------------------------------------------

sealed class _ToWorker {
  const _ToWorker();
}

final class _AdoptedToken extends _ToWorker {
  const _AdoptedToken(this.address);

  final int address;
}

Future<void> _workerMain((PaperbackIsolateWorkerConfig, SendPort) message) async {
  final (PaperbackIsolateWorkerConfig config, SendPort toMain) = message;
  final input = StreamController<List<int>>();
  final control = ReceivePort('${config.debugName} input');
  // Tokens published to the launching isolate, held until it confirms that
  // it adopted them (so the native token cannot be freed in between).
  final published = <int, JsInterruptToken>{};
  control.listen((Object? m) {
    switch (m) {
      case final TransferableTypedData data:
        input.add(data.materialize().asUint8List());
      case null:
        unawaited(input.close());
      case _AdoptedToken(:final int address):
        published.remove(address)?.release();
    }
  });
  toMain.send(control.sendPort);

  void log(String line) => toMain.send(line);
  final http.Client client = config.clientFactory();
  final output = StreamController<List<int>>();
  final StreamSubscription<List<int>> forward = output.stream.listen(
    (List<int> chunk) => toMain.send(TransferableTypedData.fromList(<Uint8List>[Uint8List.fromList(chunk)])),
  );
  try {
    await runZoned(
      () => PaperbackSourceWorker(
        input: input.stream,
        output: output,
        limits: config.limits,
        deadlineHeadroom: config.deadlineHeadroom,
        adapterFactory: (PaperbackBrowserChannel browser) =>
            config.adapterFactory?.call(browser, client, log) ??
            PaperbackApiAdapter(http: PaperbackHttp(client), browser: browser, log: log),
        browserEnabled: config.browserEnabled,
        log: log,
        onRuntimeCreated: (SourceJsRuntime runtime) {
          final int address = runtime.interruptTokenAddress;
          published[address] = JsInterruptToken.fromAddress(address);
          toMain.send(_PublishedToken(address));
        },
      ).run(),
      zoneSpecification: ZoneSpecification(print: (_, _, _, String line) => log(line)),
    );
  } finally {
    await forward.cancel();
    client.close();
    // Unadopted tokens are released only now; the launching isolate never
    // touches a token it did not adopt.
    for (final JsInterruptToken t in published.values) {
      t.release();
    }
    control.close();
    toMain.send(const _WorkerDone());
  }
}

final class _PublishedToken {
  const _PublishedToken(this.address);

  final int address;
}

final class _WorkerDone {
  const _WorkerDone();
}

// --- Launcher side --------------------------------------------------------------

final class _IsolateWorkerProcess implements WorkerProcess {
  _IsolateWorkerProcess(this._fromWorker, this._exitPort, this._errorPort) {
    _stdinController.stream.listen(
      (List<int> chunk) => _sendToWorker(TransferableTypedData.fromList(<Uint8List>[Uint8List.fromList(chunk)])),
      onDone: () => _sendToWorker(null),
    );
    _fromWorker.listen(_onMessage);
    _errorPort.listen((Object? e) {
      final text = e is List && e.isNotEmpty ? '${e.first}' : '$e';
      _stderr.add(utf8.encode('[paperback-isolate] uncaught error: $text\n'));
    });
    _exitPort.listen((_) => _onExit());
  }

  final ReceivePort _fromWorker;
  final ReceivePort _exitPort;
  final ReceivePort _errorPort;
  Isolate? _isolate;
  SendPort? _toWorker;
  final List<Object?> _queued = <Object?>[];
  final StreamController<List<int>> _stdinController = StreamController<List<int>>();
  late final IOSink _stdin = IOSink(_stdinController);
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  final Map<int, JsInterruptToken> _tokens = <int, JsInterruptToken>{};
  bool _killed = false;
  bool _done = false;

  /// Interrupt tokens adopted from the worker (diagnostics and tests).
  int get adoptedTokens => _tokens.length;

  void _sendToWorker(Object? message) {
    final SendPort? port = _toWorker;
    if (port == null) {
      _queued.add(message);
    } else {
      port.send(message);
    }
  }

  void _onMessage(Object? m) {
    switch (m) {
      case final SendPort port:
        _toWorker = port;
        for (final Object? q in _queued) {
          port.send(q);
        }
        _queued.clear();
      case final TransferableTypedData data:
        if (!_stdout.isClosed) _stdout.add(data.materialize().asUint8List());
      case final String line:
        if (!_stderr.isClosed) _stderr.add(utf8.encode('$line\n'));
      case _PublishedToken(:final int address):
        // The worker holds its own reference until it sees the adoption.
        _tokens[address] = JsInterruptToken.fromAddress(address);
        if (_killed) _tokens[address]!.request();
        _toWorker?.send(_AdoptedToken(address));
      case _WorkerDone():
        _done = true;
    }
  }

  void _onExit() {
    for (final JsInterruptToken t in _tokens.values) {
      t.release();
    }
    _tokens.clear();
    _closePorts();
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    if (!_exit.isCompleted) _exit.complete(_killed && !_done ? -9 : 0);
  }

  void _closePorts() {
    _fromWorker.close();
    _exitPort.close();
    _errorPort.close();
  }

  @override
  int get pid => -1;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  bool kill() {
    if (_exit.isCompleted) return false;
    _killed = true;
    // Stop JS first: the isolate handles the kill only once it is back in
    // Dart code.
    for (final JsInterruptToken t in _tokens.values) {
      t.request();
    }
    _isolate?.kill(priority: Isolate.immediate);
    return true;
  }
}
