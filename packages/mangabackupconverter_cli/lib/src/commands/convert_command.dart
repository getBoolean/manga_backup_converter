// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:characters/characters.dart';
import 'package:collection/collection.dart';
import 'package:mangabackupconverter_cli/mangabackupconverter_lib.dart';
import 'package:mangabackupconverter_cli/src/commands/chapter_resolve_screen.dart';
import 'package:mangabackupconverter_cli/src/commands/conversion_composition.dart';
import 'package:mangabackupconverter_cli/src/commands/extension_select_screen.dart';
import 'package:mangabackupconverter_cli/src/commands/file_stores.dart';
import 'package:mangabackupconverter_cli/src/commands/format_select_screen.dart';
import 'package:mangabackupconverter_cli/src/commands/migration_dashboard.dart';
import 'package:mangabackupconverter_cli/src/commands/plugin_cache.dart';
import 'package:mangabackupconverter_cli/src/commands/redacting_log.dart';
import 'package:mangabackupconverter_cli/src/commands/terminal_ui.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart' show Redactor, SettingsSnapshot, SourceFailure;
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart' show TachiArtifactPolicy, TachiWorkerLocation;

class ConvertCommand extends Command<void> {
  /// Set by the migration pipeline; printed once the terminal is restored.
  ConversionReport? _conversionReport;

  @override
  final String name = 'convert';
  @override
  final String description = 'Convert a manga backup to another format.';

  static final List<String> _aliases = BackupFormat.values.map((BackupFormat f) => f.alias).toList();

  /// Formats with a registered writer or direct converter; whether a pair
  /// is enabled on this host is checked once the input format is known.
  static final List<BackupFormat> _outputFormats = cliFormatRegistry().outputFormats;

  ConvertCommand() {
    argParser
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Show additional command output.')
      ..addOption(
        'backup',
        abbr: 'b',
        help: 'A backup file to convert to the output format.',
      )
      ..addOption(
        'output-format',
        abbr: 'f',
        help: 'The output backup format.',
        allowed: _outputFormats.map((BackupFormat f) => f.alias).toList(),
      )
      ..addOption(
        'input-format',
        abbr: 'i',
        help: 'Specify the input backup format if not detected automatically.',
        allowed: _aliases,
      )
      ..addMultiOption(
        'repos',
        abbr: 'r',
        help: 'Extension repo URLs for plugin-based migration.',
      )
      ..addMultiOption(
        'extensions',
        abbr: 'e',
        help:
            'Extension IDs to install (e.g. multi.mangadex). '
            'Skips interactive extension selection.',
      )
      ..addOption(
        'max-rating',
        help:
            'Maximum extension content rating (safe, suggestive, nsfw). Defaults to suggestive, or nsfw '
            'with --confirm-adult; nsfw requires --confirm-adult.',
        allowed: <String>['safe', 'suggestive', 'nsfw'],
      )
      ..addFlag(
        'confirm-adult',
        negatable: false,
        help:
            'Confirm you are of legal age to view adult content. Adult (NSFW) and unrated sources '
            'are hidden from source selection without it.',
      )
      ..addOption(
        'languages',
        valueHelp: 'en,ja|all',
        help:
            'Search only sources in these languages (plus multi-language sources). Defaults to the '
            "languages found in the backup; 'all' searches every language.",
      )
      ..addFlag(
        'accept-partial',
        negatable: false,
        help:
            'Accept a partial conversion (unresolved or unrepresentable records) without asking. '
            'Without it, an unattended partial conversion writes nothing.',
      )
      ..addFlag(
        'fresh',
        negatable: false,
        help: 'Discard any conversion journal for this output and start over.',
      )
      ..addOption(
        'journal',
        help:
            'Conversion journal path, used to resume an interrupted conversion. '
            'Defaults to <output-basename>.journal.json; deleted after the output is written.',
      )
      ..addOption(
        'output',
        abbr: 'o',
        help: 'Output file path. Defaults to <input>_converted.<ext> next to the backup file.',
      )
      ..addMultiOption(
        'trust-tachi-repo',
        valueHelp: 'URL=SHA256',
        help:
            'Pre-approve a Tachi repository signing fingerprint (certificate SHA-256). Unattended runs '
            'refuse first-seen or changed fingerprints without it.',
      )
      ..addMultiOption(
        'tachi-artifact',
        valueHelp: 'jar|apk|REPO_URL=jar|apk|PACKAGE=jar|apk',
        help:
            'Force the Tachi artifact kind for every repository, one repository, or one package. '
            'Defaults to the JAR when a repository publishes one, otherwise the APK.',
      )
      ..addOption(
        'tachi-runtime',
        valueHelp: 'tachi-runtime.json',
        help: 'Tachi worker runtime manifest. Defaults to the development install (./gradlew installDist).',
      )
      ..addOption(
        'tachi-handshake-deadline-ms',
        help:
            'Deadline for the Tachi worker handshake, in milliseconds. Required unless the runtime manifest '
            'sets handshakeDeadlineMs; the worker reports every other limit itself.',
      )
      ..addOption(
        'log-file',
        abbr: 'l',
        help:
            'Log file path for verbose output in interactive mode. '
            'Defaults to <output-basename>.log next to the output file.',
      );
  }

