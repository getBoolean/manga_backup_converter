// ignore_for_file: avoid_print

import 'dart:io' as io;
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:mangabackupconverter_cli/mangabackupconverter_lib.dart';
import 'package:path/path.dart' as p;

const String version = '0.1.0';

ArgParser buildParser() {
  return ArgParser()
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print this usage information.',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Show additional command output.',
    )
    ..addFlag(
      'version',
      negatable: false,
      help: 'Print the tool version.',
    )
    ..addOption(
      'backup',
      abbr: 'b',
      help:
          'A backup file from Mihon, Aidoku, Paperback, or Tachimanga to convert to the output format',
      mandatory: true,
    )
    ..addOption(
      'output-format',
      abbr: 'f',
      help: 'The output backup format the backup will be converted to',
      allowed: ['aidoku', 'tachi', 'paperback'],
      mandatory: true,
    )
    ..addOption(
      'tachi-fork',
      abbr: 't',
      help: 'The specific Tachiyomi fork to use for the backup format',
      allowed: [
        TachiFork.mihon.name,
        TachiFork.sy.name,
        TachiFork.j2k.name,
        TachiFork.yokai.name,
        TachiFork.neko.name,
      ],
      defaultsTo: TachiFork.mihon.name,
    );
}

void printUsage(ArgParser argParser) {
  print('Usage: dart mangabackupconverter_cli.dart <flags> [arguments]');
  print(argParser.usage);
}

