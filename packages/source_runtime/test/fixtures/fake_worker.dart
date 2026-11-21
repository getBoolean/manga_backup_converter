// A fake source worker for supervisor tests. Compiled to a native executable
// by the tests and launched as a real subprocess.
//
// Deliberately imports only dart: libraries and re-implements the wire format,
// so the supervisor's codec is checked against an independent implementation.
//
// Arguments:
//   --bad-version          answer the handshake with protocol version 2
//   --startup-garbage      print a non-protocol line before anything else
//   --handshake-wait=PATH  delay the handshake reply until PATH exists
//   --fail-package=ID      fail package.load for ID
//   --ignore-shutdown      never answer or act on shutdown
//   --bad-handshake        answer the handshake without its capabilities
//   --malformed-load=ID    answer package.load for ID with a malformed reply
//   --minor=N              highest protocol minor the worker speaks (default 1);
//                          the reply carries the lower of N and the request's
//   --omit-minor           reply without protocolMinor, like a 1.0 worker
//   --force-minor=N        reply with protocolMinor N whatever was offered
//   --limits=JSON          report this handshake `limits` object
//   --sizing=JSON          report this handshake `sizing` object
//   --prepare-lie          artifact.prepare reports a digest that is not the output's
//   --respond-requests     answer each held host.browser.request event (1.2) with a
//                          host.browser.respond rreq whose response body is
//                          "from worker", sent under the reverse call in flight
//
// artifact.prepare copies inputPath to outputPath, echoes the input binding
// (a copy keeps its digest) and records trustedSigners; it never needs the
// package to be loaded.
//
// settings.update fails when the new settings' values contain
// `"failUpdate": true`.
//
// Request payload `fake` object selects a behaviour (see _run).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

int _gen = 0;
final Map<String, Completer<void>> _cancels = <String, Completer<void>>{};
final Map<String, Completer<Map<String, Object?>>> _reverse = <String, Completer<Map<String, Object?>>>{};
final Map<String, Map<String, Object?>> _held = <String, Map<String, Object?>>{};
final Set<String> _issuedHandles = <String>{};
final Map<String, int> _activePerPackage = <String, int>{};
final Map<String, int> _maxPerPackage = <String, int>{};
final Map<String, String> _loaded = <String, String>{};
final Map<String, Object?> _settings = <String, Object?>{};
final List<Object?> _disposed = <Object?>[];
final List<Object?> _prepared = <Object?>[];
int _active = 0;
int _maxActive = 0;
int _handleCounter = 0;
int _reverseCounter = 0;

/// IDs of requests currently waiting on a reverse reply.
final List<String> _inFlightReverse = <String>[];
late List<String> _args;

void _write(Map<String, Object?> frame) {
  stdout.add(utf8.encode('${jsonEncode(frame)}\n'));
}

Map<String, Object?> _res(String id, {Map<String, Object?>? ok, String? errCode, String? errMessage, int? gen}) =>
    <String, Object?>{
      'v': 1,
      't': 'res',
      'id': id,
      'gen': gen ?? _gen,
      if (errCode == null) 'ok': ok ?? <String, Object?>{},
      if (errCode != null) 'err': <String, Object?>{'code': errCode, 'message': errMessage ?? errCode},
    };

String? _arg(String name) {
  for (final String a in _args) {
    if (a.startsWith('--$name=')) return a.substring(name.length + 3);
  }
  return null;
}

Future<void> main(List<String> args) async {
  _args = args;
  if (args.contains('--startup-garbage')) stdout.writeln('worker starting up');
  final pending = <int>[];
  await for (final List<int> chunk in stdin) {
    for (final b in chunk) {
      if (b != 0x0A) {
        pending.add(b);
        continue;
      }
      final frame = jsonDecode(utf8.decode(pending)) as Map<String, Object?>;
      pending.clear();
      unawaited(_dispatch(frame));
    }
  }
  exit(0);
}