  @override
  Future<void> run() async {
    final ArgResults results = argResults!;
    final bool verbose = results.flag('verbose');
    final bool interactive = hasTerminal;

    // Single TerminalContext for the entire interactive session — stdin's
    // broadcast subscription is killed on dispose(), so we must not create
    // multiple short-lived contexts.
    final TerminalContext? context = interactive ? TerminalContext() : null;

    // --- Backup file path ---
    String? backupPath = results.option('backup');
    if (backupPath == null) {
      if (!interactive) {
        context?.showCursor();
        context?.dispose();
        throw UsageException('--backup is required in non-interactive mode.', usage);
      }
      backupPath = await _readPath(context!, prompt: 'Backup file path: ');
      if (backupPath == null || backupPath.isEmpty) {
        context.showCursor();
        context.dispose();
        throw UsageException('No backup file path provided.', usage);
      }
    }

    final backupFile = io.File(backupPath);
    if (!backupFile.existsSync()) {
      context?.showCursor();
      context?.dispose();
      throw UsageException('Backup file does not exist: ${backupFile.path}', usage);
    }

    try {
      await _runWithContext(results, verbose, interactive, backupFile, context);
    } finally {
      context?.showCursor();
      context?.dispose();
    }
    // Printed after the terminal leaves raw mode and the loading region is
    // cleared, so multi-line output is neither erased nor stair-stepped.
    _conversionReport?.describe().forEach(print);
  }

