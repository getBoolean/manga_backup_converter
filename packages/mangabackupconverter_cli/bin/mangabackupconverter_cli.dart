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
    );
}

void printUsage(ArgParser argParser) {
  print('Usage: dart mangabackupconverter_cli.dart <flags> [arguments]');
  print(argParser.usage);
}

void main(List<String> arguments) {
  final ArgParser argParser = buildParser();
  try {
    final ArgResults results = argParser.parse(arguments);
    bool verbose = false;
    io.File? backupFile;
    String outputFormat = 'aib';

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

    if (results.wasParsed('backup')) {
      backupFile = io.File(results.option('backup') ?? '');
      if (!backupFile.existsSync()) {
        print('backup file does not exist');
        return;
      }
    }

    if (backupFile == null) {
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
    if (!['.aib', '.tachibk', '.proto.gz', '.json', '.pas4', '.tmb']
        .contains(backupFileExtension)) {
      print('Unsupported file extension: "$backupFileExtension"');
      return;
    }

    final converter = MangaBackupConverter();

    switch (backupFileExtension) {
      case '.aib':
        final AidokuBackup? aidokuBackup = converter.importAidokuBackup(
          ByteData.sublistView(
            backupFile.readAsBytesSync(),
          ),
        );
        if (verbose) {
          print('Imported Library Manga: ${aidokuBackup?.library?.length}');
          print('Imported Manga: ${aidokuBackup?.manga?.length}');
          print('Imported Chapters: ${aidokuBackup?.chapters?.length}');
          print('Imported Manga History: ${aidokuBackup?.history?.length}');
          print(
            'Imported Tracked Manga Items: ${aidokuBackup?.trackItems?.length}',
          );
          print('Imported Categories: ${aidokuBackup?.categories?.length}');
          print('Imported Sources: ${aidokuBackup?.sources?.length}');
          print('Aidoku Backup Name: ${aidokuBackup?.name}');
          print('Aidoku Version: ${aidokuBackup?.version}');
        }
      case '.tachibk':
      case '.proto.gz':
      case '.json':
        final TachibkBackup? tachibkBackup = converter.importTachibkBackup(
          ByteData.sublistView(
            backupFile.readAsBytesSync(),
          ),
        );
        if (verbose) {
          print(tachibkBackup?.data);
        }
      case '.pas4':
        final PaperbackBackup? paperbackBackup =
            converter.importPaperbackPas4Backup(
          backupFile.readAsBytesSync(),
          name: p.basenameWithoutExtension(backupFile.uri.toString()),
        );
        if (verbose && paperbackBackup != null) {
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
              ?.where((i) => i.tags.where((e) => e.tags.isNotEmpty).isNotEmpty)
              .toList();
          print('Manga with Tags: ${mangaTagsWithTags?.length}');
        }
      case '.tmb':
      // TODO: Read from SQLite file
      default:
        print('Unsupported imported backup type');
        return;
    }

    switch (outputFormat) {
      case 'aidoku':
      case 'tachi':
      case 'paperback':
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