Future<void> _dispatch(Map<String, Object?> frame) async {
  final type = frame['t']! as String;
  final id = frame['id']! as String;
  switch (type) {
    case 'cancel':
      _cancels[id]?.complete();
      return;
    case 'rres':
      _reverse.remove(id)?.complete(frame);
      return;
    case 'event':
      _onEvent(frame);
      return;
    case 'req':
      break;
    default:
      return;
  }
  final op = frame['op']! as String;
  final Map<String, Object?> payload = (frame['payload'] as Map<String, Object?>?) ?? <String, Object?>{};
  switch (op) {
    case 'handshake':
      _gen = frame['gen']! as int;
      final String? waitFile = _arg('handshake-wait');
      if (waitFile != null) {
        while (!File(waitFile).existsSync()) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }
      if (args.contains('--bad-version')) {
        _write(<String, Object?>{'v': 2, 't': 'res', 'id': id, 'gen': _gen, 'ok': <String, Object?>{}});
        return;
      }
      if (args.contains('--bad-handshake')) {
        _write(_res(id, ok: <String, Object?>{'protocolVersion': 1, 'worker': 'fake'}));
        return;
      }
      final int ownMinor = int.parse(_arg('minor') ?? '1');
      final int offered = payload['protocolMinor'] as int? ?? 0;
      final String? limits = _arg('limits');
      final String? sizing = _arg('sizing');
      _write(
        _res(
          id,
          ok: <String, Object?>{
            'protocolVersion': 1,
            if (!args.contains('--omit-minor'))
              'protocolMinor': _arg('force-minor') != null
                  ? int.parse(_arg('force-minor')!)
                  : (ownMinor < offered ? ownMinor : offered),
            'worker': 'fake',
            'pid': pid,
            'capabilities': <String, Object?>{
              'apiFamilies': <String>['fake-1'],
              'browser': true,
            },
            if (limits != null) 'limits': jsonDecode(limits),
            if (sizing != null) 'sizing': jsonDecode(sizing),
          },
        ),
      );
      return;
    case 'artifact.prepare':
      final artifact = payload['artifact']! as Map<String, Object?>;
      _prepared.add(<String, Object?>{
        'pkg': frame['pkg'],
        'loaded': _loaded.containsKey(frame['pkg']),
        'trustedSigners': payload['trustedSigners'],
      });
      File(payload['outputPath']! as String).writeAsBytesSync(File(payload['inputPath']! as String).readAsBytesSync());
      _write(
        _res(
          id,
          ok: <String, Object?>{
            'artifact': <String, Object?>{
              ...artifact,
              if (args.contains('--prepare-lie')) 'sha256': '0' * 64,
              'kind': 'jar',
            },
            'producer': 'fake-prepare',
            'converterVersion': 'fake.1',
          },
        ),
      );
      return;
    case 'shutdown':
      if (args.contains('--ignore-shutdown')) return;
      _write(_res(id));
      await stdout.flush();
      exit(0);
    case 'stats':
      _write(
        _res(
          id,
          ok: <String, Object?>{
            'pid': pid,
            'maxActive': _maxActive,
            'maxPerPackage': _maxPerPackage,
            'loaded': _loaded,
            'settings': _settings,
            'disposed': _disposed,
            'prepared': _prepared,
          },
        ),
      );
      return;
    case 'package.load':
      final pkg = frame['pkg']! as String;
      if (_arg('fail-package') == pkg) {
        _write(_res(id, errCode: 'artifact-incompatible', errMessage: 'fake load failure for $pkg'));
        return;
      }
      _loaded[pkg] = (payload['artifact'] as Map<String, Object?>?)?['sha256'] as String? ?? '';
      _settings[pkg] = payload['settings'];
      if (_arg('malformed-load') == pkg) {
        _write(_res(id, ok: <String, Object?>{'sources': 'not a list'}));
        return;
      }
      _write(
        _res(
          id,
          ok: <String, Object?>{
            'sources': <Object?>[
              <String, Object?>{
                'sourceId': '9223372036854775807',
                'name': 'Fake $pkg',
                'capabilities': <String, Object?>{
                  'operations': <String>['search', 'mangaDetails', 'chapterList'],
                },
              },
            ],
          },
        ),
      );
      return;
    case 'package.unload':
      final pkg = frame['pkg']! as String;
      _loaded.remove(pkg);
      _settings.remove(pkg);
      _write(_res(id));
      return;
    case 'settings.update':
      final pkg = frame['pkg']! as String;
      if (!_loaded.containsKey(pkg)) {
        _write(_res(id, errCode: 'stale-reference', errMessage: 'package $pkg is not loaded'));
        return;
      }
      final settings = payload['settings']! as Map<String, Object?>;
      if ((settings['values']! as Map<String, Object?>)['failUpdate'] == true) {
        _write(_res(id, errCode: 'source-error', errMessage: 'fake settings update failure'));
        return;
      }
      _settings[pkg] = settings;
      _write(_res(id));
      return;
    case 'dispose':
      _disposed.add(<String, Object?>{'pkg': frame['pkg'], 'handles': payload['handles']});
      _write(_res(id));
      return;
  }
  await _run(id, frame['pkg'] as String?, op, payload);
}

