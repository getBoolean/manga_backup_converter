import 'package:args/args.dart';
import 'package:mangabackupconverter_cli/mangabackupconverter_lib.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart' show TachiArtifactPolicy;

/// The `convert` command's options, parsed and validated without I/O or
/// prompts. What is missing here (backup path, formats, output path) the
/// command asks for interactively or rejects when unattended.
final class ConvertOptions {
  const ConvertOptions({
    required this.backup,
    required this.outputFormat,
    required this.inputFormat,
    required this.output,
    required this.repos,
    required this.tachiPins,
    required this.tachiPolicy,
    required this.tachiHandshakeDeadline,
    required this.tachiRuntime,
    required this.webviewHelper,
    required this.ratingPolicy,
    required this.languagePolicy,
    required this.extensionIds,
    required this.sourceIds,
    required this.settingsFile,
    required this.settingFlags,
    required this.logFile,
    required this.journal,
    required this.acceptPartial,
    required this.fresh,
    required this.verbose,
  });

  /// Parses [results]; a malformed or contradictory value throws
  /// [FormatException] with the message for the user.
  factory ConvertOptions.parse(ArgResults results) {
    final ratingPolicy = SourceRatingPolicy(
      adultContentConfirmed: results.flag('confirm-adult'),
      maxRating: switch (results.option('max-rating')) {
        'safe' => ContentRatingLevel.safe,
        'suggestive' => ContentRatingLevel.suggestive,
        'nsfw' => ContentRatingLevel.nsfw,
        _ => null,
      },
    );
    if (ratingPolicy.requestsUnconfirmedAdult) {
      throw const FormatException('--max-rating nsfw requires --confirm-adult (age confirmation).');
    }
    final String? languages = results.option('languages');
    final String? handshake = results.option('tachi-handshake-deadline-ms');
    final int? handshakeMs = handshake == null ? null : int.tryParse(handshake);
    if (handshake != null && (handshakeMs ?? 0) <= 0) {
      throw FormatException('--tachi-handshake-deadline-ms must be a positive integer, got "$handshake"');
    }
    final String? output = results.option('output-format');
    return ConvertOptions(
      backup: results.option('backup'),
      outputFormat: output == null ? null : BackupFormat.byName(output),
      inputFormat: results.wasParsed('input-format') ? BackupFormat.byName(results.option('input-format')!) : null,
      output: results.wasParsed('output') ? results.option('output') : null,
      repos: results.multiOption('repos'),
      tachiPins: PinnedTrustStore.parsePins(results.multiOption('trust-tachi-repo')),
      tachiPolicy: parseTachiArtifactOverrides(results.multiOption('tachi-artifact')),
      tachiHandshakeDeadline: handshakeMs == null ? null : Duration(milliseconds: handshakeMs),
      tachiRuntime: results.option('tachi-runtime'),
      webviewHelper: results.option('webview-helper'),
      ratingPolicy: ratingPolicy,
      languagePolicy: languages == null ? null : SourceLanguagePolicy.parse(languages),
      extensionIds: results.multiOption('extensions'),
      sourceIds: results.multiOption('sources').toSet(),
      settingsFile: results.option('settings'),
      settingFlags: results.multiOption('setting'),
      logFile: results.option('log-file'),
      journal: results.option('journal'),
      acceptPartial: results.flag('accept-partial'),
      fresh: results.flag('fresh'),
      verbose: results.flag('verbose'),
    );
  }

  /// `--backup`, or `null` to ask.
  final String? backup;

  /// `--output-format`, or `null` to ask.
  final BackupFormat? outputFormat;

  /// `--input-format`, or `null` to detect it from the file extension.
  final BackupFormat? inputFormat;

  /// `--output`, or `null` for the default (or to ask).
  final String? output;

  /// The user's repositories (never a built-in list).
  final List<String> repos;
  final Map<Uri, String> tachiPins;
  final TachiArtifactPolicy tachiPolicy;
  final Duration? tachiHandshakeDeadline;
  final String? tachiRuntime;
  final String? webviewHelper;
  final SourceRatingPolicy ratingPolicy;

  /// `null` infers the languages from the backup.
  final SourceLanguagePolicy? languagePolicy;
  final List<String> extensionIds;
  final Set<String> sourceIds;
  final String? settingsFile;
  final List<String> settingFlags;
  final String? logFile;
  final String? journal;
  final bool acceptPartial;
  final bool fresh;
  final bool verbose;
}
