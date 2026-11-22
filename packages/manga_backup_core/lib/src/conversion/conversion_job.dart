import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/conversion_journal.dart';
import 'package:manga_backup_core/src/conversion/conversion_owner.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/conversion_session.dart';
import 'package:manga_backup_core/src/conversion/conversion_strategy.dart';
import 'package:manga_backup_core/src/conversion/extension_settings.dart';
import 'package:manga_backup_core/src/conversion/format_registry.dart';
import 'package:manga_backup_core/src/conversion/migration_pipeline.dart';
import 'package:manga_backup_core/src/conversion/plugin_loader.dart';
import 'package:manga_backup_core/src/conversion/repository_trust.dart';
import 'package:manga_backup_core/src/conversion/runtime_registry.dart';
import 'package:manga_backup_core/src/conversion/selection_port.dart';
import 'package:manga_backup_core/src/conversion/source_language_policy.dart';
import 'package:manga_backup_core/src/conversion/source_rating_policy.dart';
import 'package:source_runtime/source_contracts.dart';

/// Where a finished conversion is published (a platform I/O adapter).
abstract interface class ConversionOutput {
  /// Publishes [bytes] atomically: on any failure the previous destination
  /// is left unchanged and no partial file is visible.
  Future<void> publish(Uint8List bytes);
}

/// Why [target] cannot be produced from [source] with [formats] and
/// [runtimes], or `null` when it can: the input needs a codec; a direct pair
/// needs the direct converter; anything else needs a writer and an
/// available destination runtime. Cheap: runtimes are probed, never started.
SourceFailure? conversionUnavailable(
  FormatRegistry formats,
  RuntimeRegistry runtimes,
  BackupFormat source,
  BackupFormat target, {
  bool forceMigration = false,
}) {
  if (formats.codecFor(source) == null) {
    return CapabilityUnavailableFailure('codec.${source.alias}', 'No codec is registered to read $source');
  }
  if (determineStrategy(source, target) is DirectConversion && !forceMigration) {
    return formats.directTarget(target)
        ? null
        : CapabilityUnavailableFailure('direct.${target.alias}', 'No verified direct conversion to $target');
  }
  if (formats.writerFor(target) == null) {
    return CapabilityUnavailableFailure('writer.${target.alias}', 'No backup writer is registered for $target');
  }
  return runtimes.unavailable(target);
}

/// One conversion to run.
final class ConversionRequest {
  const ConversionRequest({
    required this.input,
    required this.sourceFormat,
    required this.targetFormat,
    this.inputName,
    this.repoUrls = const <String>[],
    this.sources = const <String>{},
    this.forceMigration = false,
  });

  /// The input backup bytes; never modified.
  final Uint8List input;

  /// Display name of the input (for formats that carry none).
  final String? inputName;
  final BackupFormat sourceFormat;
  final BackupFormat targetFormat;

  /// The repositories the user supplied (never a built-in list).
  final List<String> repoUrls;

  /// Runtime source IDs the user named: exactly these sources are searched
  /// and language narrowing is skipped. Empty: the user's extension picks,
  /// narrowed to the backup's languages.
  final Set<String> sources;

  /// Use plugin migration for a pair that could convert directly.
  final bool forceMigration;
}

/// What a completed conversion published.
final class ConversionResult {
  const ConversionResult({required this.draft, required this.input});

  final ConversionDraft draft;

  /// The decoded input backup.
  final ConvertableBackup input;

  ConversionReport get report => draft.report;
  bool get partialAccepted => draft.partialAccepted;
}

