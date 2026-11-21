import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Hand-built `.aix` packages for host-boundary tests (desktop and device).
///
/// Each module is a few dozen bytes of WASM with no fixture or network
/// dependency, so failure paths and host semantics can be exercised on any
/// platform the Aidoku host runs on.
abstract final class SyntheticAix {
  /// `get_search_manga_list` executes `unreachable`; `start` succeeds.
  static Uint8List trapInSearch() => _package('test.trap-search', _trapModule(trapInStart: false));

  /// `start` executes `unreachable`, which kills the WASM isolate.
  static Uint8List trapInStart() => _package('test.trap-start', _trapModule(trapInStart: true));

  /// URL requested by [headerProbe].
  static const String probeUrl = 'https://probe.invalid/headers';

  /// Response header [headerProbe] reads back, in the case the source uses.
  static const String probeHeader = 'x-probe';

  /// Rate limit [headerProbe] declares in `start`: [probePermits] requests
  /// per [probePeriodSeconds] seconds.
  static const int probePermits = 2;
  static const int probePeriodSeconds = 1;

  /// `start` calls `net::set_rate_limit(probePermits, probePeriodSeconds,
  /// seconds)`. Each `get_search_manga_list` sends one GET to [probeUrl],
  /// reads response header [probeHeader] with `net::get_header`, and prints
  /// its value through `env::print` (the host logs it as
  /// `[aidoku] <value>`); it returns no results.
  static Uint8List headerProbe() => _package('test.header-probe', _probeModule());
}

