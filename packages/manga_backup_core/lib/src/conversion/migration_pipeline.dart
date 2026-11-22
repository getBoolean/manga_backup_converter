import 'dart:async';
import 'dart:typed_data';

import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/conversion_journal.dart';
import 'package:manga_backup_core/src/conversion/conversion_owner.dart';
import 'package:manga_backup_core/src/conversion/conversion_plan.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/conversion_session.dart';
import 'package:manga_backup_core/src/conversion/conversion_strategy.dart';
import 'package:manga_backup_core/src/conversion/details_outcome.dart';
import 'package:manga_backup_core/src/conversion/extension_entry.dart';
import 'package:manga_backup_core/src/conversion/format_registry.dart';
import 'package:manga_backup_core/src/conversion/match_confirmation.dart';
import 'package:manga_backup_core/src/conversion/plugin_loader.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/repository_trust.dart';
import 'package:manga_backup_core/src/conversion/search_events.dart';
import 'package:manga_backup_core/src/conversion/selection_port.dart';
import 'package:manga_backup_core/src/conversion/source_language_policy.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/conversion/source_rating_policy.dart';
import 'package:manga_backup_core/src/conversion/stable_keys.dart';
import 'package:manga_backup_core/src/conversion/target_backup_builder.dart';
import 'package:manga_backup_core/src/exceptions/migration_exception.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_decisions.dart';
import 'package:meta/meta.dart';
import 'package:source_runtime/source_contracts.dart';

/// A built and structurally validated destination document, its exact
/// serialized [bytes], and its complete accounting. Publishing [bytes]
/// (atomically) is the job's output port.
final class ConversionDraft {
  const ConversionDraft({
    required this.backup,
    required this.bytes,
    required this.report,
    this.plans = const <MangaConversionPlan>[],
    this.partialAccepted = false,
  });

  final ConvertableBackup backup;

  /// The validated serialization of [backup]; these exact bytes are
  /// published (a second `toData()` may differ, for example by timestamp).
  final Uint8List bytes;
  final ConversionReport report;

  /// The reconciliation plans the backup was built from (empty for a direct
  /// conversion).
  final List<MangaConversionPlan> plans;

  /// The report is partial and the user (or `--accept-partial`) accepted it.
  final bool partialAccepted;
}

/// The built output failed pre-publish structural validation (KTD8);
/// nothing may be published.
class InvalidConversionOutput extends MigrationException {
  InvalidConversionOutput(this.format, this.problems, this.report)
    : super(
        'The $format output failed structural validation; nothing was written: '
        '${problems.take(5).join('; ')}${problems.length > 5 ? ' (+${problems.length - 5} more)' : ''}',
      );

  final BackupFormat format;
  final List<String> problems;
  final ConversionReport report;
}

/// The destination cannot be produced on this host: no writer, no direct
/// converter, or its source runtime is unavailable (KTD15).
class DestinationUnavailable extends MigrationException {
  DestinationUnavailable(this.failure) : super(failure.message);

  final SourceFailure failure;
}

/// A partial conversion was not accepted; nothing may be published.
class PartialConversionDeclined extends MigrationException {
  PartialConversionDeclined(this.report) : super('The conversion is partial and was not accepted; nothing was written');

  final ConversionReport report;
}

/// How a conversion produces its destination, decided once before any
/// source work: a direct conversion, or plugin migration through a writer
/// and the destination runtime's loader.
sealed class ConversionRoute {
  const ConversionRoute();
}

/// Converts field by field with [convert]; no sources.
final class DirectRoute extends ConversionRoute {
  const DirectRoute(this.convert);

  final DirectConverter convert;
}

/// Migrates through [loader]'s sources and builds with [writer].
final class MigrationRoute extends ConversionRoute {
  const MigrationRoute({required this.writer, required this.loader});

  final TargetBackupBuilder writer;
  final PluginLoader loader;
}