/// The conversion job every host runs (KTD14): the CLI and the Flutter app
/// service differ only in the adapters they inject. The job holds the
/// host-lifetime parts — the [FormatRegistry], the [RuntimeRegistry] (source
/// providers and capabilities), the [TrustStore], the redactor and the
/// runtime scope adoption — and each [run] takes the per-run parts: the
/// [ConversionRequest], the [ConversionOutput] and the [ConversionSession]
/// (user decisions, journal, policies, progress).
///
/// A run decodes the input with the [FormatRegistry], checks the destination
/// is enabled on this host (writer and runtime, or a direct converter),
/// decides the [ConversionRoute] once, runs the pipeline on it (which
/// validates the exact output bytes, KTD8), and only then publishes and
/// clears the journal. Any failure publishes nothing.
final class ConversionJob {
  /// The per-run parameters ([selection] through [settingsFor]) are a
  /// compatibility path: given here, they form the session [run] uses when it
  /// is passed none. New hosts pass a [ConversionSession] to [run] instead.
  ConversionJob({
    required this.formats,
    required this.runtimes,
    this.trustStore,
    this.redact = _identity,
    this.onOwnerOpened,
    SelectionPort? selection,
    void Function(int current, int total, String message)? onProgress,
    JournalStore? journalStore,
    SourceRatingPolicy ratingPolicy = const SourceRatingPolicy(),
    SourceLanguagePolicy? languagePolicy,
    void Function(int decisions)? onResume,
    void Function(ConvertableBackup input)? onDecoded,
    ExtensionSettingsProvider settingsFor = noExtensionSettings,
  }) : _defaultSession = selection == null
           ? null
           : ConversionSession(
               selection: selection,
               onProgress: onProgress ?? _noProgress,
               journalStore: journalStore,
               ratingPolicy: ratingPolicy,
               languagePolicy: languagePolicy,
               onResume: onResume,
               onDecoded: onDecoded,
               settingsFor: settingsFor,
             );

  final FormatRegistry formats;
  final RuntimeRegistry runtimes;
  final TrustStore? trustStore;
  final String Function(String text) redact;
  final FutureOr<void> Function(ConversionOwner owner)? onOwnerOpened;
  final ConversionSession? _defaultSession;

  static void _noProgress(int current, int total, String message) {}
  static String _identity(String s) => s;

  /// Why [target] cannot be produced from [source] on this host, or `null`
  /// when it can (see [conversionUnavailable]).
  SourceFailure? unavailable(BackupFormat source, BackupFormat target, {bool forceMigration = false}) =>
      conversionUnavailable(formats, runtimes, source, target, forceMigration: forceMigration);

  /// Whether [target] is a usable destination from [source] on this host.
  bool enabled(BackupFormat source, BackupFormat target, {bool forceMigration = false}) =>
      unavailable(source, target, forceMigration: forceMigration) == null;

  Future<ConversionResult> run(ConversionRequest request, ConversionOutput output, [ConversionSession? session]) async {
    final ConversionSession s =
        session ?? _defaultSession ?? (throw ArgumentError('ConversionJob.run needs a ConversionSession'));
    final ConversionRoute route = _route(request, s);

    final ConvertableBackup input = await formats.codecFor(request.sourceFormat)!(
      Uint8List.fromList(request.input),
      name: request.inputName,
    );
    s.onDecoded?.call(input);

    final ConversionDraft draft =
        await MigrationPipeline.forJob(
          session: s,
          repoUrls: request.repoUrls,
          explicitSources: request.sources,
          formats: formats,
          trustStore: trustStore,
          redact: redact,
          onOwnerOpened: onOwnerOpened,
        ).execute(
          route,
          sourceBackup: input,
          sourceFormat: request.sourceFormat,
          targetFormat: request.targetFormat,
          inputIdentity: sha256.convert(request.input).toString(),
        );
    await output.publish(draft.bytes);
    await s.journalStore?.clear();
    return ConversionResult(draft: draft, input: input);
  }

  /// The one decision of how [request] is produced on this host; throws
  /// [DestinationUnavailable] when it cannot be.
  ConversionRoute _route(ConversionRequest request, ConversionSession session) {
    final SourceFailure? missing = unavailable(
      request.sourceFormat,
      request.targetFormat,
      forceMigration: request.forceMigration,
    );
    if (missing != null) throw DestinationUnavailable(missing);
    if (determineStrategy(request.sourceFormat, request.targetFormat) is DirectConversion && !request.forceMigration) {
      return DirectRoute(formats.directConverter!);
    }
    final SourceOutcome<PluginLoader> loader = runtimes.loaderFor(
      request.targetFormat,
      RuntimeContext(settingsFor: session.settingsFor),
    );
    return MigrationRoute(
      writer: formats.writerFor(request.targetFormat)!,
      loader: loader.valueOrNull ?? (throw DestinationUnavailable(loader.failureOrNull!)),
    );
  }
}