Uint8List _package(String id, Uint8List wasm) {
  final List<int> source = utf8.encode(
    jsonEncode(<String, Object?>{
      'info': <String, Object?>{
        'id': id,
        'name': id,
        'version': 1,
        'languages': <String>['en'],
      },
    }),
  );
  final archive = Archive()
    ..addFile(ArchiveFile('Payload/source.json', source.length, source))
    ..addFile(ArchiveFile('Payload/main.wasm', wasm.length, wasm));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

// --- WASM encoding (values here are all below 64, or encoded explicitly) ---

const List<int> _header = <int>[0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
const int _i32 = 0x7f;

List<int> _u(int value) {
  var v = value;
  final out = <int>[];
  do {
    int b = v & 0x7f;
    v >>= 7;
    if (v != 0) b |= 0x80;
    out.add(b);
  } while (v != 0);
  return out;
}

/// Signed LEB128 for non-negative values.
List<int> _s(int value) {
  var v = value;
  final out = <int>[];
  while (true) {
    final int b = v & 0x7f;
    v >>= 7;
    if (v == 0 && (b & 0x40) == 0) {
      out.add(b);
      return out;
    }
    out.add(b | 0x80);
  }
}

List<int> _section(int id, List<int> body) => <int>[id, ..._u(body.length), ...body];
List<int> _name(String s) => <int>[..._u(s.length), ...ascii.encode(s)];
List<int> _vec(List<List<int>> items) => <int>[..._u(items.length), for (final List<int> i in items) ...i];
List<int> _type(List<int> params, List<int> results) => <int>[
  0x60,
  ..._vec(<List<int>>[
    for (final int p in params) <int>[p],
  ]),
  ..._vec(<List<int>>[
    for (final int r in results) <int>[r],
  ]),
];
List<int> _body(List<int> locals, List<int> code) {
  final b = <int>[...locals, ...code, 0x0b];
  return <int>[..._u(b.length), ...b];
}

List<int> _i32Const(int v) => <int>[0x41, ..._s(v)];
List<int> _call(int f) => <int>[0x10, ..._u(f)];

Uint8List _trapModule({required bool trapInStart}) {
  const unreachable = <int>[0x00];
  return Uint8List.fromList(<int>[
    ..._header,
    ..._section(
      1,
      _vec(<List<int>>[
        _type(<int>[], <int>[]),
        _type(<int>[_i32, _i32, _i32], <int>[_i32]),
      ]),
    ),
    ..._section(
      3,
      _vec(<List<int>>[
        <int>[0],
        <int>[1],
      ]),
    ),
    ..._section(
      5,
      _vec(<List<int>>[
        <int>[0x00, 0x01],
      ]),
    ),
    ..._section(
      7,
      _vec(<List<int>>[
        <int>[..._name('start'), 0x00, 0x00],
        <int>[..._name('get_search_manga_list'), 0x00, 0x01],
        <int>[..._name('memory'), 0x02, 0x00],
      ]),
    ),
    ..._section(
      10,
      _vec(<List<int>>[
        _body(<int>[0x00], trapInStart ? unreachable : <int>[]),
        _body(<int>[0x00], unreachable),
      ]),
    ),
  ]);
}

Uint8List _probeModule() {
  const urlAt = 16;
  const keyAt = 128;
  const outAt = 256;
  final List<int> url = ascii.encode(SyntheticAix.probeUrl);
  final List<int> key = ascii.encode(SyntheticAix.probeHeader);
  // Types.
  const tVoid = 0; // () -> ()
  const t3to1 = 1; // (i32, i32, i32) -> i32
  const t1to1 = 2; // (i32) -> i32
  const t2to0 = 3; // (i32, i32) -> ()
  const t3to0 = 4; // (i32, i32, i32) -> ()
  // Imported function indices, in import order.
  const setRateLimit = 0;
  const init = 1;
  const setUrl = 2;
  const send = 3;
  const getHeader = 4;
  const bufferLen = 5;
  const readBuffer = 6;
  const print = 7;
  List<int> imp(String module, String name, int type) => <int>[..._name(module), ..._name(name), 0x00, ..._u(type)];
  const localGet = 0x20;
  const localSet = 0x21;
  const drop = 0x1a;
  return Uint8List.fromList(<int>[
    ..._header,
    ..._section(
      1,
      _vec(<List<int>>[
        _type(<int>[], <int>[]),
        _type(<int>[_i32, _i32, _i32], <int>[_i32]),
        _type(<int>[_i32], <int>[_i32]),
        _type(<int>[_i32, _i32], <int>[]),
        _type(<int>[_i32, _i32, _i32], <int>[]),
      ]),
    ),
    ..._section(
      2,
      _vec(<List<int>>[
        imp('net', 'set_rate_limit', t3to0),
        imp('net', 'init', t1to1),
        imp('net', 'set_url', t3to1),
        imp('net', 'send', t1to1),
        imp('net', 'get_header', t3to1),
        imp('std', 'buffer_len', t1to1),
        imp('std', 'read_buffer', t3to1),
        imp('env', 'print', t2to0),
      ]),
    ),
    ..._section(
      3,
      _vec(<List<int>>[
        <int>[tVoid],
        <int>[t3to1],
      ]),
    ),
    ..._section(
      5,
      _vec(<List<int>>[
        <int>[0x00, 0x01],
      ]),
    ),
    ..._section(
      7,
      _vec(<List<int>>[
        <int>[..._name('start'), 0x00, ..._u(8)],
        <int>[..._name('get_search_manga_list'), 0x00, ..._u(9)],
        <int>[..._name('memory'), 0x02, 0x00],
      ]),
    ),
    ..._section(
      10,
      _vec(<List<int>>[
        // start: set_rate_limit(permits, period, unit 0 = seconds).
        _body(
          <int>[0x00],
          <int>[
            ..._i32Const(SyntheticAix.probePermits),
            ..._i32Const(SyntheticAix.probePeriodSeconds),
            ..._i32Const(0),
            ..._call(setRateLimit),
          ],
        ),
        // get_search_manga_list: locals 0 = request, 1 = header value.
        _body(
          <int>[0x01, 0x02, _i32],
          <int>[
            ..._i32Const(0),
            ..._call(init),
            localSet,
            0x00,
            localGet,
            0x00,
            ..._i32Const(urlAt),
            ..._i32Const(url.length),
            ..._call(setUrl),
            drop,
            localGet,
            0x00,
            ..._call(send),
            drop,
            localGet,
            0x00,
            ..._i32Const(keyAt),
            ..._i32Const(key.length),
            ..._call(getHeader),
            localSet,
            0x01,
            localGet,
            0x01,
            ..._i32Const(outAt),
            localGet,
            0x01,
            ..._call(bufferLen),
            ..._call(readBuffer),
            drop,
            ..._i32Const(outAt),
            localGet,
            0x01,
            ..._call(bufferLen),
            ..._call(print),
            ..._i32Const(0),
          ],
        ),
      ]),
    ),
    ..._section(
      11,
      _vec(<List<int>>[
        <int>[0x00, ..._i32Const(urlAt), 0x0b, ..._u(url.length), ...url],
        <int>[0x00, ..._i32Const(keyAt), 0x0b, ..._u(key.length), ...key],
      ]),
    ),
  ]);
}