/// Runs a conversion: direct conversion for formats that need no sources, or
/// plugin migration with complete loss accounting (KTD8).
///
/// Hosts run conversions through `ConversionJob`, which decides the
/// [ConversionRoute] and hands it to [execute]. The public constructor and
/// [run] are a standalone path (tests, tools) that decides the route itself.
class MigrationPipeline {
  MigrationPipeline({
    required this.repoUrls,
    required SelectionPort selection,
    required void Function(int current, int total, String message) onProgress,
    this.pluginLoader,
    FormatRegistry? formats,
    DirectConverter? directConverter,
    SourceLanguagePolicy? languagePolicy,
    this.explicitSources = const <String>{},
    this.onOwnerOpened,
    JournalStore? journalStore,
    void Function(int decisions)? onResume,
    SourceRatingPolicy ratingPolicy = const SourceRatingPolicy(),
    TrustStore? trustStore,
    this.redact = _identity,
  }) : session = ConversionSession(
         selection: selection,
         onProgress: onProgress,
         journalStore: journalStore,
         ratingPolicy: ratingPolicy,
         languagePolicy: languagePolicy,
         onResume: onResume,
       ),
       trustStore = trustStore ?? InMemoryTrustStore(),
       formats = formats ?? FormatRegistry.portable(),
       directConverter = directConverter ?? formats?.directConverter;

  /// The pipeline a `ConversionJob` runs for one request.
  @internal
  MigrationPipeline.forJob({
    required this.session,
    required this.repoUrls,
    required this.explicitSources,
    required this.formats,
    required TrustStore? trustStore,
    required this.redact,
    required this.onOwnerOpened,
  }) : trustStore = trustStore ?? InMemoryTrustStore(),
       pluginLoader = null,
       directConverter = null;

  /// The run's collaborators: selection, progress, journal and policies.
  final ConversionSession session;

  final List<String> repoUrls;

  /// The destination runtime's loader, for [run]'s migrations.
  final PluginLoader? pluginLoader;

  /// Codecs, used to re-check direct conversions (and, for [run], writers).
  final FormatRegistry formats;

  /// For [run]'s direct conversions.
  final DirectConverter? directConverter;

  /// Runtime source IDs the user named: exactly these are searched, with no
  /// language narrowing; every one must load.
  final Set<String> explicitSources;

  /// Called once the conversion owner exists and before any source list is
  /// fetched; composition roots adopt their runtime scope (worker processes)
  /// here so it is closed in the same `finally` as every plugin.
  final FutureOr<void> Function(ConversionOwner owner)? onOwnerOpened;
  final TrustStore trustStore;

  /// Applied to every failure message before it enters the report or the
  /// journal (KTD9). The CLI passes its session `Redactor`.
  final String Function(String text) redact;

  SelectionPort get _selection => session.selection;

  static String _identity(String s) => s;

  /// Decides the route from this pipeline's own parts, then runs it.
  Future<ConversionDraft> run({
    required ConvertableBackup sourceBackup,
    required BackupFormat sourceFormat,
    required BackupFormat targetFormat,
    bool forceMigration = false,

    /// Identity of the input backup (for example a digest of its bytes);
    /// required for the journal to resume a conversion.
    String? inputIdentity,
  }) async => execute(
    _route(sourceFormat, targetFormat, forceMigration: forceMigration),
    sourceBackup: sourceBackup,
    sourceFormat: sourceFormat,
    targetFormat: targetFormat,
    inputIdentity: inputIdentity,
  );

  ConversionRoute _route(BackupFormat source, BackupFormat target, {required bool forceMigration}) {
    if (determineStrategy(source, target) is DirectConversion && !forceMigration) {
      final DirectConverter? convert = directConverter;
      if (convert == null) {
        throw DestinationUnavailable(
          CapabilityUnavailableFailure('direct.${target.alias}', 'No direct converter is registered for $target'),
        );
      }
      return DirectRoute(convert);
    }
    final TargetBackupBuilder? writer = formats.writerFor(target);
    if (writer == null) {
      throw DestinationUnavailable(
        CapabilityUnavailableFailure('writer.${target.alias}', 'No backup writer is registered for $target'),
      );
    }
    final PluginLoader? loader = pluginLoader;
    if (loader == null) {
      throw DestinationUnavailable(
        CapabilityUnavailableFailure('runtime.${target.alias}', 'No source runtime was supplied for $target'),
      );
    }
    return MigrationRoute(writer: writer, loader: loader);
  }

