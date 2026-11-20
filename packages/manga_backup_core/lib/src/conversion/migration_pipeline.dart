import 'dart:async';

import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/conversion_journal.dart';
import 'package:manga_backup_core/src/conversion/conversion_owner.dart';
import 'package:manga_backup_core/src/conversion/conversion_plan.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/conversion_strategy.dart';
import 'package:manga_backup_core/src/conversion/details_outcome.dart';
import 'package:manga_backup_core/src/conversion/extension_entry.dart';
import 'package:manga_backup_core/src/conversion/match_confirmation.dart';
import 'package:manga_backup_core/src/conversion/plugin_loader.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/repository_trust.dart';
import 'package:manga_backup_core/src/conversion/search_events.dart';
import 'package:manga_backup_core/src/conversion/selection_port.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/conversion/source_rating_policy.dart';
import 'package:manga_backup_core/src/conversion/stable_keys.dart';
import 'package:manga_backup_core/src/exceptions/migration_exception.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_decisions.dart';
import 'package:source_runtime/source_contracts.dart';

/// Converts directly between formats that need no source plugins (for
/// example the CLI's Tachimanga↔Tachi adapter, which is native-dependent and
/// therefore lives outside the core).
typedef DirectConverter = ConvertableBackup Function(ConvertableBackup source, BackupFormat target);

/// A built, validated-by-construction destination document and its complete
/// accounting. Publishing it (atomically) is the platform adapter's job.
final class ConversionDraft {
  const ConversionDraft({required this.backup, required this.report, this.partialAccepted = false});

  final ConvertableBackup backup;
  final ConversionReport report;

  /// The report is partial and the user (or `--accept-partial`) accepted it.
  final bool partialAccepted;
}

/// A partial conversion was not accepted; nothing may be published.
class PartialConversionDeclined extends MigrationException {
  PartialConversionDeclined(this.report) : super('The conversion is partial and was not accepted; nothing was written');

  final ConversionReport report;
}

/// Runs a conversion: direct conversion for formats that need no sources, or
/// plugin migration with complete loss accounting (KTD8).
class MigrationPipeline {
  MigrationPipeline({
    required this.repoUrls,
    required this.selection,
    required this.onProgress,
    required this.pluginLoader,
    this.directConverter,
    this.onOwnerOpened,
    this.journalStore,
    this.ratingPolicy = const SourceRatingPolicy(),
    TrustStore? trustStore,
    this.redact = _identity,
  }) : trustStore = trustStore ?? InMemoryTrustStore();

  final List<String> repoUrls;
  final SelectionPort selection;
  final void Function(int current, int total, String message) onProgress;
  final PluginLoader pluginLoader;
  final DirectConverter? directConverter;

  /// Called once the conversion owner exists and before any source list is
  /// fetched; composition roots adopt their runtime scope (worker processes)
  /// here so it is closed in the same `finally` as every plugin.
  final FutureOr<void> Function(ConversionOwner owner)? onOwnerOpened;

  /// Persists the conversion journal; `null` disables journaling.
  final JournalStore? journalStore;
  final SourceRatingPolicy ratingPolicy;
  final TrustStore trustStore;

  /// Applied to every failure message before it enters the report or the
  /// journal (KTD9). The CLI passes its session `Redactor`.
  final String Function(String text) redact;

  static String _identity(String s) => s;

  Future<ConversionDraft> run({
    required ConvertableBackup sourceBackup,
    required BackupFormat sourceFormat,
    required BackupFormat targetFormat,
    bool forceMigration = false,

    /// Identity of the input backup (for example a digest of its bytes);
    /// required for the journal to resume a conversion.
    String? inputIdentity,
  }) async {
    final ConversionStrategy strategy = determineStrategy(sourceFormat, targetFormat);
    return switch (strategy) {
      DirectConversion() when !forceMigration => _directConvert(sourceBackup, targetFormat),
      _ => _runMigration(sourceBackup, sourceFormat, targetFormat, inputIdentity),
    };
  }

  ConversionDraft _directConvert(ConvertableBackup sourceBackup, BackupFormat targetFormat) {
    final DirectConverter? convert = directConverter;
    if (convert == null) {
      throw StateError('No direct converter registered for ${sourceBackup.runtimeType} → $targetFormat');
    }
    return ConversionDraft(backup: convert(sourceBackup, targetFormat), report: ConversionReport());
  }

  Future<ConversionDraft> _runMigration(
    ConvertableBackup sourceBackup,
    BackupFormat sourceFormat,
    BackupFormat targetFormat,
    String? inputIdentity,
  ) async {
    final owner = ConversionOwner();
    try {
      await onOwnerOpened?.call(owner);
      final _Journal journal = await _Journal.open(
        journalStore,
        inputIdentity: inputIdentity,
        sourceFormat: sourceFormat.alias,
        targetFormat: targetFormat.alias,
      );
      return await _migrate(owner, journal, sourceBackup, sourceFormat, targetFormat);
    } finally {
      await owner.close();
    }
  }

