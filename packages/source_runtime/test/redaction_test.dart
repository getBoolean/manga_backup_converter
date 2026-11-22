import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('Redactor', () {
    final redactor = Redactor(secrets: <String>['s3cr3t value', 'p@ss/word']);

    test('strips cookie and authorization headers in every form', () {
      for (final (String input, String leaked) in <(String, String)>[
        ('Cookie: sid=abc; theme=dark', 'abc'),
        ('set-cookie: id=xyz; Path=/; HttpOnly', 'xyz'),
        ('Authorization: Basic dXNlcjpwYXNz', 'dXNlcjpwYXNz'),
        ('proxy-authorization=Bearer qqq', 'qqq'),
        ('headers={"Cookie":"cf=123","Accept":"*/*"}', 'cf=123'),
        (r'{"authorization": "Bearer tkn\"x"}', 'tkn'),
      ]) {
        final String out = redactor.redact(input);
        check(because: input, out).not((Subject<String> it) => it.contains(leaked));
        check(out).contains(redactedPlaceholder);
      }
      check(redactor.redact('{"Cookie":"cf=123","Accept":"*/*"}')).contains('"Accept":"*/*"');
    });

    test('strips credential URL components but keeps the rest of the URL', () {
      final String out = redactor.redact('GET https://bob:hunter2@api.example.org/v1?page=2&access_token=t0k&q=x');
      check(out).not((Subject<String> it) => it.contains('bob'));
      check(out).not((Subject<String> it) => it.contains('hunter2'));
      check(out).not((Subject<String> it) => it.contains('t0k'));
      check(out).contains('api.example.org/v1?page=2');
      check(out).contains('q=x');
    });

    test('strips registered secrets verbatim and URL-encoded', () {
      final String out = redactor.redact('login s3cr3t value / s3cr3t+value / p%40ss%2Fword / p@ss/word');
      check(out).not((Subject<String> it) => it.contains('s3cr3t'));
      check(out).not((Subject<String> it) => it.contains('p@ss'));
      check(out).not((Subject<String> it) => it.contains('p%40ss'));
    });

    test('leaves ordinary log lines untouched', () {
      const line = 'Loaded 3 sources from eu.kanade.tachiyomi.extension.en.example in 412 ms';
      check(redactor.redact(line)).equals(line);
    });
  });

  group('RedactingLineSink', () {
    test('redacts a secret split across chunks', () {
      final lines = <String>[];
      final sink = RedactingLineSink(Redactor(secrets: <String>['topsecret']), lines.add);
      final List<int> bytes = utf8.encode('pass=topsecret done\nnext line\r\ntail');
      for (var i = 0; i < bytes.length; i += 4) {
        sink.add(bytes.sublist(i, i + 4 > bytes.length ? bytes.length : i + 4));
      }
      sink.close();
      check(lines).deepEquals(<String>['pass=$redactedPlaceholder done', 'next line', 'tail']);
    });

    test('caps a line without a newline and never emits part of a straddling secret (L2)', () {
      final lines = <String>[];
      final sink = RedactingLineSink(
        Redactor(secrets: <String>['correct horse battery', 'tok_ABCDEFGH']),
        lines.add,
        maxLineBytes: 32,
      );
      // The cap (32 bytes) falls inside the first secret, and inside the
      // second on the next line: neither half may be emitted.
      sink.add(utf8.encode('${'a' * 20} correct horse battery and more and more'));
      sink.add(utf8.encode(' still the same line\n'));
      sink.add(utf8.encode('${'b' * 26}tok_ABCDEFGH tail\nshort\n'));
      sink.close();
      check(lines).deepEquals(<String>[
        '${'a' * 20}$truncatedLineMarker',
        '${'b' * 26}$truncatedLineMarker',
        'short',
      ]);
      for (final line in lines) {
        for (final part in <String>['correct', 'horse', 'tok_']) {
          check(line).not((Subject<String> it) => it.contains(part));
        }
      }
    });

    test('a line of exactly the cap is kept whole', () {
      final lines = <String>[];
      RedactingLineSink(Redactor(), lines.add, maxLineBytes: 4)
        ..add(utf8.encode('abcd\nabcde\n'))
        ..close();
      check(lines).deepEquals(<String>['abcd', 'abcd$truncatedLineMarker']);
    });
  });
}