  /// Runs the decided [route] (the `ConversionJob` path).
  @internal
  Future<ConversionDraft> execute(
    ConversionRoute route, {
    required ConvertableBackup sourceBackup,
    required BackupFormat sourceFormat,
    required BackupFormat targetFormat,
    String? inputIdentity,
  }) => switch (route) {
    DirectRoute(:final DirectConverter convert) => _directConvert(convert, sourceBackup, targetFormat),
    MigrationRoute(:final TargetBackupBuilder writer, :final PluginLoader loader) => _runMigration(
      writer,
      loader,
      sourceBackup,
      sourceFormat,
      targetFormat,
      inputIdentity,
    ),
  };

  /// Converts without sources. Every manga, state-bearing chapter and
  /// tracking record is accounted as transferred (the converter carries them
  /// over field by field) and the converter adds what it changes or drops.
  /// The output is decoded again before it may be published.
  Future<ConversionDraft> _directConvert(
    DirectConverter convert,
    ConvertableBackup sourceBackup,
    BackupFormat targetFormat,
  ) async {
    final report = ConversionReport();
    final List<SourceMangaData> manga = sourceBackup.sourceMangaDataEntries;
    for (final m in manga) {
      final String title = m.details.title;
      report.add(RecordKind.manga, RecordDisposition.transferred, title, title);
      for (final SourceChapter c in m.chapters.where((SourceChapter c) => c.hasReadingState)) {
        report.add(RecordKind.chapterState, RecordDisposition.transferred, title, chapterLabel(c));
      }
      for (final SourceTrackingEntry t in m.tracking) {
        report.add(RecordKind.tracking, RecordDisposition.transferred, title, trackingLabel(t));
      }
    }
    for (final ExtractionLoss loss in sourceBackup.extractionLosses) {
      report.add(RecordKind.manga, RecordDisposition.unresolved, loss.subject, loss.subject, reason: loss.reason);
    }
    final ConvertableBackup backup = convert(sourceBackup, targetFormat, report);
    final Uint8List bytes = await backup.toData();
    final BackupDecoder? decode = formats.codecFor(targetFormat);
    final problems = <String>[];
    if (decode == null) {
      problems.add('no codec is registered to re-read $targetFormat');
    } else {
      try {
        final int written = (await decode(bytes)).sourceMangaDataEntries.length;
        if (written != manga.length) problems.add('$written of ${manga.length} manga were written');
      } on Object catch (e) {
        problems.add('the written backup does not decode: $e');
      }
    }
    if (problems.isNotEmpty) throw InvalidConversionOutput(targetFormat, problems, report);
    if (report.isPartial && !await _selection.acceptPartialConversion(report)) throw PartialConversionDeclined(report);
    return ConversionDraft(backup: backup, bytes: bytes, report: report, partialAccepted: report.isPartial);
  }

  Future<ConversionDraft> _runMigration(
    TargetBackupBuilder writer,
    PluginLoader loader,
    ConvertableBackup sourceBackup,
    BackupFormat sourceFormat,
    BackupFormat targetFormat,
    String? inputIdentity,
  ) async {
    final owner = ConversionOwner();
    try {
      await onOwnerOpened?.call(owner);
      final _Journal journal = await _Journal.open(
        session.journalStore,
        inputIdentity: inputIdentity,
        sourceFormat: sourceFormat.alias,
        targetFormat: targetFormat.alias,
      );
      if (journal.resumedDecisions > 0) session.onResume?.call(journal.resumedDecisions);
      return await _migrate(writer, loader, owner, journal, sourceBackup, sourceFormat, targetFormat);
    } finally {
      await owner.close();
    }
  }

