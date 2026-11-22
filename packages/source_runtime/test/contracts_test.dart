import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

const ArtifactBinding _artifact = ArtifactBinding(sha256: 'abc', kind: 'jar', version: '1.4.2');

void main() {
  group('Int64Id', () {
    test('keeps values beyond 2^53 exact through JSON', () {
      const max = '9223372036854775807';
      const min = '-9223372036854775808';
      for (final value in <String>[max, min, '9007199254740993']) {
        final Object? decoded = jsonDecode(jsonEncode(<String, Object?>{'id': Int64Id.parse(value)}));
        check(Int64Id.fromJson((decoded! as Map<String, Object?>)['id']).decimal).equals(value);
      }
    });

    test('rejects JSON numbers, out-of-range and non-canonical values', () {
      // ignore: avoid_js_rounded_ints
      check(() => Int64Id.fromJson(9007199254740993)).throws<FormatException>();
      check(() => Int64Id.parse('9223372036854775808')).throws<FormatException>();
      check(() => Int64Id.parse('007')).throws<FormatException>();
      check(() => Int64Id.parse('-0')).throws<FormatException>();
      check(() => Int64Id.parse('1e3')).throws<FormatException>();
    });
  });

  group('NativeMangaRef', () {
    final source = SourceIdentity(
      ecosystem: 'tachi',
      packageId: 'eu.kanade.tachiyomi.extension.en.example',
      sourceId: Int64Id.parse('6247824327199706550').decimal,
      artifact: _artifact,
    );

    test('serialises durably without its ephemeral handle', () {
      final ref = NativeMangaRef(
        source: source,
        mangaId: '/manga/onimai',
        settingsRevision: 'rev',
        context: const <String, Object?>{'url': '/manga/onimai', 'initialized': true},
        handle: const SessionHandle(generation: 3, value: 'h1'),
      );
      final String json = jsonEncode(ref.toJson());
      check(json).not((Subject<String> it) => it.contains('h1'));
      final back = NativeMangaRef.fromJson(jsonDecode(json) as Map<String, Object?>);
      check(back.source).equals(source);
      check(back.source.sourceId).equals('6247824327199706550');
      check(back.context).deepEquals(<String, Object?>{'url': '/manga/onimai', 'initialized': true});
      check(back.handle).isNull();
    });

    test('rejects a numeric source ID in JSON', () {
      // ignore: avoid_js_rounded_ints
      final Map<String, Object?> json = source.toJson()..['sourceId'] = 6247824327199706550;
      check(() => SourceIdentity.fromJson(json)).throws<FormatException>();
    });
  });

  group('SettingsSnapshot', () {
    test('revision ignores secret values but tracks secret names', () {
      final a = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en'},
        secrets: const <String, String>{'password': 'one'},
      );
      final reentered = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en'},
        secrets: const <String, String>{'password': 'two'},
      );
      final noSecret = SettingsSnapshot(values: const <String, Object>{'lang': 'en'});
      final changed = SettingsSnapshot(
        values: const <String, Object>{'lang': 'fr'},
        secrets: const <String, String>{'password': 'one'},
      );
      check(reentered.revision).equals(a.revision);
      check(noSecret.revision).not((Subject<String> it) => it.equals(a.revision));
      check(changed.revision).not((Subject<String> it) => it.equals(a.revision));
      check(jsonEncode(a.toJson())).not((Subject<String> it) => it.contains('one'));
    });

    test('values under secret-like keys stay out of the revision and toJson but are redacted (L4)', () {
      final a = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en', 'apiToken': 'hunter2', 'showAuthor': true},
        sources: <String, SourceScopedSettings>{
          's1': SourceScopedSettings(values: const <String, Object>{'Session_Cookie': 'c=1', 'Password': 'pw'}),
        },
      );
      final b = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en', 'apiToken': 'other', 'showAuthor': true},
        sources: <String, SourceScopedSettings>{
          's1': SourceScopedSettings(values: const <String, Object>{'Session_Cookie': 'c=2', 'Password': 'pw2'}),
        },
      );
      // The digest is over key names only, so it is neither a hash of the
      // secret nor changed when the secret is re-entered.
      check(b.revision).equals(a.revision);
      check(
        SettingsSnapshot(values: const <String, Object>{'lang': 'en', 'showAuthor': true}).revision,
      ).not((Subject<String> it) => it.equals(a.revision));
      final String json = jsonEncode(a.toJson());
      for (final secret in <String>['hunter2', 'c=1', '"pw"']) {
        check(json).not((Subject<String> it) => it.contains(secret));
      }
      check(a.toJson()['secretKeys']).isA<List<String>>().deepEquals(<String>['apiToken']);
      check(a.toJson()['values'])
          .isA<Map<String, Object>>()
          .deepEquals(<String, Object>{'lang': 'en', 'showAuthor': true});
      check(a.allSecretValues.toSet()).deepEquals(<String>{'hunter2', 'c=1', 'pw'});
      // Delivery is unchanged: the source still reads the value.
      check(a.valuesFor('s1')['Password']).equals('pw');
      // `author` is not a credential; bools and ints are never redacted.
      check(isSecretLikeSettingKey('showAuthor')).isFalse();
      check(isSecretLikeSettingKey('authKey')).isTrue();
      for (final key in <String>['Authorization', 'authorized', 'authorisation', 'AUTH_TOKEN', 'passcode']) {
        check(because: key, isSecretLikeSettingKey(key)).isTrue();
      }
      for (final key in <String>['authors', 'authorName', 'lang', 'compassDirection']) {
        check(because: key, isSecretLikeSettingKey(key)).equals(key == 'compassDirection');
      }
      check(
        SettingsSnapshot(values: const <String, Object>{'useAuth': true, 'tokenTtl': 3}).allSecretValues,
      ).isEmpty();
    });

    test('revision covers only allowlisted non-secret keys', () {
      final a = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en', 'lastSync': '1'},
        revisionAllowlist: const <String>{'lang'},
      );
      final b = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en', 'lastSync': '2'},
        revisionAllowlist: const <String>{'lang'},
      );
      check(b.revision).equals(a.revision);
    });

    test('typing values keeps the digest of a string-only snapshot', () {
      // Pinned before values became typed; a change here reopens every
      // confirmation made under string settings.
      final snapshot = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en', 'quality': 'high'},
        secrets: const <String, String>{'password': 'x'},
      );
      check(snapshot.revision).equals('248d0ee3793ac7c3b9d25e6b5d444ae3930a3d33e99183323828df475b71013e');
    });

    test('bool and int values are typed: true, "true" and 1 are distinct revisions', () {
      final String asBool = SettingsSnapshot(values: const <String, Object>{'nsfw': true}).revision;
      final String asString = SettingsSnapshot(values: const <String, Object>{'nsfw': 'true'}).revision;
      final String asInt = SettingsSnapshot(values: const <String, Object>{'nsfw': 1}).revision;
      check(<String>{asBool, asString, asInt}).length.equals(3);
    });

    test('values round-trip their JSON types and reject other types', () {
      final snapshot = SettingsSnapshot(values: const <String, Object>{'lang': 'en', 'nsfw': false, 'pageSize': 20});
      final decoded = jsonDecode(jsonEncode(snapshot.toJson())) as Map<String, Object?>;
      final Map<String, Object> values = SettingsSnapshot.valuesFromJson(decoded['values']! as Map<String, Object?>);
      check(values).deepEquals(<String, Object>{'lang': 'en', 'nsfw': false, 'pageSize': 20});
      check(SettingsSnapshot(values: values).revision).equals(snapshot.revision);
      check(() => SettingsSnapshot(values: const <String, Object>{'ratio': 1.5})).throws<FormatException>();
      check(() => SettingsSnapshot(values: const <String, Object>{'big': 9007199254740992})).throws<FormatException>();
      check(() => SettingsSnapshot.valuesFromJson(const <String, Object?>{'x': null})).throws<FormatException>();
      check(
        () => SettingsSnapshot.valuesFromJson(const <String, Object?>{
          'x': <Object?>['a', 1],
        }),
      ).throws<FormatException>();
      check(
        () => SettingsSnapshot.valuesFromJson(const <String, Object?>{
          'x': <String, Object?>{'a': 'b'},
        }),
      ).throws<FormatException>();
    });

    test('string sets are sorted and deduplicated, so equal sets share a revision', () {
      final a = SettingsSnapshot(
        values: const <String, Object>{
          'genres': <String>['romance', 'action', 'romance'],
        },
      );
      final b = SettingsSnapshot(
        values: const <String, Object>{
          'genres': <String>['action', 'romance'],
        },
      );
      final decoded = SettingsSnapshot(
        values: SettingsSnapshot.valuesFromJson(
          (jsonDecode(jsonEncode(a.toJson())) as Map<String, Object?>)['values']! as Map<String, Object?>,
        ),
      );
      check(a.values['genres']).isA<List<String>>().deepEquals(<String>['action', 'romance']);
      check(b.revision).equals(a.revision);
      check(decoded.revision).equals(a.revision);
      // A set is not the same setting as a string or a different set.
      check(
        SettingsSnapshot(values: const <String, Object>{'genres': 'action'}).revision,
      ).not((Subject<String> it) => it.equals(a.revision));
      check(
        SettingsSnapshot(
          values: const <String, Object>{
            'genres': <String>['action'],
          },
        ).revision,
      ).not((Subject<String> it) => it.equals(a.revision));
      check(a.needsProtocol11).isTrue();
      check(SettingsSnapshot(values: const <String, Object>{'lang': 'en'}).needsProtocol11).isFalse();
    });

    test('a string set digest is pinned', () {
      // Pinned when string sets were added; a change here reopens every
      // confirmation made under them.
      final snapshot = SettingsSnapshot(
        values: const <String, Object>{
          'lang': 'en',
          'genres': <String>['b', 'a'],
        },
      );
      check(snapshot.revision).equals(
        sha256
            .convert(
              utf8.encode(
                '{"values":[["genres",["a","b"]],["lang","en"]],"secretKeys":[]}',
              ),
            )
            .toString(),
      );
    });

    test('source scopes address one source of a multi-source package', () {
      final scoped = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en', 'nsfw': false},
        secrets: const <String, String>{'token': 'pkg'},
        sources: <String, SourceScopedSettings>{
          '123': SourceScopedSettings(
            values: const <String, Object>{'lang': 'ja'},
            secrets: const <String, String>{'token': 'src'},
          ),
          '456': SourceScopedSettings(),
        },
      );
      check(scoped.sources.keys).deepEquals(<String>['123']);
      check(scoped.valuesFor('123')).deepEquals(<String, Object>{'lang': 'ja', 'nsfw': false});
      check(scoped.valuesFor('999')).deepEquals(<String, Object>{'lang': 'en', 'nsfw': false});
      check(scoped.secretsFor('123')).deepEquals(<String, String>{'token': 'src'});
      check(scoped.allSecretValues.toSet()).deepEquals(<String>{'pkg', 'src'});
      check(scoped.needsProtocol11).isTrue();
      final String json = jsonEncode(scoped.toJson());
      check(json).not((Subject<String> it) => it.contains('src'));
      check(json).not((Subject<String> it) => it.contains('pkg'));

      final unscoped = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en', 'nsfw': false},
        secrets: const <String, String>{'token': 'pkg'},
      );
      check(scoped.revision).not((Subject<String> it) => it.equals(unscoped.revision));
      // An empty scope changes nothing, so the digest of unscoped settings is
      // the one they had before scopes existed.
      check(
        SettingsSnapshot(
          values: const <String, Object>{'lang': 'en', 'nsfw': false},
          secrets: const <String, String>{'token': 'pkg'},
          sources: <String, SourceScopedSettings>{'456': SourceScopedSettings()},
        ).revision,
      ).equals(unscoped.revision);
      // Scope order does not matter; re-entered scoped secrets keep the revision.
      final reordered = SettingsSnapshot(
        values: const <String, Object>{'nsfw': false, 'lang': 'en'},
        secrets: const <String, String>{'token': 'other'},
        sources: <String, SourceScopedSettings>{
          '123': SourceScopedSettings(
            values: const <String, Object>{'lang': 'ja'},
            secrets: const <String, String>{'token': 'changed'},
          ),
        },
      );
      check(reordered.revision).equals(scoped.revision);
      // The same value scoped to another source is a different revision.
      final otherSource = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en', 'nsfw': false},
        secrets: const <String, String>{'token': 'pkg'},
        sources: <String, SourceScopedSettings>{
          '124': SourceScopedSettings(
            values: const <String, Object>{'lang': 'ja'},
            secrets: const <String, String>{'token': 'src'},
          ),
        },
      );
      check(otherSource.revision).not((Subject<String> it) => it.equals(scoped.revision));
    });

    test('the revision allowlist applies inside source scopes', () {
      SettingsSnapshot build(String volatile) => SettingsSnapshot(
        values: const <String, Object>{'lang': 'en'},
        sources: <String, SourceScopedSettings>{
          '1': SourceScopedSettings(values: <String, Object>{'lang': 'ja', 'lastSync': volatile}),
        },
        revisionAllowlist: const <String>{'lang'},
      );
      check(build('a').revision).equals(build('b').revision);
    });
  });

  group('ArtifactTrustAnchor', () {
    test('normalises certificate fingerprints and rejects anything else', () {
      final anchor = ArtifactTrustAnchor(
        signerFingerprints: const <String>[
          '9A:DD:65:5A:78:E9:6C:4E:C7:A5:3E:F8:9D:CC:B5:57:CB:5D:76:74:89:FA:C5:E7:85:D6:71:A5:A7:5D:4D:A2',
          '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
        ],
      );
      check(anchor.signerFingerprints).deepEquals(<String>{
        '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2',
      });
      for (final bad in <String>['', 'abc', '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4dzz']) {
        check(() => ArtifactTrustAnchor(signerFingerprints: <String>[bad])).throws<FormatException>();
      }
    });
  });

  group('outcomes and capabilities', () {
    test('an empty success is distinct from a failure', () {
      const SourceOutcome<SearchPage> empty = SourceSuccess<SearchPage>(SearchPage(hits: <SearchHit>[]));
      check(empty.isSuccess).isTrue();
      check(empty.valueOrNull!.hits).isEmpty();
      const SourceOutcome<SearchPage> failed = SourceFailed<SearchPage>(TimeoutFailure('slow'));
      check(failed.isSuccess).isFalse();
      check(failed.valueOrNull).isNull();
    });

    test('wire codes round-trip, and capability failures name the operation', () {
      final failures = <SourceFailure>[
        const TimeoutFailure('m'),
        const CancelledFailure('m'),
        const UnsupportedApiFailure('m'),
        const InteractionRequiredFailure('m'),
        const StaleReferenceFailure('m'),
        const ArtifactIncompatibleFailure('m'),
        const WorkerRestartedFailure('m'),
        const SourceErrorFailure('m'),
        const CapabilityUnavailableFailure('search', 'm'),
        const ProtocolViolationFailure('m'),
        const RuntimeUnavailableFailure('m'),
      ];
      for (final f in failures) {
        final Map<String, Object?> wire = f.toWire();
        final back = SourceFailure.fromWire(
          wire['code']! as String,
          wire['message']! as String,
          operation: wire['operation'] as String?,
        );
        check(back.runtimeType).equals(f.runtimeType);
      }
      final caps = SourceCapabilities(operations: const <SourceOperation>{SourceOperation.search});
      check(caps.unavailable(SourceOperation.mangaDetails).operation).equals('mangaDetails');
    });
  });

  group('BrowserUrlPolicy', () {
    test('allows only http, https and about:blank for navigation', () {
      for (final ok in <String>['https://a.example/', 'http://a.example/x?y=1', 'about:blank']) {
        check(BrowserUrlPolicy.isNavigable(Uri.parse(ok))).isTrue();
      }
      for (final bad in <String>[
        'file:///etc/passwd',
        'about:config',
        'about:blank?x=1',
        'content://x/y',
        'data:text/html,x',
        'javascript:alert(1)',
        'https:///no-host',
      ]) {
        check(because: bad, BrowserUrlPolicy.isNavigable(Uri.parse(bad))).isFalse();
      }
    });

    test('allows only http(s) base URLs', () {
      check(BrowserUrlPolicy.isAllowedBaseUrl(Uri.parse('https://a.example/'))).isTrue();
      check(BrowserUrlPolicy.isAllowedBaseUrl(Uri.parse('about:blank'))).isFalse();
      check(BrowserUrlPolicy.isAllowedBaseUrl(Uri.parse('file:///tmp/'))).isFalse();
    });
  });

  test('the contract library never reaches dart:io or subprocess code (web-safe)', () {
    final lib = Directory(
      File(p.join('lib', 'source_contracts.dart')).existsSync() ? 'lib' : p.join('packages', 'source_runtime', 'lib'),
    );
    final visited = <String>{};
    final pending = <String>[p.join(lib.path, 'source_contracts.dart')];
    final forbidden = RegExp(r'''import\s+['"](dart:io|dart:ffi|dart:isolate|package:http/)''');
    final local = RegExp(r'''(?:import|export)\s+['"](?:package:source_runtime/)?([^'":]+\.dart)['"]''');
    while (pending.isNotEmpty) {
      final String path = p.normalize(pending.removeLast());
      if (!visited.add(path)) continue;
      final String text = File(path).readAsStringSync();
      check(because: '$path must stay web-safe', forbidden.hasMatch(text)).isFalse();
      for (final RegExpMatch m in local.allMatches(text)) {
        final String target = m[0]!.contains('package:source_runtime/')
            ? p.join(lib.path, m[1])
            : p.join(p.dirname(path), m[1]);
        pending.add(target);
      }
    }
    check(visited.length).isGreaterThan(4);
  });
}