  Future<void> _runWithContext(
    ArgResults results,
    bool verbose,
    bool interactive,
    io.File backupFile,
    TerminalContext? context,
  ) async {
    // --- Output format ---
    final String? outputFormatName = results.option('output-format');
    final BackupFormat outputFormat;
    if (outputFormatName == null) {
      if (!interactive) {
        throw UsageException('--output-format is required in non-interactive mode.', usage);
      }
      final BackupFormat? picked = await FormatSelectScreen().run(
        context: context!,
        formats: _outputFormats,
        title: 'Select output format',
      );
      if (picked == null) {
        throw UsageException('No output format selected.', usage);
      }
      outputFormat = picked;
    } else {
      outputFormat = BackupFormat.byName(outputFormatName);
    }

    // --- Input format ---
    final String backupFileExtension = p.extension(backupFile.uri.toString());

    BackupFormat? inputFormat = BackupFormat.byExtension(backupFileExtension);
    if (results.wasParsed('input-format')) {
      inputFormat = BackupFormat.byName(results.option('input-format')!);
    }

    if (inputFormat == null) {
      if (!interactive) {
        throw UsageException(
          'Unsupported file extension: "$backupFileExtension". Use --input-format to specify.',
          usage,
        );
      }
      context!.write('Could not detect format from extension "$backupFileExtension".\r\n');
      final BackupFormat? picked = await FormatSelectScreen().run(
        context: context,
        formats: BackupFormat.values,
        title: 'Select input format',
      );
      if (picked == null) {
        throw UsageException('No input format selected.', usage);
      }
      inputFormat = picked;
    }
    final BackupFormat resolvedInputFormat = inputFormat;

    List<String> repoUrls = results.multiOption('repos');

    // --- Tachi runtime options (validated up front) ---
    final Map<Uri, String> tachiPins;
    final TachiArtifactPolicy tachiPolicy;
    final Duration? tachiHandshakeDeadline;
    try {
      tachiPins = PinnedTrustStore.parsePins(results.multiOption('trust-tachi-repo'));
      tachiPolicy = parseTachiArtifactOverrides(results.multiOption('tachi-artifact'));
      tachiHandshakeDeadline = switch (results.option('tachi-handshake-deadline-ms')) {
        null => null,
        final String ms when (int.tryParse(ms) ?? 0) > 0 => Duration(milliseconds: int.parse(ms)),
        final String ms => throw FormatException('--tachi-handshake-deadline-ms must be a positive integer, got "$ms"'),
      };
    } on FormatException catch (e) {
      throw UsageException(e.message, usage);
    }

    // Adult sources stay hidden unless the user confirms their age (shared
    // core policy; the mobile hosts reuse it).
    final ratingPolicy = SourceRatingPolicy(
      adultContentConfirmed: results.flag('confirm-adult'),
      maxRating: switch (results.option('max-rating')) {
        'safe' => SourceRatingPolicy.safe,
        'suggestive' => SourceRatingPolicy.suggestive,
        'nsfw' => SourceRatingPolicy.nsfw,
        _ => null,
      },
    );
    if (ratingPolicy.requestsUnconfirmedAdult) {
      throw UsageException('--max-rating nsfw requires --confirm-adult (age confirmation).', usage);
    }
    // `null` infers the languages from the backup. Plain if/try (no
    // pattern switch into a deferred final): see the Dart 3.14 AOT note.
    SourceLanguagePolicy? languagePolicy;
    final String? languagesOption = results.option('languages');
    if (languagesOption != null) {
      try {
        languagePolicy = SourceLanguagePolicy.parse(languagesOption);
      } on FormatException catch (e) {
        throw UsageException(e.message, usage);
      }
    }

    final ConversionStrategy strategy = determineStrategy(resolvedInputFormat, outputFormat);
    var forceMigration = false;

    if (interactive) {
      if (strategy is DirectConversion) {
        context!.write(
          '${resolvedInputFormat.alias} can be converted directly to '
          '${outputFormat.alias} without plugins.\r\n'
          'Use plugin migration instead? [y/N] ',
        );
        forceMigration = await _readYesNo(context);
        context.write('\r\n');
      } else if (_isSameBackupFormat(resolvedInputFormat, outputFormat)) {
        context!.write(
          'Source (${resolvedInputFormat.alias}) and target (${outputFormat.alias}) '
          'use the same backup format. '
          'This will re-migrate all manga through plugins.\r\n'
          'Continue? [y/N] ',
        );
        if (!await _readYesNo(context)) {
          throw UsageException('Aborted.', usage);
        }
        context.write('\r\n');
      }
    }

    // --- Composition root (KTD15): formats, desktop runtimes, enablement ---
    final FormatRegistry formats = cliFormatRegistry();
    // One session redactor for every log line and user-visible error (KTD9).
    final redactor = Redactor();
    RedactingLog? activeLog;
    final tachi = DesktopTachiRuntime(
      locate: () => TachiWorkerLocation.resolve(
        manifestPath: results.option('tachi-runtime'),
        handshakeDeadline: tachiHandshakeDeadline,
        searchFrom: io.File(io.Platform.script.toFilePath()).parent,
      ),
      cacheDirectory: io.Directory(p.join(userConfigDirectory(), 'cache', 'tachi')),
      fetch: httpTachiFetch,
      policy: tachiPolicy,
      onLog: (String line) => activeLog?.writeln(line),
      redactor: redactor,
    );
    final RuntimeRegistry runtimes = cliRuntimeRegistry(
      cache: PluginCache(),
      tachi: tachi,
      cacheRoot: userConfigDirectory(),
      onSettings: (SettingsSnapshot settings) => activeLog?.addSecrets(settings),
      onLog: (String line) => activeLog?.writeln(line),
    );
    final SourceFailure? unavailable = conversionUnavailable(
      formats,
      runtimes,
      resolvedInputFormat,
      outputFormat,
      forceMigration: forceMigration,
    );
    if (unavailable != null) {
      throw UsageException(
        '${resolvedInputFormat.alias} → ${outputFormat.alias} is not available on this host: ${unavailable.message}',
        usage,
      );
    }

    // --- Repo URL prompt ---
    final bool willMigrate = strategy is Migration || forceMigration;
    if (interactive && willMigrate && repoUrls.isEmpty) {
      final required = strategy is Migration;
      final promptLabel = required ? 'Extension repo URL: ' : 'Extension repo URL (Enter to skip): ';
      String? repoInput;
      do {
        repoInput = await _readLine(context!, prompt: promptLabel);
        if (repoInput == null) {
          throw UsageException('Cancelled.', usage);
        }
        if (repoInput.isEmpty && required) {
          context.write('A repo URL is required for migration.\r\n');
        }
      } while (repoInput.isEmpty && required);
      if (repoInput.isNotEmpty) {
        repoUrls = [repoInput];
      }
    }

    // --- Output path ---
    final String defaultOutputPath = p.join(
      p.dirname(backupFile.path),
      '${p.basenameWithoutExtension(backupFile.uri.toString())}_converted'
      '${outputFormat.extensions.first}',
    );

    String outputPath;
    if (results.wasParsed('output')) {
      outputPath = results.option('output')!;
    } else if (interactive) {
      final String? customPath = await _readPath(
        context!,
        prompt: 'Output path: ',
        defaultValue: defaultOutputPath,
      );
      if (customPath == null) {
        throw UsageException('Cancelled.', usage);
      }
      outputPath = customPath;
    } else {
      outputPath = defaultOutputPath;
    }

    // If -o points to a directory, append default filename inside it.
    if (io.FileSystemEntity.isDirectorySync(outputPath) ||
        outputPath.endsWith(p.separator) ||
        outputPath.endsWith('/')) {
      outputPath = p.join(
        outputPath,
        '${p.basenameWithoutExtension(backupFile.uri.toString())}_converted${outputFormat.extensions.first}',
      );
    }

    final String logPath = results.option('log-file') ?? (interactive ? '${p.withoutExtension(outputPath)}.log' : '');
    final io.IOSink? logSink = logPath.isNotEmpty ? io.File(logPath).openWrite() : null;
    final log = RedactingLog(logSink, redactor: redactor);
    activeLog = log;
    final String journalPath = results.option('journal') ?? '${p.withoutExtension(outputPath)}.journal.json';
    final bool acceptPartial = results.flag('accept-partial');

    // Loading indicator for interactive startup.
    final Spinner? spinner = interactive ? Spinner() : null;
    final ScreenRegion? loadingRegion = context != null ? ScreenRegion(context) : null;
    var loadingMessage = '';
    void updateLoading(String message) {
      loadingMessage = message;
      loadingRegion?.render(['${spinner!.frame} $loadingMessage']);
    }

    /// Pauses the loading spinner around an interactive screen.
    Future<T> paused<T>(Future<T> Function(TerminalContext context) body) async {
      spinner!.stop();
      loadingRegion!.clear();
      context!.showCursor();
      try {
        return await body(context);
      } finally {
        context.hideCursor();
        spinner.start(() => loadingRegion.render(['${spinner.frame} $loadingMessage']));
      }
    }

    if (interactive) {
      context!.hideCursor();
      spinner!.start(() => loadingRegion!.render(['${spinner.frame} $loadingMessage']));
    }

    final List<String> extensionIds = results.multiOption('extensions');

    final selection = CallbackSelectionPort(
      onSelectExtensions: (List<ExtensionEntry> e) async => e,
      onSelectSources: (SourceSelectionRequest request) async {
        final List<ExtensionEntry> extensions = request.available;
        if (extensions.isEmpty) {
          throw MigrationException(
            'No extensions available at the selected content rating and languages'
            '${request.hiddenByRating > 0 ? ' (${request.hiddenByRating} hidden by rating; see --confirm-adult)' : ''}'
            '${request.hiddenByLanguage > 0 ? ' (${request.hiddenByLanguage} hidden by language; see --languages)' : ''}.',
          );
        }

        // A resumed conversion reuses its journaled sources unless
        // --extensions names others.
        if (extensionIds.isEmpty && request.previousSelection.isNotEmpty) {
          return request.previousSelection;
        }

        // --extensions flag: filter by ID, skip TUI/auto-select. Matching
        // runs after the rating policy, so a hidden source cannot be named.
        if (extensionIds.isNotEmpty) {
          final Set<String> idSet = extensionIds.toSet();
          final List<ExtensionEntry> matched = extensions.where((ExtensionEntry e) => idSet.contains(e.id)).toList();
          final Set<String> unmatched = idSet.difference(matched.map((ExtensionEntry e) => e.id).toSet());
          for (final id in unmatched) {
            Zone.root.print('Warning: extension "$id" not found in repos (or hidden by the content rating).');
          }
          if (matched.isNotEmpty) return matched;
          if (!interactive) {
            throw UsageException('None of the specified extensions were found.', usage);
          }
          // Fall through to TUI when interactive.
        }

        if (interactive) {
          final List<ExtensionEntry>? result = await paused(
            (TerminalContext c) => ExtensionSelectScreen().run(
              context: c,
              extensions: extensions,
              hiddenByRating: request.hiddenByRating,
            ),
          );
          if (result == null || result.isEmpty) {
            throw const MigrationException('No extensions selected.');
          }
          return result;
        }

        // Non-interactive fallback: auto-select MangaDex or first.
        return [extensions.firstWhereOrNull((ExtensionEntry e) => e.id == 'multi.mangadex') ?? extensions.first];
      },
      onConfirmMatches: interactive
          ? (pluginNames, manga, onSearch, onFetchDetails) => paused(
              (TerminalContext c) => MigrationDashboard().run(
                context: c,
                pluginNames: pluginNames,
                manga: manga,
                onSearch: onSearch,
                onFetchDetails: onFetchDetails,
              ),
            )
          : autoAcceptMatches,
      onRepositoryTrust: interactive
          ? (RepositoryTrustRequest request) => paused((TerminalContext c) => _readTrust(c, request))
          : null,
      onResolveChapters: interactive
          ? (ChapterAmbiguityRequest request) =>
                paused((TerminalContext c) => ChapterResolveScreen().run(context: c, request: request))
          : null,
      onAcceptPartial: interactive
          ? (ConversionReport report) => paused((TerminalContext c) => _readAcceptPartial(c, report))
          : null,
      // Unattended runs accept a partial conversion only with --accept-partial.
      acceptPartial: acceptPartial,
    );

    try {
      await runZoned(
        () async {
          updateLoading('Reading backup file...');
          final Uint8List bytes = backupFile.readAsBytesSync();
          updateLoading('Importing ${resolvedInputFormat.alias} backup...');

          final journalStore = FileJournalStore(journalPath);
          if (results.flag('fresh')) await journalStore.clear();
          final job = ConversionJob(
            formats: formats,
            runtimes: runtimes,
            selection: selection,
            journalStore: journalStore,
            ratingPolicy: ratingPolicy,
            languagePolicy: languagePolicy,
            trustStore: PinnedTrustStore(
              FileTrustStore(p.join(userConfigDirectory(), 'trusted_repositories.json')),
              tachiPins,
            ),
            // The Tachi worker scope is closed with every plugin, in the
            // pipeline's finally; it starts only if a Tachi package loads.
            onOwnerOpened: tachi.attach,
            onResume: (int decisions) => Zone.root.print(
              'Resuming from journal $journalPath ($decisions manga decision(s)); use --fresh to start over.',
            ),
            redact: redactor.redact,
            onDecoded: (ConvertableBackup imported) {
              if (!verbose) return;
              print('[VERBOSE] All arguments: ${results.arguments}');
              print('Imported Backup Extension: $backupFileExtension');
              print('============ Imported Backup Data ============ ');
              imported.diagnostics.forEach(print);
              if (!interactive) print('[VERBOSE] Non-interactive mode: auto-accepting best matches');
            },
            onProgress: (int current, int total, String message) {
              if (verbose) print('[$current/$total] $message');
              if (interactive) {
                final progress = total > 0 ? ' [$current/$total]' : '';
                updateLoading('${redactor.redact(message)}$progress');
              }
            },
          );

          final outputFile = io.File(outputPath);
          final bool replacing = outputFile.existsSync();
          // The job validates the output and publishes it atomically (a
          // temporary sibling renamed into place); on any failure the input
          // and an existing destination file are left unchanged.
          final ConversionResult result = await job.run(
            ConversionRequest(
              input: bytes,
              inputName: p.basenameWithoutExtension(backupFile.uri.toString()),
              sourceFormat: resolvedInputFormat,
              targetFormat: outputFormat,
              repoUrls: repoUrls,
              forceMigration: forceMigration,
            ),
            FileConversionOutput(outputPath),
          );
          _conversionReport = result.report;

          if (verbose) {
            print('============ Converted Backup Data ============ ');
            result.draft.backup.diagnostics.forEach(print);
            print('Converted Backup Size: ${result.draft.bytes.length}');
          }
          // Write outside zone — user-facing status messages
          if (replacing) Zone.root.print('Output file already existed; it was replaced.');
          Zone.root.print(
            'Converted backup written to ${outputFile.path}'
            '${result.partialAccepted ? ' (partial conversion accepted)' : ''}',
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) {
            if (log.isMounted) {
              log.writeln(line);
            } else {
              parent.print(zone, redactor.redact(line));
            }
          },
        ),
      );
    } on InvalidConversionOutput catch (e) {
      _conversionReport = e.report;
      io.stderr.writeln(redactor.redact('Migration failed: $e'));
      io.exitCode = 1;
    } on PartialConversionDeclined catch (e) {
      _conversionReport = e.report;
      io.stderr.writeln(
        interactive
            ? 'Migration stopped: the partial conversion was declined; nothing was written.'
            : 'Migration stopped: the conversion is partial and nothing was written. '
                  'Review the report below; re-run with --accept-partial to accept it.',
      );
      io.exitCode = 1;
    } on MigrationException catch (e) {
      io.stderr.writeln(redactor.redact('Migration failed: $e'));
      io.exitCode = 1;
    } finally {
      spinner?.stop();
      loadingRegion?.clear();
      log.unmount();
      await logSink?.flush();
      await logSink?.close();
      if (logSink != null) {
        print('Logs written to $logPath');
      }
    }
  }
}