  Future<ConversionDraft> _migrate(
    TargetBackupBuilder writer,
    PluginLoader loader,
    ConversionOwner owner,
    _Journal journal,
    ConvertableBackup sourceBackup,
    BackupFormat sourceFormat,
    BackupFormat targetFormat,
  ) async {
    final report = ConversionReport();
    final SelectionPort selection = _selection;
    final void Function(int current, int total, String message) onProgress = session.onProgress;
    final SourceRatingPolicy ratingPolicy = session.ratingPolicy;
    final gate = RepositoryTrustGate(store: trustStore, decide: selection.decideRepositoryTrust);

    onProgress(0, 0, 'Fetching extension lists...');
    final List<ExtensionEntry> availableExtensions = await loader.fetchExtensionLists(
      repoUrls,
      onWarning: (String msg) => onProgress(0, 0, 'Warning: ${redact(msg)}'),
      trust: gate,
    );
    report.decisions.addAll(gate.decisions);
    if (availableExtensions.isEmpty && repoUrls.isNotEmpty) {
      // Keep trust decisions visible: a refused repository lists nothing.
      throw MigrationException(
        'No extensions found from provided repos'
        '${gate.decisions.isEmpty ? '' : ' (${gate.decisions.map(redact).join('; ')})'}',
      );
    }

    final ({int hidden, List<ExtensionEntry> visible}) rated = ratingPolicy.apply(availableExtensions);
    final List<SourceMangaData> mangaList = sourceBackup.sourceMangaDataEntries;
    final SourceLanguagePolicy languages = explicitSources.isNotEmpty
        ? const SourceLanguagePolicy.any()
        : session.languagePolicy ?? SourceLanguagePolicy.inferredFrom(mangaList);
    report.notes.add(
      explicitSources.isNotEmpty
          ? 'Exactly the named sources were searched (${(explicitSources.toList()..sort()).join(', ')}); '
                'no language narrowing'
          : languages.describe(),
    );
    // Sources are always chosen afresh (a resumed run may pick other flags);
    // journaled confirmations rehydrate only against matching sessions.
    final List<ExtensionEntry> selected =
        (await selection.selectSources(
              SourceSelectionRequest(
                available: rated.visible,
                hiddenByRating: rated.hidden,
                languages: languages.languages,
                explicitSources: explicitSources,
                previousSelection: journal.previousSelection(rated.visible),
              ),
            ))
            // The rating policy holds even if a selection UI returns a hidden source.
            .where((ExtensionEntry e) => ratingPolicy.allows(e.contentRating))
            .toList();
    if (selected.isEmpty) throw const MigrationException('No extensions selected');
    await journal.recordSelection(selected);

    onProgress(0, selected.length, 'Loading plugins...');
    final loadFailures = <PluginLoadFailure>[];
    final List<PluginSource> loaded = await loader.loadPlugins(
      selected,
      onProgress: onProgress,
      owner: owner,
      onFailure: loadFailures.add,
    );
    for (final plugin in loaded) {
      await owner.adopt(plugin.dispose);
    }
    final List<PluginSource> plugins = _sourcesToSearch(loaded, languages, report);
    for (final f in loadFailures) {
      report.failures.add(SourceFailureRecord.fromFailure(FailureStage.load, f.extensionId, f.failure, redact: redact));
    }
    if (explicitSources.isNotEmpty) {
      final Set<String> missing = explicitSources.difference(<String>{for (final p in plugins) p.sourceId});
      if (missing.isNotEmpty) {
        throw MigrationException(
          'Named source(s) ${(missing.toList()..sort()).join(', ')} did not load from the selected extensions',
        );
      }
    }
    if (plugins.isEmpty) {
      throw MigrationException(
        'No plugins loaded successfully'
        '${loadFailures.isEmpty ? '' : ': ${loadFailures.map((PluginLoadFailure f) => '${f.extensionId} ${redact(f.failure.toString())}').join('; ')}'}',
      );
    }
    await journal.recordSessions(plugins);

    final List<String> keys = stableMangaKeys(mangaList);
    for (final ExtractionLoss loss in sourceBackup.extractionLosses) {
      report.add(RecordKind.manga, RecordDisposition.unresolved, loss.subject, loss.subject, reason: loss.reason);
    }

    PluginSource? pluginFor(NativeMangaRef ref) => plugins
        .where((PluginSource p) => p.identity == ref.source && p.settingsRevision == ref.settingsRevision)
        .firstOrNull;

    Future<DetailsOutcome> fetchDetails(NativeMangaRef ref) async {
      final PluginSource? plugin = pluginFor(ref);
      if (plugin == null) {
        return DetailsFailed(StaleReferenceFailure('No loaded source matches ${ref.source} at this settings revision'));
      }
      try {
        return await plugin.fetchDetails(ref);
      } on Object catch (e) {
        return DetailsFailed(SourceErrorFailure('$e'));
      }
    }

    // Rehydrate journaled decisions; a changed artifact or settings revision
    // reopens the affected manga.
    final confirmations = List<MangaMatchConfirmation?>.filled(mangaList.length, null);
    for (final (int i, SourceMangaData m) in mangaList.indexed) {
      confirmations[i] = await journal.rehydrate(keys[i], m, (NativeMangaRef ref) => pluginFor(ref) != null);
    }

    final pending = <int>[
      for (final (int i, MangaMatchConfirmation? c) in confirmations.indexed)
        if (c == null) i,
    ];
    if (pending.isNotEmpty) {
      final pendingManga = <SourceMangaData>[for (final i in pending) mangaList[i]];
      final List<MangaMatchConfirmation> decided = await selection.confirmMatches(
        plugins.map((PluginSource p) => p.sourceName).toList(),
        pendingManga,
        (String query) => _streamSearch(query, plugins),
        fetchDetails,
      );
      for (final (int n, int i) in pending.indexed) {
        final MangaMatchConfirmation c =
            decided.where((MangaMatchConfirmation d) => identical(d.sourceManga, mangaList[i])).firstOrNull ??
            (n < decided.length && decided.length == pending.length
                ? decided[n]
                : MangaMatchConfirmation(sourceManga: mangaList[i]));
        confirmations[i] = c;
        await journal.recordConfirmation(keys[i], c, redact);
      }
    }

    // Fetch the confirmed destination snapshot of every match that has none.
    // A snapshot the selection UI already fetched (an enriched match) or the
    // journal holds is reused, never fetched again; either way it is journaled.
    await Future.wait(<Future<void>>[
      for (final (int i, MangaMatchConfirmation? c) in confirmations.indexed)
        if (c != null && !c.excluded && c.confirmedMatch != null && c.destination == null)
          () async {
            final DetailsOutcome outcome =
                c.confirmedMatch!.fetchedOutcome ?? await fetchDetails(c.confirmedMatch!.ref);
            switch (outcome) {
              case DetailsFailed(:final SourceFailure failure):
                final SourceFailure redacted = redactFailure(failure, redact);
                confirmations[i] = c.withDetailsFailure(redacted);
                report.failures.add(
                  SourceFailureRecord.fromFailure(
                    FailureStage.details,
                    c.confirmedMatch!.pluginSourceId,
                    redacted,
                    manga: c.sourceManga.details.title,
                  ),
                );
              case DetailsFetched(:final FetchedManga manga) || DetailsEmpty(:final FetchedManga manga):
                confirmations[i] = c.withDestination(manga);
                await journal.recordSnapshot(keys[i], manga);
            }
          }(),
    ]);

    for (final c in confirmations) {
      for (final PluginSearchFailure f in c?.searchFailures ?? const <PluginSearchFailure>[]) {
        report.failures.add(
          SourceFailureRecord.fromFailure(
            FailureStage.search,
            f.pluginName ?? f.pluginId,
            f.failure,
            manga: c!.sourceManga.details.title,
            redact: redact,
          ),
        );
      }
    }

    // Reconcile; the user resolves what stays ambiguous (KTD7).
    final plans = <MangaConversionPlan>[];
    for (final (int i, MangaMatchConfirmation? c) in confirmations.indexed) {
      final String key = keys[i];
      List<ChapterDecision> decisions = journal.chapterDecisions(key);
      MangaConversionPlan plan = planConversion(c!, decisions: decisions);
      if (plan.isBuildable && plan.reconciliation.unresolved.isNotEmpty) {
        final List<ChapterDecision> added = await selection.resolveChapters(
          ChapterAmbiguityRequest(
            mangaKey: key,
            mangaTitle: c.sourceManga.details.title,
            unresolved: plan.reconciliation.unresolved,
            destinationChapters: c.targetChapters,
          ),
        );
        if (added.isNotEmpty) {
          decisions = <ChapterDecision>[...decisions, ...added];
          plan = planConversion(c, decisions: decisions);
          await journal.recordChapterDecisions(key, decisions);
        }
      }
      for (final ChapterDecision d in plan.decisions) {
        report.decisions.add(_describeDecision(c, d));
      }
      plans.add(plan);
    }

    final ConvertableBackup backup = writer.build(plans, sourceFormatAlias: sourceFormat.alias, report: report);
    // KTD8: validate the exact bytes that will be published, before asking
    // for acceptance; an invalid output is never offered or written.
    final Uint8List bytes = await backup.toData();
    final List<String> problems = writer.validate(bytes, plans);
    if (problems.isNotEmpty) throw InvalidConversionOutput(targetFormat, problems, report);

    var partialAccepted = false;
    if (report.isPartial) {
      if (journal.acceptedDigest == report.digest) {
        partialAccepted = true;
      } else {
        partialAccepted = await selection.acceptPartialConversion(report);
        if (!partialAccepted) throw PartialConversionDeclined(report);
        await journal.recordAcceptance(report.digest);
      }
      report.decisions.add('Partial conversion accepted');
    }
    return ConversionDraft(
      backup: backup,
      bytes: bytes,
      report: report,
      plans: plans,
      partialAccepted: partialAccepted,
    );
  }

