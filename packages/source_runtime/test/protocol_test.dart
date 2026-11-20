import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

Future<(List<ProtocolFrame>, List<ProtocolException>)> _decode(
  List<List<int>> chunks, {
  int maxFrameBytes = protocolMaxFrameBytes,
}) async {
  final frames = <ProtocolFrame>[];
  final errors = <ProtocolException>[];
  await Stream<List<int>>.fromIterable(chunks)
      .transform(FrameDecoder(maxFrameBytes: maxFrameBytes))
      .handleError((Object e) => errors.add(e as ProtocolException))
      .forEach(frames.add);
  return (frames, errors);
}

List<int> _line(Map<String, Object?> json) => utf8.encode('${jsonEncode(json)}\n');

Map<String, Object?> _res(String id, Map<String, Object?> ok, {int v = 1}) => <String, Object?>{
  'v': v,
  't': 'res',
  'id': id,
  'gen': 1,
  'ok': ok,
};

void main() {
  group('FrameDecoder', () {
    test('reassembles a multi-byte UTF-8 frame split at every byte boundary', () async {
      final List<int> bytes = _line(_res('1', <String, Object?>{'title': '漫画 🎌 é', 'id': '9007199254740993'}));
      for (var cut = 1; cut < bytes.length; cut++) {
        final (List<ProtocolFrame> frames, List<ProtocolException> errors) = await _decode(<List<int>>[
          bytes.sublist(0, cut),
          bytes.sublist(cut),
        ]);
        check(errors).isEmpty();
        check(frames.single.ok!['title']).equals('漫画 🎌 é');
        check(frames.single.ok!['id']).equals('9007199254740993');
      }
    });

    test('emits every frame from a single read', () async {
      final (List<ProtocolFrame> frames, _) = await _decode(<List<int>>[
        <int>[..._line(_res('1', const <String, Object?>{})), ..._line(_res('2', const <String, Object?>{}))],
      ]);
      check(frames.map((ProtocolFrame f) => f.id)).deepEquals(<String>['1', '2']);
    });

    test('tolerates CRLF line endings', () async {
      final (List<ProtocolFrame> frames, List<ProtocolException> errors) = await _decode(<List<int>>[
        utf8.encode('${jsonEncode(_res('1', const <String, Object?>{}))}\r\n'),
      ]);
      check(errors).isEmpty();
      check(frames).length.equals(1);
    });

    test('rejects an unknown protocol version', () async {
      final (_, List<ProtocolException> errors) = await _decode(<List<int>>[_line(_res('1', const {}, v: 2))]);
      check(errors.single.kind).equals(ProtocolViolationKind.unknownVersion);
    });

    test('rejects non-JSON stdout text', () async {
      final (_, List<ProtocolException> errors) = await _decode(<List<int>>[
        utf8.encode('Picked up JAVA_TOOL_OPTIONS\n'),
      ]);
      check(errors.single.kind).equals(ProtocolViolationKind.unexpectedText);
    });

    test('rejects malformed JSON and invalid UTF-8', () async {
      final (_, List<ProtocolException> errors) = await _decode(<List<int>>[
        utf8.encode('{"v":1,\n'),
        <int>[0x7B, 0xFF, 0xFE, 0x7D, 0x0A],
      ]);
      check(errors.map((ProtocolException e) => e.kind)).deepEquals(<ProtocolViolationKind>[
        ProtocolViolationKind.malformed,
        ProtocolViolationKind.malformed,
      ]);
    });

    test('rejects a frame missing required fields', () async {
      final (_, List<ProtocolException> errors) = await _decode(<List<int>>[
        _line(<String, Object?>{'v': 1, 't': 'res'}),
      ]);
      check(errors.single.kind).equals(ProtocolViolationKind.malformed);
    });

    test('fails an oversized frame while buffering, before its newline arrives', () async {
      final controller = StreamController<List<int>>();
      final errors = <ProtocolException>[];
      final frames = <ProtocolFrame>[];
      final Future<void> done = controller.stream
          .transform(const FrameDecoder(maxFrameBytes: 64))
          .handleError((Object e) => errors.add(e as ProtocolException))
          .forEach(frames.add);
      controller.add(utf8.encode('{"v":1,"t":"res","id":"1","gen":1,"ok":{"blob":"${'x' * 100}'));
      await Future<void>.delayed(Duration.zero);
      check(errors.single.kind).equals(ProtocolViolationKind.oversized);
      // The rest of the oversized frame is discarded; the next frame decodes.
      controller
        ..add(utf8.encode('"}}\n'))
        ..add(_line(_res('2', const <String, Object?>{})));
      await controller.close();
      await done;
      check(frames.map((ProtocolFrame f) => f.id)).deepEquals(<String>['2']);
    });

    test('accepts a frame of exactly the limit', () async {
      final List<int> line = _line(_res('1', const <String, Object?>{}));
      final (List<ProtocolFrame> frames, List<ProtocolException> errors) = await _decode(<List<int>>[
        line,
      ], maxFrameBytes: line.length - 1);
      check(errors).isEmpty();
      check(frames).length.equals(1);
    });
  });

  group('encodeFrame', () {
    test('round-trips through the decoder with the newline terminator', () async {
      final Uint8List bytes = encodeFrame(
        const ProtocolFrame(
          type: FrameType.reverseRequest,
          id: 'r1',
          generation: 3,
          op: 'host.browser.load',
          originId: '3-7',
          payload: <String, Object?>{'url': 'https://example.org/'},
        ),
      );
      check(bytes.last).equals(0x0A);
      final (List<ProtocolFrame> frames, _) = await _decode(<List<int>>[bytes]);
      final ProtocolFrame f = frames.single;
      check(f.type).equals(FrameType.reverseRequest);
      check(f.originId).equals('3-7');
      check(f.generation).equals(3);
    });

    test('fails visibly above the limit instead of truncating', () {
      check(
            () => encodeFrame(
              ProtocolFrame(
                type: FrameType.request,
                id: '1',
                generation: 1,
                op: 'echo',
                payload: <String, Object?>{'blob': 'x' * 200},
              ),
              maxFrameBytes: 100,
            ),
          )
          .throws<ProtocolException>()
          .has((ProtocolException e) => e.kind, 'kind')
          .equals(ProtocolViolationKind.oversized);
    });

    test('the default limit is 16 MiB', () {
      check(protocolMaxFrameBytes).equals(16 * 1024 * 1024);
    });
  });
}