/// Asks whether to trust a first-seen or changed repository fingerprint.
Future<TrustDecision> _readTrust(TerminalContext context, RepositoryTrustRequest request) async {
  context.write(
    '${request.isChange ? 'The signing fingerprint changed' : 'First time seeing this repository'}: '
    '${request.repository} (${request.ecosystem})\r\n'
    '  fingerprint: ${request.fingerprint}\r\n'
    '${request.isChange ? '  previously:  ${request.previousFingerprint}\r\n' : ''}'
    'Trust it? [y] once / [a] always / [N] no ',
  );
  await for (final KeyEvent key in context.keyInput.stream) {
    final TrustDecision? decision = switch (key) {
      CharKey(char: 'y' || 'Y') => TrustDecision.trustOnce,
      CharKey(char: 'a' || 'A') => TrustDecision.trustAndRemember,
      CharKey(char: 'n' || 'N') || Enter() || Escape() => TrustDecision.reject,
      _ => null,
    };
    if (decision != null) {
      context.write('${decision.name}\r\n');
      return decision;
    }
  }
  return TrustDecision.reject;
}

/// Shows the partial-conversion report and asks whether to accept it.
Future<bool> _readAcceptPartial(TerminalContext context, ConversionReport report) async {
  final region = ScreenRegion(context);
  final List<String> lines = report.describe();
  final int room = context.height - 3;
  region.render(<String>[
    ...lines.take(room).map((String l) => truncate(l, context.width)),
    if (lines.length > room) dim('… ${lines.length - room} more lines (printed after the conversion)'),
    bold('This conversion is partial. Write it anyway? [y/N]'),
  ]);
  final bool accepted = await _readYesNo(context);
  region.clear();
  return accepted;
}

