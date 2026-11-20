import 'dart:async';

import 'package:manga_backup_core/src/conversion/details_outcome.dart';
import 'package:manga_backup_core/src/conversion/match_confirmation.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_decisions.dart';
import 'package:source_runtime/source_contracts.dart';

/// How a manga's match was decided. Only decisions are journaled; a manga
/// without a confirmed match is searched again on resume.
enum MangaDecisionKind {
  /// Confirmed against a destination; [JournaledConfirmation.snapshot] holds
  /// the confirmed destination snapshot once fetched.
  matched,

  /// The user excluded it.
  excluded,
}

/// A source the user selected, by extension identity and version.
final class JournaledSource {
  const JournaledSource({required this.extensionId, required this.cacheKey});

  factory JournaledSource.fromJson(Map<String, Object?> json) =>
      JournaledSource(extensionId: json['extensionId']! as String, cacheKey: json['cacheKey']! as String);

  final String extensionId;

  /// Extension version identity (`ExtensionEntry.cacheKey`).
  final String cacheKey;

  Map<String, Object?> toJson() => <String, Object?>{'extensionId': extensionId, 'cacheKey': cacheKey};
}

/// A loaded source session: its verified identity (including the artifact
/// digest) and the secret-free settings revision it ran with.
final class JournaledSession {
  const JournaledSession({required this.identity, required this.settingsRevision});

  factory JournaledSession.fromJson(Map<String, Object?> json) => JournaledSession(
    identity: SourceIdentity.fromJson(json['identity']! as Map<String, Object?>),
    settingsRevision: json['settingsRevision']! as String,
  );

  final SourceIdentity identity;
  final String settingsRevision;

  Map<String, Object?> toJson() => <String, Object?>{
    'identity': identity.toJson(),
    'settingsRevision': settingsRevision,
  };
}

/// A manga decision with its durable native reference and, once fetched,
/// the confirmed destination snapshot (reused on resume instead of
/// re-fetching).
final class JournaledConfirmation {
  const JournaledConfirmation({
    required this.decision,
    this.ref,
    this.title,
    this.pluginSourceName,
    this.coverUrl,
    this.authors = const <String>[],
    this.snapshot,
    this.searchFailures = const <PluginSearchFailure>[],
  });

  factory JournaledConfirmation.fromJson(Map<String, Object?> json) => JournaledConfirmation(
    decision: MangaDecisionKind.values.byName(json['decision']! as String),
    ref: json['ref'] == null ? null : NativeMangaRef.fromJson(json['ref']! as Map<String, Object?>),
    title: json['title'] as String?,
    pluginSourceName: json['pluginSourceName'] as String?,
    coverUrl: json['coverUrl'] as String?,
    authors: <String>[for (final Object? a in json['authors'] as List<Object?>? ?? const <Object?>[]) a! as String],
    snapshot: json['snapshot'] == null ? null : FetchedManga.fromJson(json['snapshot']! as Map<String, Object?>),
    searchFailures: <PluginSearchFailure>[
      for (final Object? f in json['searchFailures'] as List<Object?>? ?? const <Object?>[])
        _failureFromJson(f! as Map<String, Object?>),
    ],
  );

  static PluginSearchFailure _failureFromJson(Map<String, Object?> json) => PluginSearchFailure(
    pluginId: json['pluginId']! as String,
    pluginName: json['pluginName'] as String?,
    failure: SourceFailure.fromWire(
      json['code']! as String,
      json['message']! as String,
      operation: json['operation'] as String?,
    ),
  );

  static Map<String, Object?> _failureToJson(PluginSearchFailure f) => <String, Object?>{
    'pluginId': f.pluginId,
    'pluginName': f.pluginName,
    ...f.failure.toWire(),
  };

  final MangaDecisionKind decision;
  final NativeMangaRef? ref;

  /// Search-result fields of the confirmed match, so a resumed build has the
  /// same fallbacks as an uninterrupted one.
  final String? title;
  final String? pluginSourceName;
  final String? coverUrl;
  final List<String> authors;
  final FetchedManga? snapshot;

  /// Search failures seen while matching (messages already redacted).
  final List<PluginSearchFailure> searchFailures;

  JournaledConfirmation withSnapshot(FetchedManga snapshot) => JournaledConfirmation(
    decision: decision,
    ref: ref,
    title: title,
    pluginSourceName: pluginSourceName,
    coverUrl: coverUrl,
    authors: authors,
    snapshot: snapshot,
    searchFailures: searchFailures,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'decision': decision.name,
    'ref': ref?.toJson(),
    'title': title,
    'pluginSourceName': pluginSourceName,
    'coverUrl': coverUrl,
    'authors': authors,
    'snapshot': snapshot?.toJson(),
    'searchFailures': <Map<String, Object?>>[for (final PluginSearchFailure f in searchFailures) _failureToJson(f)],
  };
}

