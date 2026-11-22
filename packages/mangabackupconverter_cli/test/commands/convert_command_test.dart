// `convert` as a user runs it unattended: repositories, extension picks and
// settings come only from the user, and the direct Tachi/Tachimanga path
// runs end to end offline through the core ConversionJob.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:args/command_runner.dart';
import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/convert_command.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup.dart';
import 'package:test/scaffolding.dart';

Future<Uint8List> _mihonBackup() => const TachiBackup(
  backupManga: <TachiBackupManga>[
    TachiBackupManga(
      source: 1234,
      url: '/series/x',
      title: 'Onimai',
      artist: '',
      author: '',
      description: '',
      genre: <String>[],
      status: 0,
      thumbnailUrl: '',
      dateAdded: 0,
      viewer: 0,
      chapters: <TachiBackupChapter>[
        TachiBackupChapter(
          url: '/c1',
          name: 'Step 1',
          scanlator: '',
          read: true,
          bookmark: false,
          lastPageRead: 0,
          dateFetch: 0,
          dateUpload: 0,
          chapterNumber: 1,
          sourceOrder: 0,
        ),
      ],
      categories: <int>[],
      tracking: <TachiBackupTracking>[],
      favorite: true,
      chapterFlags: 0,
      viewerFlags: 0,
      history: <TachiBackupHistory>[],
    ),
  ],
).toData();

void main() {
  late Directory temp;
  late File input;

  setUp(() async {
    temp = Directory.systemTemp.createTempSync('u7_convert_');
    input = File('${temp.path}/library.tachibk')..writeAsBytesSync(await _mihonBackup());
  });
  tearDown(() => temp.deleteSync(recursive: true));

  Future<void> run(List<String> args) =>
      (CommandRunner<void>('test', 'test')..addCommand(ConvertCommand())).run(<String>['convert', ...args]);

  Future<String> usageError(List<String> args) async {
    try {
      await run(args);
    } on UsageException catch (e) {
      return e.message;
    }
    throw StateError('expected a usage error');
  }

  test('unattended migration has no built-in repository: --repos is required', () async {
    check(await usageError(<String>['-b', input.path, '-f', 'aidoku', '-e', 'some.extension']))
        .contains('--repos is required');
  });

  test('unattended migration never auto-picks an extension: --extensions or --sources is required', () async {
    check(await usageError(<String>['-b', input.path, '-f', 'aidoku', '-r', 'https://repo.invalid/index.json']))
        .contains('--extensions or --sources');
  });

  test('malformed extension settings are a usage error', () async {
    final settings = File('${temp.path}/settings.json')..writeAsStringSync('{"extensions": {"x": {"values": 3}}}');
    check(
      await usageError(<String>[
        '-b', input.path, '-f', 'aidoku', '-r', 'https://repo.invalid', '-e', 'x', //
        '--settings', settings.path,
      ]),
    ).contains('Invalid extension settings');
    check(
      await usageError(<String>[
        '-b', input.path, '-f', 'aidoku', '-r', 'https://repo.invalid', '-e', 'x', //
        '--setting', 'no-key-or-value',
      ]),
    ).contains('EXTENSION_ID=KEY=VALUE');
  });

  test('an unverified Tachi fork is not a direct-conversion target', () async {
    final tmb = File('${temp.path}/in.tmb')..writeAsBytesSync(<int>[0]);
    check(await usageError(<String>['-b', tmb.path, '-f', 'sy'])).contains('not an allowed value');
  });

  test('Mihon → Tachimanga converts directly and publishes a re-readable backup; an existing file is replaced '
      'only by a complete one', () async {
    final out = File('${temp.path}/out.tmb')..writeAsBytesSync(<int>[1, 2, 3]);
    await run(<String>['-b', input.path, '-f', 'tachimanga', '-o', out.path]);
    final TachimangaBackup written = await TachimangaBackup.fromData(out.readAsBytesSync());
    check(written.db.mangaTable.single.url).equals('/series/x');
    check(written.db.chapterTable.single.read).isTrue();
    check(File('${temp.path}/out.journal.json').existsSync()).isFalse();
    check(temp.listSync().whereType<File>().where((File f) => f.path.endsWith('.tmp'))).isEmpty();
  });
}