List<String> get args => _args;

Future<void> _run(String id, String? pkg, String op, Map<String, Object?> payload) async {
  final Map<String, Object?> fake = (payload['fake'] as Map<String, Object?>?) ?? <String, Object?>{};
  final cancel = Completer<void>();
  _cancels[id] = cancel;
  final String key = pkg ?? '';
  _active++;
  _activePerPackage[key] = (_activePerPackage[key] ?? 0) + 1;
  if (_active > _maxActive) _maxActive = _active;
  if (_activePerPackage[key]! > (_maxPerPackage[key] ?? 0)) _maxPerPackage[key] = _activePerPackage[key]!;
  try {
    if (fake['stderr'] case final String text) {
      final List<int> bytes = utf8.encode('$text\n');
      if (fake['stderrSplit'] == true) {
        // Two chunks split mid-line, so redaction must reassemble the line.
        final int mid = bytes.length ~/ 2;
        stderr.add(bytes.sublist(0, mid));
        await stderr.flush();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        stderr.add(bytes.sublist(mid));
        await stderr.flush();
      } else {
        // No flush: concurrent flushes on one IOSink throw.
        stderr.add(bytes);
      }
    }
    if (fake['crash'] == true) exit(3);
    if (fake['crashOnce'] case final String marker) {
      // Crash the first time only, so the re-queued attempt succeeds.
      if (!File(marker).existsSync()) {
        File(marker).writeAsStringSync('crashed');
        exit(3);
      }
    }
    if (fake['stdoutGarbage'] == true) {
      stdout.writeln('debug: this is not a frame');
      return;
    }
    if (fake['orphanReverse'] == true) {
      _write(<String, Object?>{
        'v': 1,
        't': 'rreq',
        'id': 'r-orphan',
        'gen': _gen,
        'op': 'host.browser.evaluate',
        'of': 'no-such-request',
        'payload': <String, Object?>{},
      });
      return;
    }
    if (fake['stdoutText'] case final String text) {
      stdout.writeln(text);
      return;
    }
    if (fake['errorMessage'] case final String message) {
      _write(_res(id, errCode: 'source-error', errMessage: message));
      return;
    }
    if (fake['malformed'] == true) {
      stdout.add(utf8.encode('{"v":1,"t":"res",\n'));
      return;
    }
    if (fake['unknownReply'] == true) {
      _write(_res('no-such-request'));
      return;
    }
    if (fake['hang'] == true) {
      await Completer<void>().future; // never settles, ignores cancel
    }
    if (fake['hangUntilCancel'] == true) {
      await cancel.future;
      _write(_res(id, errCode: 'cancelled', errMessage: 'cooperatively cancelled'));
      return;
    }
    if (fake['delayMs'] case final int ms) {
      await Future.any(<Future<void>>[Future<void>.delayed(Duration(milliseconds: ms)), cancel.future]);
      if (cancel.isCompleted) {
        _write(_res(id, errCode: 'cancelled', errMessage: 'cooperatively cancelled'));
        return;
      }
    }
    if (fake['batch'] case final String tag) {
      // Hold this reply until another request with the same tag arrives, then
      // write both replies in a single write.
      final Map<String, Object?>? otherReply = _held.remove(tag);
      final Map<String, Object?> mine = _res(id, ok: <String, Object?>{'echo': payload['value']});
      if (otherReply == null) {
        _held[tag] = mine;
        return;
      }
      stdout.add(utf8.encode('${jsonEncode(otherReply)}\n${jsonEncode(mine)}\n'));
      return;
    }
    if (fake['reverse'] case final Map<String, Object?> reverse) {
      final rid = 'r${++_reverseCounter}';
      final done = Completer<Map<String, Object?>>();
      _reverse[rid] = done;
      _inFlightReverse.add(id);
      _write(<String, Object?>{
        'v': 1,
        't': 'rreq',
        'id': rid,
        'gen': _gen,
        'op': reverse['op'],
        'of': id,
        'payload': reverse['payload'] ?? <String, Object?>{},
      });
      final Map<String, Object?> reply = await done.future;
      _inFlightReverse.remove(id);
      _write(_res(id, ok: <String, Object?>{'reverse': reply['ok'], 'reverseError': reply['err']}));
      return;
    }
    final Map<String, Object?> reply = switch (op) {
      'echo' => _res(id, ok: <String, Object?>{'echo': payload['value']}),
      'search' => _searchReply(id, pkg, payload),
      'details' => _detailsReply(id, pkg, payload),
      _ => _res(id, errCode: 'unsupported-api', errMessage: 'unknown op $op'),
    };
    if (fake['wrongGen'] == true) reply['gen'] = _gen + 1;
    if (fake['oversized'] case final int size) {
      reply['ok'] = <String, Object?>{'blob': 'x' * size};
    }
    if (fake['split'] == true) {
      final List<int> bytes = utf8.encode('${jsonEncode(reply)}\n');
      for (var i = 0; i < bytes.length; i += 3) {
        stdout.add(bytes.sublist(i, i + 3 > bytes.length ? bytes.length : i + 3));
        await stdout.flush();
      }
      return;
    }
    _write(reply);
  } finally {
    _cancels.remove(id);
    _active--;
    _activePerPackage[key] = _activePerPackage[key]! - 1;
  }
}