/// Non-interactive fallback: searches for each manga and accepts a match only
/// when exactly one result across all plugins has the exact title (R8).
/// Search failures are kept on each confirmation for the final report.
@visibleForTesting
Future<List<MangaMatchConfirmation>> autoAcceptMatches(
  List<String> pluginNames,
  List<SourceMangaData> manga,
  Stream<PluginSearchEvent> Function(String query) onSearch,
  FetchDetails onFetchDetails,
) async {
  final confirmations = <MangaMatchConfirmation>[];
  for (final entry in manga) {
    final allResults = <PluginSearchResult>[];
    final failures = <PluginSearchFailure>[];
    await for (final PluginSearchEvent event in onSearch(entry.details.title)) {
      switch (event) {
        case PluginSearchResults(:final results):
          allResults.addAll(results);
        case PluginSearchError(:final failure):
          failures.add(failure);
        case PluginSearchStarted():
          break;
      }
    }
    // Only a single exact-title match across plugins is accepted; anything
    // else stays unresolved and is listed in the conversion report.
    confirmations.add(
      MangaMatchConfirmation(
        sourceManga: entry,
        confirmedMatch: uniqueExactTitleMatch(entry.details.title, allResults),
        searchFailures: failures,
      ),
    );
  }
  return confirmations;
}