  /// The loaded sources to search. Named sources ([explicitSources]) are
  /// used exactly. Otherwise each picked package is narrowed to its sources
  /// in the searched languages plus multi-language ones (a Tachi MangaDex
  /// package exposes one source per language); a package with no such
  /// source keeps all of its sources, since the user picked it.
  List<PluginSource> _sourcesToSearch(
    List<PluginSource> loaded,
    SourceLanguagePolicy languages,
    ConversionReport report,
  ) {
    if (explicitSources.isNotEmpty) {
      return loaded.where((PluginSource p) => explicitSources.contains(p.sourceId)).toList();
    }
    final byPackage = <String, List<PluginSource>>{};
    for (final p in loaded) {
      (byPackage['${p.identity.ecosystem}|${p.identity.packageId}'] ??= <PluginSource>[]).add(p);
    }
    final kept = <PluginSource>[];
    final skipped = <PluginSource>[];
    for (final List<PluginSource> package in byPackage.values) {
      final List<PluginSource> matching = package
          .where((PluginSource p) => languages.allowsLanguage(p.language))
          .toList();
      if (matching.isEmpty) {
        kept.addAll(package);
        report.notes.add(
          '${package.first.identity.packageId} has no source in the searched languages; all of its '
          '${package.length} source(s) were searched because it was picked',
        );
      } else {
        kept.addAll(matching);
        skipped.addAll(package.where((PluginSource p) => !matching.contains(p)));
      }
    }
    if (skipped.isNotEmpty) {
      report.notes.add(
        '${skipped.length} source(s) of other languages in the picked extensions were not searched '
        '(${skipped.map((PluginSource p) => p.sourceName).take(8).join(', ')}${skipped.length > 8 ? ', …' : ''})',
      );
    }
    // Keep the loader's order.
    return loaded.where(kept.contains).toList();
  }

