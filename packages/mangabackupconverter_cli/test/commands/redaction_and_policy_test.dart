// ignore_for_file: avoid_print

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart' show UserExtensionSettings;
import 'package:mangabackupconverter_cli/src/commands/convert_command.dart';
import 'package:mangabackupconverter_cli/src/commands/file_stores.dart';
import 'package:mangabackupconverter_cli/src/commands/redacting_log.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('CLI log redaction (KTD9)', () {
    test('seeded cookies, tokens and passwords never reach the log file', () async {
      final Directory dir = await Directory.systemTemp.createTemp('mbc_log');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, 'convert.log'));
      final IOSink sink = file.openWrite();
      final log = RedactingLog(sink)
        ..addSecrets(
          SettingsSnapshot(
            values: const <String, Object>{'lang': 'en'},
            secrets: const <String, String>{'password': 'correct horse', 'token': 'tok_5ecret'},
          ),
        );

      // Zone-captured prints, as convert_command installs them.
      runZoned(
        () {
          print('Cookie: cf_clearance=abc123; session=xyz');
          print('GET https://user:pa55@api.example/search?q=a&access_token=tok_5ecret');
          print('login failed for password correct horse');
          print('Authorization: Bearer eyJhbGciOi');
        },
        zoneSpecification: ZoneSpecification(print: (_, _, _, String line) => log.writeln(line)),
      );
      // Worker stderr, split mid-secret across chunks.
      final RedactingLineSink stderrSink = log.lineSink()
        ..add(utf8.encode('[jvm] Set-Cookie: sid=deadbeef\n[jvm] using tok_5e'))
        ..add(utf8.encode('cret now\n'));
      stderrSink.close();

      log.unmount();
      await sink.close();
      final String text = await file.readAsString();
      for (final secret in <String>['abc123', 'xyz', 'pa55', 'tok_5ecret', 'correct horse', 'eyJhbGciOi', 'deadbeef']) {
        check(text).not((it) => it.contains(secret));
      }
      check(text).contains(redactedPlaceholder);
      check(text).contains('[jvm] using');
    });
  });

  group('settings secrets registered at startup (L4)', () {
    test('every secret in the settings file is redacted before any loader opens it', () {
      final UserExtensionSettings settings = UserExtensionSettings.fromJson(const <String, Object?>{
        'extensions': <String, Object?>{
          'a': <String, Object?>{
            'values': <String, Object?>{'lang': 'en', 'authToken': 'tok_in_values'},
            'secrets': <String, Object?>{'password': 'pw_package'},
            'sources': <String, Object?>{
              's1': <String, Object?>{
                'secrets': <String, Object?>{'cookie': 'ck_scoped'},
              },
            },
          },
        },
      }).withFlag('b=passphrase=from_flag');
      final redactor = Redactor();
      registerUserSettingSecrets(settings, redactor);
      check(
        redactor.redact('tok_in_values pw_package ck_scoped from_flag en'),
      ).equals('[REDACTED] [REDACTED] [REDACTED] [REDACTED] en');
    });
  });

  group('adult-source policy flags', () {
    test('--max-rating nsfw without --confirm-adult is a usage error', () async {
      final Directory dir = await Directory.systemTemp.createTemp('mbc_rating');
      addTearDown(() => dir.delete(recursive: true));
      final backup = File(p.join(dir.path, 'in.aib'))..writeAsBytesSync(<int>[0]);
      final runner = CommandRunner<void>('mbc', 'test')..addCommand(ConvertCommand());
      Object? error;
      try {
        await runner.run(<String>['convert', '-b', backup.path, '-f', 'aidoku', '--max-rating', 'nsfw']);
      } on Object catch (e) {
        error = e;
      }
      check(error).isA<UsageException>().has((UsageException e) => e.message, 'message').contains('--confirm-adult');
    });
  });

  group('atomic output', () {
    test('publishing replaces the target only with complete bytes and leaves no temporary file', () async {
      final Directory dir = await Directory.systemTemp.createTemp('mbc_out');
      addTearDown(() => dir.delete(recursive: true));
      final String target = p.join(dir.path, 'out.aib');
      File(target).writeAsStringSync('old');
      await writeFileAtomically(target, utf8.encode('new'));
      check(File(target).readAsStringSync()).equals('new');
      check(dir.listSync().map((FileSystemEntity e) => p.basename(e.path)).toList()).deepEquals(<String>['out.aib']);
    });

    test('the file journal store round-trips and clears', () async {
      final Directory dir = await Directory.systemTemp.createTemp('mbc_journal');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileJournalStore(p.join(dir.path, 'j.json'));
      check(await store.read()).isNull();
      await store.write(<String, Object?>{'version': 1});
      check(await store.read()).isNotNull().deepEquals(<String, Object?>{'version': 1});
      await store.clear();
      check(await store.read()).isNull();
    });
  });
}
