import 'dart:async';

import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:riverpod/riverpod.dart';
import 'package:source_runtime/source_contracts.dart';

/// The app's conversion entry point: runs the same core [ConversionJob] as
/// the CLI, with the runtime registry and platform adapters the app's
/// composition root supplies (KTD14, KTD15).
///
/// The service names no concrete source backend: the iOS and Android
/// composition roots (U14, U15) register their local Aidoku, Paperback and
/// Tachi runtimes in [runtimes], and pass their own file output, journal
/// store and selection UI per conversion.
class ConversionService {
  ConversionService({
    required this.runtimes,
    FormatRegistry? formats,
    this.trustStore,
    this.redact = _identity,
    this.onOwnerOpened,
  }) : formats = formats ?? FormatRegistry.portable();

  /// Source runtimes available on this device.
  final RuntimeRegistry runtimes;

  /// Codecs and writers; the portable set unless the host adds its own.
  final FormatRegistry formats;

  /// Remembered repository trust decisions (platform storage).
  final TrustStore? trustStore;

  /// Applied to failure messages before they reach a report (KTD9).
  final String Function(String text) redact;

  /// Called with each conversion's owner before any runtime starts, so the
  /// composition root can adopt the per-conversion runtime scopes it creates
  /// (workers, browser bridges); the owner closes them when the job ends.
  final FutureOr<void> Function(ConversionOwner owner)? onOwnerOpened;

  static String _identity(String s) => s;

  /// Why [target] cannot be produced from [source] on this device, or
  /// `null` when it can.
  SourceFailure? unavailable(
    BackupFormat source,
    BackupFormat target, {
    bool forceMigration = false,
  }) => conversionUnavailable(
    formats,
    runtimes,
    source,
    target,
    forceMigration: forceMigration,
  );

  /// The destinations enabled for [source] on this device.
  List<BackupFormat> availableTargets(BackupFormat source) => <BackupFormat>[
    for (final BackupFormat t in formats.outputFormats)
      if (unavailable(source, t) == null) t,
  ];

  /// Runs one conversion. Everything source-related is the user's: the
  /// repositories in [ConversionRequest.repoUrls], the extensions picked
  /// through [selection] (the app's decision UI adapter) or named in
  /// [ConversionRequest.sources], and the extension settings from
  /// [settingsFor]. [output] is the app's atomic file publisher and
  /// [journal] its resumable job store; [onResume] is told how many
  /// journaled decisions a resumed job reuses.
  Future<ConversionResult> convert(
    ConversionRequest request, {
    required SelectionPort selection,
    required ConversionOutput output,
    JournalStore? journal,
    SourceRatingPolicy ratingPolicy = const SourceRatingPolicy(),
    SourceLanguagePolicy? languages,
    ExtensionSettingsProvider settingsFor = noExtensionSettings,
    void Function(int current, int total, String message)? onProgress,
    void Function(int decisions)? onResume,
  }) => ConversionJob(
    formats: formats,
    runtimes: runtimes,
    selection: selection,
    journalStore: journal,
    ratingPolicy: ratingPolicy,
    languagePolicy: languages,
    settingsFor: settingsFor,
    trustStore: trustStore,
    redact: redact,
    onOwnerOpened: onOwnerOpened,
    onResume: onResume,
    onProgress: onProgress ?? (_, _, _) {},
  ).run(request, output);
}

/// The app's [ConversionService]. The platform composition root overrides
/// it with the device's runtime registry; there is deliberately no default
/// backend (a missing runtime is a typed failure, never a fallback).
final conversionServiceProvider = Provider<ConversionService>(
  (Ref ref) => ConversionService(runtimes: RuntimeRegistry()),
);