  static String _describeDecision(MangaMatchConfirmation c, ChapterDecision d) {
    final String title = c.sourceManga.details.title;
    if (d.isExclusion) return '$title: excluded source chapter ${d.sourceChapterKey}';
    final PluginChapter? dest = c.targetChapters
        .where((PluginChapter p) => p.chapterId == d.destinationChapterId)
        .firstOrNull;
    return '$title: source chapter ${d.sourceChapterKey} → destination "${dest?.title ?? d.destinationChapterId}"';
  }

  /// Searches all [plugins] in parallel, emitting raw results and typed
  /// failures as they arrive. Results are not enriched; details are fetched
  /// only for confirmed matches.
  Stream<PluginSearchEvent> _streamSearch(String query, List<PluginSource> plugins) {
    final controller = StreamController<PluginSearchEvent>();
    var cancelled = false;
    controller.onCancel = () {
      cancelled = true;
    };
    int remaining = plugins.length;
    if (remaining == 0) {
      controller.close();
      return controller.stream;
    }
    void emit(PluginSearchEvent event) {
      if (!cancelled && !controller.isClosed) controller.add(event);
    }

    PluginSearchError failed(PluginSource plugin, SourceFailure failure) => PluginSearchError(
      failure: PluginSearchFailure(
        pluginId: plugin.sourceId,
        pluginName: plugin.sourceName,
        failure: redactFailure(failure, redact),
      ),
    );

    for (final plugin in plugins) {
      controller.add(PluginSearchStarted(pluginId: plugin.sourceId, pluginName: plugin.sourceName));
      Future<SourceOutcome<PluginSearchPageResult>>(() => plugin.search(query, 1))
          .then(
            (SourceOutcome<PluginSearchPageResult> outcome) {
              switch (outcome) {
                case SourceSuccess<PluginSearchPageResult>(:final PluginSearchPageResult value):
                  emit(
                    PluginSearchResults(
                      pluginId: plugin.sourceId,
                      pluginName: plugin.sourceName,
                      results: value.results,
                    ),
                  );
                  if (value.warnings.isNotEmpty) {
                    emit(
                      failed(
                        plugin,
                        SourceErrorFailure('${value.warnings.length} host error(s): ${value.warnings.join('; ')}'),
                      ),
                    );
                  }
                case SourceFailed<PluginSearchPageResult>(:final SourceFailure failure):
                  emit(failed(plugin, failure));
              }
            },
            onError: (Object e) => emit(failed(plugin, SourceErrorFailure('$e'))),
          )
          .whenComplete(() {
            remaining--;
            if (remaining == 0 && !controller.isClosed) controller.close();
          });
    }
    return controller.stream;
  }
}