/// Reads a single y/n keypress from [KeyInput] in raw mode.
Future<bool> _readYesNo(TerminalContext context) async {
  await for (final KeyEvent key in context.keyInput.stream) {
    if (key is CharKey) {
      final String ch = key.char.toLowerCase();
      if (ch == 'y') return true;
      if (ch == 'n') return false;
    }
    if (key is Enter) return false; // default = No
    if (key is Escape) return false;
  }
  return false;
}

bool _isSameBackupFormat(BackupFormat source, BackupFormat target) =>
    source == target || (source is Tachiyomi && target is Tachiyomi);

/// Reads a file path from the user with Tab completion support.
///
/// Renders a prompt line with an inverse-video block cursor and shows
/// completion candidates when multiple Tab matches exist.
/// Returns `null` on Escape; returns [defaultValue] (or `''`) on empty Enter.
Future<String?> _readPath(
  TerminalContext context, {
  String prompt = '',
  String? defaultValue,
}) async {
  final state = PathInputState(defaultValue ?? '');
  final region = ScreenRegion(context);
  const maxCompletionRows = 8;

  void render() {
    final lines = <String>[];
    lines.add(_renderPathInput(prompt, state, context.width));
    // Show completion candidates below the input line.
    final List<String> completions = state.completions;
    if (completions.isNotEmpty) {
      final int count = completions.length.clamp(0, maxCompletionRows);
      for (var i = 0; i < count; i++) {
        final String entry = completions[i];
        final String label = truncate(entry, context.width - 2);
        if (i == state.completionIndex) {
          lines.add(green('❯ $label'));
        } else {
          lines.add('  $label');
        }
      }
      if (completions.length > maxCompletionRows) {
        lines.add(dim('  … ${completions.length - maxCompletionRows} more'));
      }
    }
    region.render(lines);
  }

  context.hideCursor();
  render();

  await for (final KeyEvent key in context.keyInput.stream) {
    final PathInputResult result = state.handleKey(key);
    switch (result) {
      case PathInputResult.submitted:
        region.clear();
        context.showCursor();
        final String text = state.text.trim();
        final String resolved = text.isEmpty ? (defaultValue ?? '') : text;
        context.write('$prompt$resolved\r\n');
        return resolved;
      case PathInputResult.cancelled:
        region.clear();
        context.showCursor();
        context.write('$prompt\r\n');
        return null;
      case PathInputResult.textChanged:
      case PathInputResult.cursorMoved:
      case PathInputResult.tabCompleted:
        render();
      case PathInputResult.ignored:
        break;
    }
  }
  context.showCursor();
  return null;
}

