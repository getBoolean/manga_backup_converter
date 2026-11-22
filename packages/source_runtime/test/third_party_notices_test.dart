import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:source_runtime/third_party_notices.dart';
import 'package:test/scaffolding.dart';

String _asset(List<Map<String, Object?>> components, Map<String, String> texts, {int format = 1}) =>
    jsonEncode(<String, Object?>{'format': format, 'components': components, 'texts': texts});

void main() {
  test('resolves each component to its full texts, shared texts stored once', () {
    final List<ThirdPartyNotice> notices = parseThirdPartyNotices(
      _asset(
        <Map<String, Object?>>[
          <String, Object?>{
            'id': 'maven:org.jsoup:jsoup:1.22.2',
            'name': 'org.jsoup:jsoup 1.22.2',
            'license': 'MIT',
            'texts': <String>['a'],
          },
          <String, Object?>{
            'id': 'crate:scraper@0.25.0',
            'name': 'scraper 0.25.0',
            'license': 'ISC',
            'texts': <String>['a', 'b'],
          },
        ],
        <String, String>{'a': 'MIT text', 'b': 'NOTICE text'},
      ),
    );
    check(notices.map((ThirdPartyNotice n) => n.id)).deepEquals(<String>[
      'maven:org.jsoup:jsoup:1.22.2',
      'crate:scraper@0.25.0',
    ]);
    check(notices[1].text).equals('MIT text\n\nNOTICE text');
    check(notices[0].license).equals('MIT');
  });

  test('rejects a component without a text or naming a missing text', () {
    check(
      () => parseThirdPartyNotices(
        _asset(<Map<String, Object?>>[
          <String, Object?>{'id': 'x', 'name': 'x', 'texts': <String>[]},
        ], const <String, String>{}),
      ),
    ).throws<FormatException>();
    check(
      () => parseThirdPartyNotices(
        _asset(<Map<String, Object?>>[
          <String, Object?>{
            'id': 'x',
            'name': 'x',
            'texts': <String>['gone'],
          },
        ], const <String, String>{}),
      ),
    ).throws<FormatException>();
    check(() => parseThirdPartyNotices(_asset(const <Map<String, Object?>>[], const <String, String>{}, format: 2)))
        .throws<FormatException>();
  });
}