/// The pipeline's view of the journal: persistence is serialized, and every
/// write goes through the store after each completed step.
final class _Journal {
  _Journal(this._store, this._journal);

  static Future<_Journal> open(
    JournalStore? store, {
    required String? inputIdentity,
    required String sourceFormat,
    required String targetFormat,
  }) async {
    if (store == null || inputIdentity == null) return _Journal(null, null);
    ConversionJournal? existing;
    try {
      final Map<String, Object?>? json = await store.read();
      if (json != null) existing = ConversionJournal.fromJson(json);
    } on Object {
      // An unreadable or foreign journal starts a fresh conversion.
      existing = null;
    }
    final bool resumable =
        existing != null &&
        existing.matches(inputIdentity: inputIdentity, sourceFormat: sourceFormat, targetFormat: targetFormat);
    return _Journal(
      store,
      resumable
          ? existing
          : ConversionJournal(inputIdentity: inputIdentity, sourceFormat: sourceFormat, targetFormat: targetFormat),
    ).._resumed = resumable ? existing.confirmations.length : 0;
  }

  final JournalStore? _store;
  final ConversionJournal? _journal;
  Future<void> _writes = Future<void>.value();

  String? get acceptedDigest => _journal?.acceptedReportDigest;

  /// Journaled manga decisions found when the journal was opened.
  int get resumedDecisions => _resumed;
  int _resumed = 0;

  Future<void> _persist() {
    final JournalStore? store = _store;
    final ConversionJournal? journal = _journal;
    if (store == null || journal == null) return Future<void>.value();
    return _writes = _writes.then((_) => store.write(journal.toJson()));
  }

  /// The journaled selection, limited to sources still offered at the same
  /// version.
  List<ExtensionEntry> previousSelection(List<ExtensionEntry> visible) => <ExtensionEntry>[
    for (final JournaledSource s in _journal?.sources ?? const <JournaledSource>[])
      ?visible.where((ExtensionEntry v) => v.id == s.extensionId && v.cacheKey == s.cacheKey).firstOrNull,
  ];

  Future<void> recordSelection(List<ExtensionEntry> selected) {
    final ConversionJournal? j = _journal;
    if (j == null) return Future<void>.value();
    j.sources
      ..clear()
      ..addAll(<JournaledSource>[
        for (final ExtensionEntry e in selected) JournaledSource(extensionId: e.id, cacheKey: e.cacheKey),
      ]);
    return _persist();
  }

