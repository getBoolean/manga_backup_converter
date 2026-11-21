import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';

/// Paperback desktop worker process (protocol v1 over stdin/stdout).
///
/// Every QuickJS limit is a required argument (KTD25); the supervisor derives
/// them from the sizing rule for this device:
///
///     paperback_source_worker --memory-limit-bytes=N --max-stack-bytes=N
///         --operation-deadline-ms=N --job-slice-ms=N [network mode]
///
/// Network mode (default: the live network):
///
///     --replay=<capture dir>           (repeatable) serve committed captures
///                                      only; any other request fails loudly
///     --record=<capture dir> --record-source=<name>
///         --record-min-interval-ms=N --record-licence=<text>
///         [--record-volatile=<query parameter>]...
///                                      manual capture run: forward to the
///                                      network and write the capture on
///                                      shutdown (never used by tests)
///
/// stdout carries protocol frames only; logs and `print` go to stderr.
Future<void> main(List<String> args) async {
  final PaperbackRuntimeLimits limits;
  final PaperbackNetworkMode network;
  try {
    final WorkerArguments parsed = parseWorkerArguments(args);
    limits = parsed.limits;
    network = parsed.network;
  } on FormatException catch (e) {
    stderr.writeln('paperback_source_worker: ${e.message}');
    exitCode = 64;
    return;
  }
  final (http.Client client, FutureOr<void> Function()? onShutdown) = _client(network);
  await runZoned(
    () => PaperbackSourceWorker(
      input: stdin,
      output: stdout,
      limits: limits,
      adapterFactory: (PaperbackBrowserChannel browser) =>
          PaperbackApiAdapter(http: PaperbackHttp(client), browser: browser, log: stderr.writeln),
      browserEnabled: true,
      onShutdown: onShutdown,
      pid: pid,
      log: stderr.writeln,
    ).run(),
    zoneSpecification: ZoneSpecification(
      print: (Zone self, ZoneDelegate parent, Zone zone, String line) => stderr.writeln(line),
    ),
  );
  client.close();
}

(http.Client, FutureOr<void> Function()?) _client(PaperbackNetworkMode mode) {
  switch (mode) {
    case LiveNetwork():
      return (http.Client(), null);
    case ReplayNetwork(:final List<Directory> dirs):
      return (MultiReplayHttpClient.load(dirs), null);
    case final RecordNetwork r:
      final recorder = RecordingHttpClient(
        http.Client(),
        minInterval: r.minInterval,
        licence: r.licence,
        volatileQueryParameters: r.volatileQueryParameters,
      );
      return (
        recorder,
        () {
          r.dir.createSync(recursive: true);
          recorder.writeTo(r.dir, ecosystem: 'paperback', source: r.source, notes: 'Recorded by paperback_source_worker --record');
          stderr.writeln('paperback_source_worker: recorded ${recorder.length} exchanges into ${r.dir.path}');
        },
      );
  }
}

/// Parsed worker arguments.
typedef WorkerArguments = ({PaperbackRuntimeLimits limits, PaperbackNetworkMode network});

/// Parses `--name=value` arguments: the four QuickJS limits are required
/// positive integers; the network mode is optional (see [main]).
WorkerArguments parseWorkerArguments(List<String> args) {
  final ints = <String, int>{};
  final strings = <String, List<String>>{};
  const limitNames = <String>{'memory-limit-bytes', 'max-stack-bytes', 'operation-deadline-ms', 'job-slice-ms'};
  const networkNames = <String>{
    'replay',
    'record',
    'record-source',
    'record-min-interval-ms',
    'record-licence',
    'record-volatile',
  };
  for (final arg in args) {
    final Match? m = RegExp(r'^--([a-z-]+)=(.*)$', dotAll: true).firstMatch(arg);
    if (m == null) throw FormatException('Unrecognized argument "$arg"');
    final String name = m.group(1)!;
    final String value = m.group(2)!;
    if (limitNames.contains(name)) {
      final int? v = RegExp(r'^\d+$').hasMatch(value) ? int.parse(value) : null;
      if (v == null) throw FormatException('--$name must be an integer');
      ints[name] = v;
    } else if (networkNames.contains(name)) {
      (strings[name] ??= <String>[]).add(value);
    } else {
      throw FormatException('Unrecognized argument "$arg"');
    }
  }
  int required(String name) {
    final int? value = ints[name];
    if (value == null) throw FormatException('Missing required --$name');
    if (value <= 0) throw FormatException('--$name must be positive');
    return value;
  }

  String single(String name) {
    final List<String>? v = strings[name];
    if (v == null || v.length != 1 || v.single.isEmpty) throw FormatException('--record needs exactly one --$name');
    return v.single;
  }

  final limits = PaperbackRuntimeLimits(
    memoryLimitBytes: required('memory-limit-bytes'),
    maxStackBytes: required('max-stack-bytes'),
    operationDeadline: Duration(milliseconds: required('operation-deadline-ms')),
    jobSlice: Duration(milliseconds: required('job-slice-ms')),
  );
  final List<String>? replay = strings['replay'];
  final List<String>? record = strings['record'];
  if (replay != null && record != null) throw const FormatException('--replay and --record are exclusive');
  final PaperbackNetworkMode network;
  if (record != null) {
    if (record.length != 1) throw const FormatException('--record may be given once');
    final int? interval = int.tryParse(single('record-min-interval-ms'));
    // The capture rules require at least 1.5 s between live requests.
    if (interval == null || interval < 1500) throw const FormatException('--record-min-interval-ms must be >= 1500');
    network = RecordNetwork(
      dir: Directory(record.single),
      source: single('record-source'),
      minInterval: Duration(milliseconds: interval),
      licence: single('record-licence'),
      volatileQueryParameters: <String>{...?strings['record-volatile']},
    );
  } else if (replay != null) {
    network = ReplayNetwork(<Directory>[for (final String d in replay) Directory(d)]);
  } else {
    if (strings.keys.any((String k) => k.startsWith('record-'))) {
      throw const FormatException('--record-* options need --record');
    }
    network = const LiveNetwork();
  }
  return (limits: limits, network: network);
}

/// Parses only the limit arguments (kept for callers of the U5 API).
PaperbackRuntimeLimits parseLimitArguments(List<String> args) => parseWorkerArguments(args).limits;
