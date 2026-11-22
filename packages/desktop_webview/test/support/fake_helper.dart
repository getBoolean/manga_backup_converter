import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_webview/desktop_webview.dart';
import 'package:source_runtime/source_contracts.dart';

/// Answers one helper request: an `ok` object, a [FakeHelperError],
/// [fakeHelperNoReply] to leave it unanswered, or `null` for
/// [FakeHelper.defaultReply].
typedef FakeHelperReply = Object? Function(Map<String, Object?> request);

/// An `err` answer of [FakeHelper].
final class FakeHelperError {
  const FakeHelperError(this.code, this.message, {this.operation});

  final String code;
  final String message;
  final String? operation;
}

/// A scripted `desktop_webview_helper` process for tests of the client's side
/// of the helper protocol: records every request the client writes, answers
/// through [reply] (falling back to [defaultReply]) and emits events on demand.
/// No WebView or window is involved.
final class FakeHelper {
  FakeHelper({this.reply});

  final FakeHelperReply? reply;

  /// Requests in the order the client wrote them, `id` included.
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];

  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();

  /// The `ready` frame emitted at start-up.
  static Map<String, Object?> readyFrame() => <String, Object?>{
    'ev': 'ready',
    'protocol': helperProtocolVersion,
    'helperVersion': '0.1.0',
    'engine': 'webview2',
    'engineVersion': 'fake',
    'pid': 4242,
    'maxFrameBytes': helperMaxFrameBytes,
    'capabilities': <String, Object?>{
      'browser': <String, Object?>{
        'available': <String>[for (final BrowserFeature f in BrowserFeature.values) f.wire],
        'unavailable': <String, Object?>{},
      },
      'requestObserve': 'all',
      'requestReplace': true,
      'statusCodes': true,
      'navigationFailures': true,
      'storage': 'fake',
      'offlineEnforced': true,
      'loadDataBaseUrl': true,
      'startScripts': true,
      'messageChannels': true,
      'record': true,
      'syncScriptInterface': false,
    },
    'wipe': <String, Object?>{'removed': 0, 'failed': 0},
  };

  /// The [HelperLauncher] for [DesktopWebViewConfig.launcher].
  Future<Process> launch(String executable, List<String> arguments) async {
    emit(readyFrame());
    return _FakeProcess(this);
  }

  /// Writes [frame] to the client as one helper line.
  void emit(Map<String, Object?> frame) {
    if (!_stdout.isClosed) _stdout.add(utf8.encode('${jsonEncode(frame)}\n'));
  }

  /// Requests with [op], in order.
  List<Map<String, Object?>> withOp(String op) => <Map<String, Object?>>[
    for (final Map<String, Object?> r in requests)
      if (r['op'] == op) r,
  ];

  /// What a working helper answers, without a WebView.
  static Object? defaultReply(Map<String, Object?> request) => switch (request['op']) {
    'load' => <String, Object?>{'finalUrl': request['url'], 'status': 200},
    'loadData' => <String, Object?>{'finalUrl': request['baseUrl'], 'status': 200},
    'eval' => <String, Object?>{'result': '"fake"'},
    'cookies' => <String, Object?>{
      'cookies': <Object?>[
        <String, Object?>{
          'name': 'a',
          'value': 'b',
          'domain': 'example.test',
          'path': '/',
          'expiresUnix': null,
          'secure': false,
          'httpOnly': false,
        },
      ],
    },
    'wipe' => <String, Object?>{'removed': 0},
    _ => <String, Object?>{},
  };

  void _onLine(String line) {
    if (line.isEmpty) return;
    final request = jsonDecode(line) as Map<String, Object?>;
    requests.add(request);
    final Object? custom = reply?.call(request);
    final Object? answer = identical(custom, fakeHelperNoReply) ? null : custom ?? defaultReply(request);
    final Object? id = request['id'];
    switch (answer) {
      case FakeHelperError(:final String code, :final String message, :final String? operation):
        emit(<String, Object?>{
          'id': id,
          'err': <String, Object?>{'code': code, 'message': message, 'operation': ?operation},
        });
      case final Map<String, Object?> ok:
        emit(<String, Object?>{'id': id, 'ok': ok});
      case _:
        break;
    }
    if (request['op'] == 'shutdown') _finish();
  }

  void _finish() {
    if (_exit.isCompleted) return;
    unawaited(_stdout.close());
    _exit.complete(0);
  }
}

/// A sentinel [FakeHelperReply] answer: leave the request unanswered.
const Object fakeHelperNoReply = _NoReply();

final class _NoReply {
  const _NoReply();
}

final class _FakeProcess implements Process {
  _FakeProcess(this._helper) {
    final input = StreamController<List<int>>();
    stdin = IOSink(input);
    input.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_helper._onLine, onDone: _helper._finish);
  }

  final FakeHelper _helper;

  @override
  late final IOSink stdin;

  @override
  Stream<List<int>> get stdout => _helper._stdout.stream;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  Future<int> get exitCode => _helper._exit.future;

  @override
  int get pid => 4242;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    _helper._finish();
    return true;
  }
}