void main(List<String> arguments) async {
  final ArgParser argParser = buildParser();
  try {
    final ArgResults results = argParser.parse(arguments);
    bool verbose = false;
    String outputFormat = 'aib';
    TachiFork outputTachiFork = TachiFork.mihon;

    if (results.wasParsed('help')) {
      printUsage(argParser);
      return;
    }
    if (results.wasParsed('version')) {
      print('mangabackupconverter_cli version: $version');
      return;
    }
    if (results.wasParsed('verbose')) {
      verbose = true;
    }

    if (verbose) {
      print('[VERBOSE] All arguments: ${results.arguments}');
    }

    final io.File backupFile;
    if (results.wasParsed('backup')) {
      backupFile = io.File(results.option('backup') ?? '');
      if (!backupFile.existsSync()) {
        print('backup file does not exist');
        return;
      }
    } else {
      print('backup file not provided');
      return;
    }

    final backupFileExtension = p.extension(backupFile.uri.toString());
    if (verbose) {
      print('Imported Backup Extension: $backupFileExtension');
    }

    if (results.wasParsed('output-format')) {
      outputFormat = results.option('output-format') ?? 'aib';
    }
    if (!['.aib', '.tachibk', '.proto.gz', '.pas4', '.tmb']
        .contains(backupFileExtension)) {
      print('Unsupported file extension: "$backupFileExtension"');
      return;
    }

    if (results.wasParsed('tachi-fork')) {
      outputTachiFork = TachiFork.values
          .byName(results.option('tachi-fork') ?? TachiFork.mihon.name);
    }

    final converter = MangaBackupConverter();

    final TachiBackup? tachiBackup = switch (backupFileExtension) {
      '.aib' => () {
          final AidokuBackup aidokuBackup = converter.importAidokuBackup(
            ByteData.sublistView(
              backupFile.readAsBytesSync(),
            ),
          );
          if (verbose) {
            print('Imported Library Manga: ${aidokuBackup.library?.length}');
            print('Imported Manga: ${aidokuBackup.manga?.length}');
            print('Imported Chapters: ${aidokuBackup.chapters?.length}');
            print('Imported Manga History: ${aidokuBackup.history?.length}');
            print(
              'Imported Tracked Manga Items: ${aidokuBackup.trackItems?.length}',
            );
            print('Imported Categories: ${aidokuBackup.categories?.length}');
            print('Imported Sources: ${aidokuBackup.sources?.length}');
            print('Aidoku Backup Name: ${aidokuBackup.name}');
            print('Aidoku Version: ${aidokuBackup.version}');
          }
          return null;
        }(),
      '.tachibk' || '.proto.gz' => () {
          final TachiBackup tachibkBackup = converter.importTachibkBackup(
            backupFile.readAsBytesSync(),
            fork: outputTachiFork,
          );
          if (verbose) {
            print(tachibkBackup);
          }
          return tachibkBackup;
        }(),
      '.pas4' => () {
          final PaperbackBackup paperbackBackup =
              converter.importPaperbackPas4Backup(
            backupFile.readAsBytesSync(),
            name: p.basenameWithoutExtension(backupFile.uri.toString()),
          );
          if (verbose) {
            print('Imported Manga Info: ${paperbackBackup.mangaInfo?.length}');
            print(
              'Imported Library Manga: ${paperbackBackup.libraryManga?.length}',
            );
            print('Imported Chapters: ${paperbackBackup.chapters?.length}');
            print(
              'Imported Chapter Progress Marker: ${paperbackBackup.chapterProgressMarker?.length}',
            );
            print(
              'Imported Source Manga: ${paperbackBackup.sourceManga?.length}',
            );
            final trackedManga = paperbackBackup.libraryManga
                ?.where((i) => i.trackedSources.isNotEmpty)
                .toList();
            print('Tracked Manga: ${trackedManga?.length}');
            final mangaWithSecondarySources = paperbackBackup.libraryManga
                ?.where((i) => i.secondarySources.isNotEmpty)
                .toList();
            print(
              'Manga with Secondary Sources: ${mangaWithSecondarySources?.length}',
            );
            final mangaTagsWithTags = paperbackBackup.mangaInfo
                ?.where(
                  (i) => i.tags.where((e) => e.tags.isNotEmpty).isNotEmpty,
                )
                .toList();
            print('Manga with Tags: ${mangaTagsWithTags?.length}');
          }

          return null;
        }(),
      '.tmb' => await () async {
          final TachimangaBackup tachimangaBackup =
              await converter.importTachimangaBackup(
            backupFile.readAsBytesSync(),
          );
          if (verbose) {
            print('Imported Manga: ${tachimangaBackup.db.mangaTable.length}');
            print(
              'Imported Chapters: ${tachimangaBackup.db.chapterTable.length}',
            );
            print(
              'Imported Manga History: ${tachimangaBackup.db.historyTable.length}',
            );
            print(
              'Imported Tracked Manga Items: ${tachimangaBackup.db.trackRecordTable.length}',
            );
            print(
              'Imported Categories: ${tachimangaBackup.db.categoryTable.length}',
            );
            print(
              'Imported Sources: ${tachimangaBackup.db.sourceTable.length}',
            );
            print('Imported Repos: ${tachimangaBackup.db.repoTable.length}');
            print('Tachimanga Backup Name: ${tachimangaBackup.name}');
            print('Tachimanga Version: ${tachimangaBackup.meta.version}');
          }

          return tachimangaBackup.toTachi();
        }(),
      _ => () {
          print('Unsupported imported backup type');
          return null;
        }(),
    };
    if (verbose) {
      print('Converted Categories: ${tachiBackup?.backupCategories.length}');
      print('Converted Manga: ${tachiBackup?.backupManga.length}');
      print('Converted Sources: ${tachiBackup?.backupSources.length}');
      print(
        'Converted Extension Repos: ${tachiBackup?.backupExtensionRepo.length}',
      );
    }

    switch (outputFormat) {
      case 'tachi':
        return;
      case 'paperback':
      // TODO: Implement Tachi to Paperback
      case 'aidoku':
      // TODO: Implement Tachi to Aidoku
      default:
        print('Unsupported output format');
        return;
    }
  } on FormatException catch (e) {
    // Print usage information if an invalid argument was provided.
    print(e.message);
    print('');
    printUsage(argParser);
  }
}