  Future<void> recordSessions(List<PluginSource> plugins) {
    final ConversionJournal? j = _journal;
    if (j == null) return Future<void>.value();
    j.sessions
      ..clear()
      ..addAll(<JournaledSession>[
        for (final PluginSource p in plugins)
          JournaledSession(identity: p.identity, settingsRevision: p.settingsRevision),
      ]);
    return _persist();
  }

  /// The journaled decision for [key], or `null` when the manga needs a
  /// (new) decision. A match whose source is no longer loaded at the same
  /// artifact and settings revision is reopened: its confirmation and chapter
  /// decisions are dropped.
  Future<MangaMatchConfirmation?> rehydrate(
    String key,
    SourceMangaData manga,
    bool Function(NativeMangaRef ref) isLoaded,
  ) async {
    final ConversionJournal? j = _journal;
    final JournaledConfirmation? c = j?.confirmations[key];
    if (j == null || c == null) return null;
    final List<PluginSearchFailure> failures = c.searchFailures;
    switch (c.decision) {
      case MangaDecisionKind.excluded:
        return MangaMatchConfirmation(sourceManga: manga, excluded: true, searchFailures: failures);
      case MangaDecisionKind.matched:
        final NativeMangaRef? ref = c.ref;
        if (ref == null || !isLoaded(ref)) {
          j.confirmations.remove(key);
          j.chapterDecisions.remove(key);
          j.acceptedReportDigest = null;
          await _persist();
          return null;
        }
        final confirmation = MangaMatchConfirmation(
          sourceManga: manga,
          confirmedMatch: PluginSearchResult(
            ref: ref,
            title: c.title ?? ref.mangaId,
            pluginSourceName: c.pluginSourceName,
            coverUrl: c.coverUrl,
            authors: c.authors,
          ),
          searchFailures: failures,
        );
        final FetchedManga? snapshot = c.snapshot;
        return snapshot == null ? confirmation : confirmation.withDestination(snapshot);
    }
  }

  Future<void> recordConfirmation(String key, MangaMatchConfirmation c, String Function(String) redact) {
    final ConversionJournal? j = _journal;
    if (j == null) return Future<void>.value();
    final PluginSearchResult? match = c.confirmedMatch;
    if (!c.excluded && match == null) {
      // Not a decision: the manga is searched again on resume.
      if (j.confirmations.remove(key) == null) return Future<void>.value();
      return _persist();
    }
    j.confirmations[key] = JournaledConfirmation(
      decision: c.excluded ? MangaDecisionKind.excluded : MangaDecisionKind.matched,
      ref: c.excluded ? null : match?.ref,
      title: match?.title,
      pluginSourceName: match?.pluginSourceName,
      coverUrl: match?.coverUrl,
      authors: match?.authors ?? const <String>[],
      searchFailures: <PluginSearchFailure>[
        for (final PluginSearchFailure f in c.searchFailures)
          PluginSearchFailure(
            pluginId: f.pluginId,
            pluginName: f.pluginName,
            failure: redactFailure(f.failure, redact),
          ),
      ],
    );
    return _persist();
  }

  Future<void> recordSnapshot(String key, FetchedManga snapshot) {
    final ConversionJournal? j = _journal;
    final JournaledConfirmation? c = j?.confirmations[key];
    if (j == null || c == null) return Future<void>.value();
    j.confirmations[key] = c.withSnapshot(snapshot);
    return _persist();
  }

  List<ChapterDecision> chapterDecisions(String key) => _journal?.chapterDecisions[key] ?? const <ChapterDecision>[];

  Future<void> recordChapterDecisions(String key, List<ChapterDecision> decisions) {
    final ConversionJournal? j = _journal;
    if (j == null) return Future<void>.value();
    j.chapterDecisions[key] = decisions;
    return _persist();
  }

  Future<void> recordAcceptance(String digest) {
    final ConversionJournal? j = _journal;
    if (j == null) return Future<void>.value();
    j.acceptedReportDigest = digest;
    return _persist();
  }
}
