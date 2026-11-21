import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

void main() {
  const entry = StubExtensionEntry(id: 'pkg.ext', name: 'Ext');

  test('a settings file maps to typed values, session-only secrets and per-source scopes', () {
    final SettingsSnapshot s = UserExtensionSettings.fromJson(<String, Object?>{
      'extensions': <String, Object?>{
        'pkg.ext': <String, Object?>{
          'values': <String, Object?>{
            'q': 'hi',
            'nsfw': false,
            'n': 3,
            'langs': <Object?>['ja', 'en', 'ja'],
          },
          'secrets': <String, Object?>{'password': 'pw'},
          'sources': <String, Object?>{
            '42': <String, Object?>{
              'values': <String, Object?>{'q': 'lo'},
              'secrets': <String, Object?>{'token': 't'},
            },
          },
        },
      },
    }).snapshotFor(entry);
    check(s.values['q']).equals('hi');
    check(s.values['nsfw']).equals(false);
    check(s.values['n']).equals(3);
    check(s.values['langs']! as List<String>).deepEquals(<String>['en', 'ja']);
    check(s.valuesFor('42')['q']).equals('lo');
    check(s.secretsFor('42')).deepEquals(<String, String>{'password': 'pw', 'token': 't'});
    check(s.toJson().toString()).not((Subject<String> it) => it.contains('pw'));
  });

  test('--setting flags are typed and override the file; other extensions get empty settings', () {
    final UserExtensionSettings settings = UserExtensionSettings()
        .withFlag('pkg.ext=nsfw=true')
        .withFlag('pkg.ext=count=12')
        .withFlag('pkg.ext=url=https://a.invalid/?x=1');
    final SettingsSnapshot s = settings.snapshotFor(entry);
    check(s.values['nsfw']).equals(true);
    check(s.values['count']).equals(12);
    check(s.values['url']).equals('https://a.invalid/?x=1');
    check(settings.snapshotFor(const StubExtensionEntry(id: 'other', name: 'O')).values).isEmpty();
    check(() => UserExtensionSettings().withFlag('pkg.ext=novalue')).throws<FormatException>();
    check(() => UserExtensionSettings.fromJson(<String, Object?>{'nope': 1})).throws<FormatException>();
  });

  test("the user's values win over an ecosystem default", () {
    final SettingsSnapshot merged = withDefaults(
      SettingsSnapshot(values: const <String, Object>{'url': 'https://mine.invalid'}),
      <String, Object>{'url': 'https://repo-default.invalid', 'other': 1},
    );
    check(merged.values).deepEquals(<String, Object>{'url': 'https://mine.invalid', 'other': 1});
  });

  test('entries are matched to named runtime source IDs per ecosystem', () {
    const tachi = TachiExtensionEntry(
      id: 'eu.pkg',
      name: 'Pkg',
      repositoryUrl: 'https://r.invalid',
      versionName: '1',
      versionCode: 1,
      artifactKind: 'jar',
      sourceIds: <String>['111', '222'],
    );
    const paperback = PaperbackExtensionEntry(
      id: 'https://r.invalid/#WeebCentral',
      name: 'WC',
      sourceId: 'WeebCentral',
      version: '1',
      repository: 'https://r.invalid/',
      bundleUrl: 'https://r.invalid/WeebCentral/index.js',
      apiFamily: 'paperback-0.9',
    );
    check(entryHostsSource(tachi, '222')).isTrue();
    check(entryHostsSource(tachi, 'eu.pkg')).isFalse();
    check(entryHostsSource(paperback, 'WeebCentral')).isTrue();
    check(entryHostsSource(const StubExtensionEntry(id: 'en.src', name: 'S'), 'en.src')).isTrue();
  });
}
