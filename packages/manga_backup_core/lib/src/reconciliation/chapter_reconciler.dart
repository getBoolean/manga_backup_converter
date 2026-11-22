import 'package:manga_backup_core/src/common/language_code.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';

// ---------------------------------------------------------------------------
// Evidence normalization — the single definition of "known" values (KTD7).
// ---------------------------------------------------------------------------

/// A chapter number usable as a match key, or `null` when unknown.
///
/// Negative values (the common `-1` sentinel) and non-finite values are
/// unknown. Chapter `0` is a real chapter (prologues, oneshots).
double? knownChapterNumber(double? number) => number != null && number.isFinite && number >= 0 ? number : null;

/// A volume number usable as evidence, or `null` when unknown.
///
/// `0` and negative values are unknown: Paperback and several sources write
/// `0` for "no volume".
double? knownVolumeNumber(double? volume) => volume != null && volume.isFinite && volume > 0 ? volume : null;

/// A comparable title (case-folded, whitespace-collapsed), or `null` if empty.
String? normalizedChapterTitle(String? title) {
  if (title == null) return null;
  final String normalized = title.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  return normalized.isEmpty ? null : normalized;
}

/// The individual scanlator groups named in [scanlator] (e.g. `"A & B"`).
Set<String> scanlatorGroups(String? scanlator) {
  if (scanlator == null) return const <String>{};
  return <String>{
    for (final String part in scanlator.split(RegExp('[,&/|;]')))
      if (part.trim().isNotEmpty) part.trim().toLowerCase(),
  };
}

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

/// A source chapter confidently corresponding to one destination chapter.
final class ChapterMatch {
  const ChapterMatch(this.source, this.destination);

  final SourceChapter source;
  final PluginChapter destination;
}

/// A source chapter that receives no state because its destination is not
/// uniquely defensible.
sealed class UnresolvedChapter {
  const UnresolvedChapter();
}

/// No destination chapter is compatible with [source].
final class UnmatchedChapter extends UnresolvedChapter {
  const UnmatchedChapter(this.source);

  final SourceChapter source;
}

/// Several destination chapters are equally plausible for [source].
final class AmbiguousChapter extends UnresolvedChapter {
  const AmbiguousChapter(this.source, this.candidates);

  final SourceChapter source;
  final List<PluginChapter> candidates;
}

/// Several state-bearing source chapters each uniquely selected the same
/// [destination]. Their state is neither merged nor overwritten.
final class ChapterCollision extends UnresolvedChapter {
  const ChapterCollision(this.destination, this.sources);

  final PluginChapter destination;
  final List<SourceChapter> sources;
}

class ChapterReconciliation {
  const ChapterReconciliation({
    required this.matches,
    required this.unresolved,
    this.excluded = const <SourceChapter>[],
  });

  final List<ChapterMatch> matches;
  final List<UnresolvedChapter> unresolved;

  /// Source chapters the user explicitly excluded; they receive no state.
  final List<SourceChapter> excluded;
}

// ---------------------------------------------------------------------------
// Reconciler
// ---------------------------------------------------------------------------