/// Durable record of a conversion's completed steps (KTD8): input backup
/// identity, selected sources with artifact and settings revisions,
/// confirmed native references with their destination snapshots, user
/// chapter decisions, and the accepted loss report.
///
/// Never holds secrets (KTD9): references and snapshots serialise without
/// session handles, sources record only the secret-free settings revision,
/// and failure messages are redacted before they are recorded.
final class ConversionJournal {
  ConversionJournal({
    required this.inputIdentity,
    required this.sourceFormat,
    required this.targetFormat,
    List<JournaledSource>? sources,
    List<JournaledSession>? sessions,
    Map<String, JournaledConfirmation>? confirmations,
    Map<String, List<ChapterDecision>>? chapterDecisions,
    this.acceptedReportDigest,
  }) : sources = sources ?? <JournaledSource>[],
       sessions = sessions ?? <JournaledSession>[],
       confirmations = confirmations ?? <String, JournaledConfirmation>{},
       chapterDecisions = chapterDecisions ?? <String, List<ChapterDecision>>{};

  factory ConversionJournal.fromJson(Map<String, Object?> json) {
    if (json['version'] != version) throw FormatException('Unsupported conversion journal version ${json['version']}');
    return ConversionJournal(
      inputIdentity: json['inputIdentity']! as String,
      sourceFormat: json['sourceFormat']! as String,
      targetFormat: json['targetFormat']! as String,
      sources: <JournaledSource>[
        for (final Object? s in json['sources']! as List<Object?>) JournaledSource.fromJson(s! as Map<String, Object?>),
      ],
      sessions: <JournaledSession>[
        for (final Object? s in json['sessions']! as List<Object?>)
          JournaledSession.fromJson(s! as Map<String, Object?>),
      ],
      confirmations: <String, JournaledConfirmation>{
        for (final MapEntry<String, Object?> e in (json['confirmations']! as Map<String, Object?>).entries)
          e.key: JournaledConfirmation.fromJson(e.value! as Map<String, Object?>),
      },
      chapterDecisions: <String, List<ChapterDecision>>{
        for (final MapEntry<String, Object?> e in (json['chapterDecisions']! as Map<String, Object?>).entries)
          e.key: <ChapterDecision>[
            for (final Object? d in e.value! as List<Object?>) ChapterDecision.fromJson(d! as Map<String, Object?>),
          ],
      },
      acceptedReportDigest: json['acceptedReportDigest'] as String?,
    );
  }

  static const int version = 1;

  /// Identity of the input backup (for example a digest of its bytes).
  final String inputIdentity;
  final String sourceFormat;
  final String targetFormat;

  /// Selected sources.
  final List<JournaledSource> sources;

  /// Loaded sessions, with artifact and settings revisions.
  final List<JournaledSession> sessions;

  /// Keyed by stable manga key.
  final Map<String, JournaledConfirmation> confirmations;

  /// Keyed by stable manga key.
  final Map<String, List<ChapterDecision>> chapterDecisions;

  /// Digest of the partial-conversion report the user accepted.
  String? acceptedReportDigest;

  /// Whether this journal records the same conversion.
  bool matches({required String inputIdentity, required String sourceFormat, required String targetFormat}) =>
      this.inputIdentity == inputIdentity && this.sourceFormat == sourceFormat && this.targetFormat == targetFormat;

  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'inputIdentity': inputIdentity,
    'sourceFormat': sourceFormat,
    'targetFormat': targetFormat,
    'sources': <Map<String, Object?>>[for (final JournaledSource s in sources) s.toJson()],
    'sessions': <Map<String, Object?>>[for (final JournaledSession s in sessions) s.toJson()],
    'confirmations': <String, Object?>{
      for (final MapEntry<String, JournaledConfirmation> e in confirmations.entries) e.key: e.value.toJson(),
    },
    'chapterDecisions': <String, Object?>{
      for (final MapEntry<String, List<ChapterDecision>> e in chapterDecisions.entries)
        e.key: <Map<String, Object?>>[for (final ChapterDecision d in e.value) d.toJson()],
    },
    'acceptedReportDigest': acceptedReportDigest,
  };
}

/// Persists a [ConversionJournal]'s JSON form. A platform I/O adapter
/// implements it (the CLI writes a file atomically; mobile hosts use app
/// storage).
abstract interface class JournalStore {
  /// The stored journal, or `null` when there is none.
  Future<Map<String, Object?>?> read();

  /// Replaces the stored journal; must be atomic.
  Future<void> write(Map<String, Object?> journal);

  /// Removes the stored journal (after publication).
  Future<void> clear();
}

/// A [JournalStore] held in memory; survives as long as the instance (tests
/// share one instance across simulated processes).
final class InMemoryJournalStore implements JournalStore {
  Map<String, Object?>? _json;

  /// The last written journal JSON.
  Map<String, Object?>? get json => _json;

  @override
  Future<Map<String, Object?>?> read() async => _json;

  @override
  Future<void> write(Map<String, Object?> journal) async => _json = journal;

  @override
  Future<void> clear() async => _json = null;
}