Map<String, Object?> _searchReply(String id, String? pkg, Map<String, Object?> payload) {
  final handle = 'h$pid-${++_handleCounter}';
  _issuedHandles.add(handle);
  final source = payload['source']! as Map<String, Object?>;
  return _res(
    id,
    ok: <String, Object?>{
      'hits': <Object?>[
        <String, Object?>{
          'ref': <String, Object?>{
            'source': source,
            'mangaId': 'manga-for-${payload['query']}',
            'settingsRevision': payload['settingsRevision'],
            'context': <String, Object?>{'url': '/manga/${payload['query']}'},
          },
          'title': 'Result for ${payload['query']}',
          'handle': handle,
        },
      ],
      'nextCursor': null,
    },
  );
}

Map<String, Object?> _detailsReply(String id, String? pkg, Map<String, Object?> payload) {
  final handle = payload['handle'] as String?;
  if (handle != null && !_issuedHandles.contains(handle)) {
    return _res(id, errCode: 'stale-reference', errMessage: 'handle $handle was not issued by worker $pid');
  }
  final ref = payload['ref']! as Map<String, Object?>;
  return _res(
    id,
    ok: <String, Object?>{
      'metadata': <String, Object?>{'title': 'Details of ${ref['mangaId']}'},
      'chapters': <Object?>[
        <String, Object?>{'chapterId': 'c1', 'sourceOrder': 0, 'chapterNumber': 1},
      ],
      'servedByPid': pid,
    },
  );
}

/// Answers a held `host.browser.request` while a reverse call is in flight
/// (the orphan rule needs an originating request).
void _onEvent(Map<String, Object?> frame) {
  if (!args.contains('--respond-requests') || frame['op'] != 'host.browser.request') return;
  final payload = frame['payload']! as Map<String, Object?>;
  final Object? requestId = payload['requestId'];
  if (requestId == null || _inFlightReverse.isEmpty) return;
  final rid = 'r${++_reverseCounter}';
  _reverse[rid] = Completer<Map<String, Object?>>();
  _write(<String, Object?>{
    'v': 1,
    't': 'rreq',
    'id': rid,
    'gen': _gen,
    'op': 'host.browser.respond',
    'of': _inFlightReverse.last,
    'payload': <String, Object?>{
      'session': payload['session'],
      'requestId': requestId,
      'response': <String, Object?>{'status': 200, 'bodyBase64': base64Encode(utf8.encode('from worker'))},
    },
  });
}
