import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/conversion_journal.dart';
import 'package:manga_backup_core/src/conversion/conversion_owner.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/conversion_strategy.dart';
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
    return formats.directConverter == null
        ? CapabilityUnavailableFailure('direct.${target.alias}', 'No direct converter is registered for $target')
        : null;
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
    this.forceMigration = false,
  });

  /// The input backup bytes; never modified.
  final Uint8List input;

  /// Display name of the input (for formats that carry none).
  final String? inputName;
  final BackupFormat sourceFormat;
  final BackupFormat targetFormat;
  final List<String> repoUrls;

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
/// service differ only in the adapters they inject — the [RuntimeRegistry]
/// (source providers and capabilities), the [SelectionPort] (user
/// decisions), the [ConversionOutput] and [JournalStore] (platform I/O).
///
/// It decodes the input with the [FormatRegistry], checks the destination is
/// enabled on this host (writer and runtime, or a direct converter), runs
/// the pipeline (which validates the exact output bytes, KTD8), and only
/// then publishes and clears the journal. Any failure publishes nothing.
final class ConversionJob {
  ConversionJob({
    required this.formats,
    required this.runtimes,
    required this.selection,
    this.onProgress = _noProgress,
    this.journalStore,
    this.ratingPolicy = const SourceRatingPolicy(),
    this.languagePolicy,
    this.trustStore,
    this.redact = _identity,
    this.onOwnerOpened,
    this.onResume,
    this.onDecoded,
  });

  final FormatRegistry formats;
  final RuntimeRegistry runtimes;
  final SelectionPort selection;
  final void Function(int current, int total, String message) onProgress;
  final JournalStore? journalStore;
  final SourceRatingPolicy ratingPolicy;

  /// `null` infers the languages from the input backup.
  final SourceLanguagePolicy? languagePolicy;
  final TrustStore? trustStore;
  final String Function(String text) redact;
  final FutureOr<void> Function(ConversionOwner owner)? onOwnerOpened;
  final void Function(int decisions)? onResume;

  /// Called with the decoded input before conversion (diagnostics).
  final void Function(ConvertableBackup input)? onDecoded;

  static void _noProgress(int current, int total, String message) {}
  static String _identity(String s) => s;

  /// Why [target] cannot be produced from [source] on this host, or `null`
  /// when it can (see [conversionUnavailable]).
  SourceFailure? unavailable(BackupFormat source, BackupFormat target, {bool forceMigration = false}) =>
      conversionUnavailable(formats, runtimes, source, target, forceMigration: forceMigration);

  /// Whether [target] is a usable destination from [source] on this host.
  bool enabled(BackupFormat source, BackupFormat target, {bool forceMigration = false}) =>
      unavailable(source, target, forceMigration: forceMigration) == null;

  Future<ConversionResult> run(ConversionRequest request, ConversionOutput output) async {
    final SourceFailure? missing = unavailable(
      request.sourceFormat,
      request.targetFormat,
      forceMigration: request.forceMigration,
    );
    if (missing != null) throw DestinationUnavailable(missing);

    final bool direct =
        determineStrategy(request.sourceFormat, request.targetFormat) is DirectConversion && !request.forceMigration;
    PluginLoader? loader;
    if (!direct) {
      final SourceOutcome<PluginLoader> resolved = runtimes.loaderFor(request.targetFormat);
      loader = resolved.valueOrNull;
      if (loader == null) throw DestinationUnavailable(resolved.failureOrNull!);
    }

    final ConvertableBackup input = await formats.codecFor(request.sourceFormat)!(
      Uint8List.fromList(request.input),
      name: request.inputName,
    );
    onDecoded?.call(input);

    final pipeline = MigrationPipeline(
      repoUrls: request.repoUrls,
      selection: selection,
      onProgress: onProgress,
      pluginLoader: loader,
      formats: formats,
      languagePolicy: languagePolicy,
      onOwnerOpened: onOwnerOpened,
      journalStore: journalStore,
      onResume: onResume,
      ratingPolicy: ratingPolicy,
      trustStore: trustStore,
      redact: redact,
    );
    final ConversionDraft draft = await pipeline.run(
      sourceBackup: input,
      sourceFormat: request.sourceFormat,
      targetFormat: request.targetFormat,
      forceMigration: request.forceMigration,
      inputIdentity: sha256.convert(request.input).toString(),
    );
    await output.publish(draft.bytes);
    await journalStore?.clear();
    return ConversionResult(draft: draft, input: input);
  }
}
