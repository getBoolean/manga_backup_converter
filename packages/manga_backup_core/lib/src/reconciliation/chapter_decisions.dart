import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/conversion/stable_keys.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_reconciler.dart';
import 'package:meta/meta.dart';

/// A user's resolution of one unresolved source chapter (KTD7): assign it to
/// [destinationChapterId], or exclude it ([destinationChapterId] is `null`).
@immutable
final class ChapterDecision {
  const ChapterDecision({required this.sourceChapterKey, this.destinationChapterId});

  const ChapterDecision.exclude(this.sourceChapterKey) : destinationChapterId = null;

  factory ChapterDecision.fromJson(Map<String, Object?> json) => ChapterDecision(
    sourceChapterKey: json['source']! as String,
    destinationChapterId: json['destination'] as String?,
  );

  /// [stableChapterKey] of the source chapter.
  final String sourceChapterKey;
  final String? destinationChapterId;

  bool get isExclusion => destinationChapterId == null;

  Map<String, Object?> toJson() => <String, Object?>{'source': sourceChapterKey, 'destination': destinationChapterId};

  @override
  bool operator ==(Object other) =>
      other is ChapterDecision &&
      other.sourceChapterKey == sourceChapterKey &&
      other.destinationChapterId == destinationChapterId;

  @override
  int get hashCode => Object.hash(sourceChapterKey, destinationChapterId);
}

/// The source chapters an [UnresolvedChapter] concerns.
List<SourceChapter> sourcesOf(UnresolvedChapter u) => switch (u) {
  UnmatchedChapter(:final SourceChapter source) || AmbiguousChapter(:final SourceChapter source) => <SourceChapter>[
    source,
  ],
  ChapterCollision(:final List<SourceChapter> sources) => sources,
};

/// Applies user [decisions] to a [reconciliation] against [destinations].
///
/// Only decided chapters change: an assignment becomes a claim on its
/// destination chapter, an exclusion leaves the chapter without state.
/// Destination uniqueness is re-enforced over the complete assignment after
/// the overrides — two chapters claiming one destination (user-assigned or
/// not) form a collision and neither receives state. Decisions naming an
/// unknown destination chapter are ignored, leaving the chapter unresolved.
ChapterReconciliation applyChapterDecisions(
  ChapterReconciliation reconciliation,
  List<ChapterDecision> decisions,
  List<PluginChapter> destinations,
) {
  if (decisions.isEmpty) return reconciliation;
  final byId = <String, PluginChapter>{for (final PluginChapter d in destinations) d.chapterId: d};
  final decided = <String, ChapterDecision>{
    for (final ChapterDecision d in decisions)
      if (d.isExclusion || byId.containsKey(d.destinationChapterId)) d.sourceChapterKey: d,
  };

  final claims = <String, List<SourceChapter>>{};
  final unresolved = <UnresolvedChapter>[];
  final excluded = <SourceChapter>[...reconciliation.excluded];

  /// Routes one source chapter: decided chapters follow the decision,
  /// undecided ones keep their [fallback] (a claim or an unresolved item).
  bool route(SourceChapter s) {
    final ChapterDecision? d = decided[stableChapterKey(s)];
    if (d == null) return false;
    if (d.isExclusion) {
      excluded.add(s);
    } else {
      (claims[d.destinationChapterId!] ??= <SourceChapter>[]).add(s);
    }
    return true;
  }

  for (final ChapterMatch m in reconciliation.matches) {
    if (!route(m.source)) (claims[m.destination.chapterId] ??= <SourceChapter>[]).add(m.source);
  }
  for (final UnresolvedChapter u in reconciliation.unresolved) {
    switch (u) {
      case ChapterCollision(:final PluginChapter destination, :final List<SourceChapter> sources):
        // Undecided members still claim the destination they each selected.
        for (final s in sources) {
          if (!route(s)) (claims[destination.chapterId] ??= <SourceChapter>[]).add(s);
        }
      case UnmatchedChapter(:final SourceChapter source) || AmbiguousChapter(:final SourceChapter source):
        if (!route(source)) unresolved.add(u);
    }
  }

  final matches = <ChapterMatch>[];
  for (final MapEntry<String, List<SourceChapter>> claim in claims.entries) {
    final PluginChapter destination = byId[claim.key]!;
    if (claim.value.length == 1) {
      matches.add(ChapterMatch(claim.value.single, destination));
    } else {
      unresolved.add(ChapterCollision(destination, claim.value));
    }
  }
  return ChapterReconciliation(matches: matches, unresolved: unresolved, excluded: excluded);
}