/// Renders the path input line with an inverse-video block cursor.
String _renderPathInput(String prompt, PathInputState state, int width) {
  final String text = state.text;
  final int cursorPos = state.cursorPos;
  final int promptWidth = displayWidth(prompt);
  final int availableWidth = width - promptWidth;

  if (availableWidth <= 0) return truncate(prompt, width);

  final List<String> chars = text.characters.toList();
  final int clampedPos = cursorPos.clamp(0, chars.length);

  final buf = StringBuffer(prompt);
  var col = 0;
  for (var i = 0; i < chars.length; i++) {
    final int gw = displayWidth(chars[i]);
    if (col + gw > availableWidth) break;
    if (i == clampedPos) {
      buf.write('\x1b[7m${chars[i]}\x1b[27m');
    } else {
      buf.write(chars[i]);
    }
    col += gw;
  }
  if (clampedPos == chars.length && col < availableWidth) {
    buf.write('\x1b[7m \x1b[27m');
  }

  return buf.toString();
}

/// Reads a line of text from [KeyInput] in raw mode, echoing characters.
/// Returns `null` on Escape; returns [defaultValue] (or `''`) on empty Enter.
Future<String?> _readLine(
  TerminalContext context, {
  String prompt = '',
  String? defaultValue,
}) async {
  final buf = StringBuffer();
  final String defaultHint = defaultValue != null ? dim(' ($defaultValue)') : '';
  context.write('$prompt$defaultHint');

  await for (final KeyEvent key in context.keyInput.stream) {
    switch (key) {
      case Escape():
        context.write('\r\n');
        return null;
      case Enter():
        context.write('\r\n');
        final String text = buf.toString().trim();
        return text.isEmpty ? (defaultValue ?? '') : text;
      case Backspace():
        if (buf.isNotEmpty) {
          context.write('\x08 \x08');
          final s = buf.toString();
          buf.clear();
          buf.write(s.substring(0, s.length - 1));
        }
      case CharKey(:final char):
        buf.write(char);
        context.write(char);
      default:
        break;
    }
  }
  return null;
}