/// Conservatively maps state-bearing [sourceChapters] onto a fetched,
/// immutable [destinationChapters] snapshot (KTD7).
///
/// - Exact chapter IDs establish correspondence only when
///   [sameSourceIdentity] is true (the caller has verified that source and
///   destination are the same source and manga).
/// - Otherwise a known volume or language that conflicts rejects a candidate;
///   a known chapter number must match exactly; title equality then narrows
///   remaining candidates, with scanlator overlap as additional evidence.
///   Unknown numbers (`-1`) are never shared match keys: such chapters match
///   only on an exact title.
/// - A source chapter needs exactly one remaining candidate. Destination
///   uniqueness is enforced across the whole assignment: when several source
///   chapters select the same destination chapter they all become a
///   [ChapterCollision] and none of them is matched.
///
/// No similarity scoring is used; anything not uniquely defensible is
/// reported as unresolved for the caller to surface (and, later, for the user
/// to resolve).
ChapterReconciliation reconcileChapters({
  required List<SourceChapter> sourceChapters,
  required List<PluginChapter> destinationChapters,
  bool sameSourceIdentity = false,
}) {
  final unresolved = <UnresolvedChapter>[];
  final tentative = <String, List<(SourceChapter, PluginChapter)>>{};

  for (final source in sourceChapters) {
    final List<PluginChapter> candidates = _candidatesFor(source, destinationChapters, sameSourceIdentity);
    switch (candidates.length) {
      case 0:
        unresolved.add(UnmatchedChapter(source));
      case 1:
        final PluginChapter destination = candidates.single;
        (tentative[destination.chapterId] ??= <(SourceChapter, PluginChapter)>[]).add((source, destination));
      default:
        unresolved.add(AmbiguousChapter(source, candidates));
    }
  }

  final matches = <ChapterMatch>[];
  for (final List<(SourceChapter, PluginChapter)> claims in tentative.values) {
    if (claims.length == 1) {
      matches.add(ChapterMatch(claims.single.$1, claims.single.$2));
    } else {
      unresolved.add(
        ChapterCollision(claims.first.$2, <SourceChapter>[for (final (SourceChapter s, _) in claims) s]),
      );
    }
  }

  return ChapterReconciliation(matches: matches, unresolved: unresolved);
}

List<PluginChapter> _candidatesFor(
  SourceChapter source,
  List<PluginChapter> destinations,
  bool sameSourceIdentity,
) {
  if (sameSourceIdentity && source.chapterKey != null) {
    final List<PluginChapter> exact = destinations
        .where((PluginChapter d) => d.chapterId == source.chapterKey)
        .toList();
    if (exact.length == 1) return exact;
  }

  final double? volume = knownVolumeNumber(source.volumeNumber);
  final LanguageCode? language = LanguageCode.tryParse(source.language);
  final double? number = knownChapterNumber(source.chapterNumber);
  final String? title = normalizedChapterTitle(source.title);

  List<PluginChapter> candidates = destinations.where((PluginChapter d) {
    final double? dVolume = knownVolumeNumber(d.volumeNumber);
    if (volume != null && dVolume != null && volume != dVolume) return false;
    final LanguageCode? dLanguage = LanguageCode.tryParse(d.language);
    if (language != null && dLanguage != null && !language.admits(dLanguage)) return false;
    return true;
  }).toList();

  if (number != null) {
    final List<PluginChapter> byNumber = candidates
        .where((PluginChapter d) => knownChapterNumber(d.chapterNumber) == number)
        .toList();
    // A destination that reports no numbers at all (some sources only title
    // their chapters) can still be identified by an exact title; a number is
    // never compared against an unknown one.
    if (byNumber.isEmpty && title != null) {
      candidates = candidates
          .where(
            (PluginChapter d) =>
                knownChapterNumber(d.chapterNumber) == null && normalizedChapterTitle(d.title) == title,
          )
          .toList();
    } else {
      candidates = byNumber;
    }
  } else {
    // Unknown number: only an exact title can identify the chapter.
    if (title == null) return const <PluginChapter>[];
    candidates = candidates.where((PluginChapter d) => normalizedChapterTitle(d.title) == title).toList();
  }

  if (candidates.length <= 1) return candidates;

  final Set<String> groups = scanlatorGroups(source.scanlator);
  bool sharesGroup(PluginChapter d) => d.scanlators.expand(scanlatorGroups).toSet().intersection(groups).isNotEmpty;
  final List<PluginChapter> byTitle = title == null
      ? const <PluginChapter>[]
      : candidates.where((PluginChapter d) => normalizedChapterTitle(d.title) == title).toList();
  final List<PluginChapter> byScanlator = groups.isEmpty
      ? const <PluginChapter>[]
      : candidates.where(sharesGroup).toList();

  // Title and scanlator point at different chapters: conflicting evidence is
  // not resolved by preferring one signal over the other.
  if (byTitle.isNotEmpty && byScanlator.isNotEmpty && !byTitle.any(byScanlator.contains)) {
    return candidates;
  }

  if (byTitle.isNotEmpty) candidates = byTitle;
  if (candidates.length > 1 && groups.isNotEmpty) {
    final List<PluginChapter> narrowed = candidates.where(sharesGroup).toList();
    if (narrowed.isNotEmpty) candidates = narrowed;
  }

  return candidates;
}