  Future<ConversionDraft> _migrate(
    ConversionOwner owner,
    _Journal journal,
    ConvertableBackup sourceBackup,
    BackupFormat sourceFormat,
    BackupFormat targetFormat,
  ) async {
    final report = ConversionReport();
    final gate = RepositoryTrustGate(store: trustStore, decide: selection.decideRepositoryTrust);

    onProgress(0, 0, 'Fetching extension lists...');
    final List<ExtensionEntry> availableExtensions = await pluginLoader.fetchExtensionLists(
      repoUrls,
      onWarning: (String msg) => onProgress(0, 0, 'Warning: ${redact(msg)}'),
      trust: gate,
    );
    report.decisions.addAll(gate.decisions);
    if (availableExtensions.isEmpty && repoUrls.isNotEmpty) {
      throw const MigrationException('No extensions found from provided repos');
    }

    final ({int hidden, List<ExtensionEntry> visible}) rated = ratingPolicy.apply(availableExtensions);
    final List<ExtensionEntry> selected =
        (journal.resumedSelection(rated.visible) ??
                await selection.selectSources(
                  SourceSelectionRequest(available: rated.visible, hiddenByRating: rated.hidden),
                ))
            // The rating policy holds even if a selection UI returns a hidden source.
            .where((ExtensionEntry e) => ratingPolicy.allows(e.contentRating))
            .toList();
    if (selected.isEmpty) throw const MigrationException('No extensions selected');
    await journal.recordSelection(selected);

    onProgress(0, selected.length, 'Loading plugins...');
    final loadFailures = <PluginLoadFailure>[];
    final List<PluginSource> plugins = await pluginLoader.loadPlugins(
      selected,
      onProgress: onProgress,
      owner: owner,
      onFailure: loadFailures.add,
    );
    for (final plugin in plugins) {
      await owner.adopt(plugin.dispose);
    }
    for (final f in loadFailures) {
      report.failures.add(SourceFailureRecord.fromFailure(FailureStage.load, f.extensionId, f.failure, redact: redact));
    }
    if (plugins.isEmpty) {
      throw MigrationException(
        'No plugins loaded successfully'
        '${loadFailures.isEmpty ? '' : ': ${loadFailures.map((PluginLoadFailure f) => '${f.extensionId} ${redact(f.failure.toString())}').join('; ')}'}',
      );
    }
    await journal.recordSessions(plugins);

    final List<SourceMangaData> mangaList = sourceBackup.sourceMangaDataEntries;
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

    // Fetch the confirmed destination snapshot of every match that has none
    // (journaled snapshots are reused, never re-fetched).
    await Future.wait(<Future<void>>[
      for (final (int i, MangaMatchConfirmation? c) in confirmations.indexed)
        if (c != null && !c.excluded && c.confirmedMatch != null && c.destination == null)
          () async {
            final DetailsOutcome outcome = await fetchDetails(c.confirmedMatch!.ref);
            switch (outcome) {
              case DetailsFailed(:final SourceFailure failure):
                final redacted = SourceFailure.fromWire(failure.code, redact(failure.message));
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

    final ConvertableBackup backup = targetFormat.backupBuilder.build(
      plans,
      sourceFormatAlias: sourceFormat.alias,
      report: report,
    );

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
    return ConversionDraft(backup: backup, report: report, partialAccepted: partialAccepted);
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
        failure: SourceFailure.fromWire(failure.code, redact(failure.message)),
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
    );
  }

  final JournalStore? _store;
  final ConversionJournal? _journal;
  Future<void> _writes = Future<void>.value();

  String? get acceptedDigest => _journal?.acceptedReportDigest;

  Future<void> _persist() {
    final JournalStore? store = _store;
    final ConversionJournal? journal = _journal;
    if (store == null || journal == null) return Future<void>.value();
    return _writes = _writes.then((_) => store.write(journal.toJson()));
  }

  /// The journaled selection, when every journaled source is still offered
  /// at the same version.
  List<ExtensionEntry>? resumedSelection(List<ExtensionEntry> visible) {
    final List<JournaledSource>? sources = _journal?.sources;
    if (sources == null || sources.isEmpty) return null;
    final result = <ExtensionEntry>[];
    for (final JournaledSource s in sources) {
      final ExtensionEntry? e = visible
          .where((ExtensionEntry v) => v.id == s.extensionId && v.cacheKey == s.cacheKey)
          .firstOrNull;
      if (e == null) return null;
      result.add(e);
    }
    return result;
  }

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
    final failures = <PluginSearchFailure>[
      for (final SourceFailureRecord f in c.searchFailures)
        PluginSearchFailure(pluginId: f.sourceId, failure: SourceFailure.fromWire(f.code, f.message)),
    ];
    switch (c.decision) {
      case MangaDecisionKind.excluded:
        return MangaMatchConfirmation(sourceManga: manga, excluded: true, searchFailures: failures);
      case MangaDecisionKind.unresolved:
        return MangaMatchConfirmation(sourceManga: manga, searchFailures: failures);
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
    j.confirmations[key] = JournaledConfirmation(
      decision: c.excluded
          ? MangaDecisionKind.excluded
          : match == null
          ? MangaDecisionKind.unresolved
          : MangaDecisionKind.matched,
      ref: c.excluded ? null : match?.ref,
      title: match?.title,
      pluginSourceName: match?.pluginSourceName,
      searchFailures: <SourceFailureRecord>[
        for (final PluginSearchFailure f in c.searchFailures)
          SourceFailureRecord.fromFailure(FailureStage.search, f.pluginId, f.failure, redact: redact),
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
