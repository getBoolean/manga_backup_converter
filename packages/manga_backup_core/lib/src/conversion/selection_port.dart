import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/details_outcome.dart';
import 'package:manga_backup_core/src/conversion/extension_entry.dart';
import 'package:manga_backup_core/src/conversion/match_confirmation.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/repository_trust.dart';
import 'package:manga_backup_core/src/conversion/search_events.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_decisions.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_reconciler.dart';
import 'package:source_runtime/source_contracts.dart';

/// Fetches a confirmed or candidate manga by its native reference.
typedef FetchDetails = Future<DetailsOutcome> Function(NativeMangaRef ref);

/// Batch match confirmation: receives all source manga still needing a
/// decision, a streaming search function, and a details function; returns
/// one confirmation per manga.
typedef OnConfirmMatches = Future<List<MangaMatchConfirmation>> Function(
  List<String> pluginNames,
  List<SourceMangaData> manga,
  Stream<PluginSearchEvent> Function(String query) onSearch,
  FetchDetails onFetchDetails,
);

/// Sources the user may choose from, after the content-rating policy.
final class SourceSelectionRequest {
  const SourceSelectionRequest({
    required this.available,
    required this.hiddenByRating,
    this.previousSelection = const <ExtensionEntry>[],
    this.languages,
    this.explicitSources = const <String>{},
  });

  final List<ExtensionEntry> available;

  /// The selection journaled by an interrupted run of the same conversion,
  /// limited to sources still offered at the same version. Hosts may default
  /// to it; explicit user choices (for example `--extensions`) win.
  final List<ExtensionEntry> previousSelection;

  /// How many sources the rating policy hid.
  final int hiddenByRating;

  /// The languages the sources inside the picked extensions are narrowed to
  /// (`null`: not narrowed). Every extension of the user's repositories is
  /// offered; narrowing never hides an extension from the user.
  final Set<String>? languages;

  /// Runtime source IDs the user named (`--sources`); hosts pick the
  /// extensions that host them.
  final Set<String> explicitSources;
}

/// Unresolved chapters of one manga, for the user to resolve (KTD7).
final class ChapterAmbiguityRequest {
  const ChapterAmbiguityRequest({
    required this.mangaKey,
    required this.mangaTitle,
    required this.unresolved,
    required this.destinationChapters,
  });

  final String mangaKey;
  final String mangaTitle;

  /// Unmatched, ambiguous, and colliding source chapters.
  final List<UnresolvedChapter> unresolved;

  /// The complete, immutable destination chapter list.
  final List<PluginChapter> destinationChapters;
}

/// Every decision the conversion asks of a user (CLI or app adapter). The
/// core never reads terminal keys or presents native UI.
abstract interface class SelectionPort {
  /// Chooses which sources to use.
  Future<List<ExtensionEntry>> selectSources(SourceSelectionRequest request);

  /// Decides whether to trust a first-seen or changed repository signing
  /// fingerprint.
  Future<TrustDecision> decideRepositoryTrust(RepositoryTrustRequest request);

  /// Confirms manga matches (see [OnConfirmMatches]).
  Future<List<MangaMatchConfirmation>> confirmMatches(
    List<String> pluginNames,
    List<SourceMangaData> manga,
    Stream<PluginSearchEvent> Function(String query) onSearch,
    FetchDetails onFetchDetails,
  );

  /// Resolves unresolved chapters and collisions; an empty list leaves them
  /// unresolved.
  Future<List<ChapterDecision>> resolveChapters(ChapterAmbiguityRequest request);

  /// Whether to accept a partial conversion described by [report]. Declining
  /// publishes nothing.
  Future<bool> acceptPartialConversion(ConversionReport report);
}

/// A [SelectionPort] assembled from callbacks. Unset decisions default to
/// the conservative answer: reject trust, resolve nothing, decline partial
/// conversions unless [acceptPartial] is set.
final class CallbackSelectionPort implements SelectionPort {
  CallbackSelectionPort({
    required this.onSelectExtensions,
    required this.onConfirmMatches,
    this.onSelectSources,
    this.onRepositoryTrust,
    this.onResolveChapters,
    this.onAcceptPartial,
    this.acceptPartial = false,
  });

  final Future<List<ExtensionEntry>> Function(List<ExtensionEntry> extensions) onSelectExtensions;
  final OnConfirmMatches onConfirmMatches;

  /// Preferred over [onSelectExtensions] when set; also receives how many
  /// sources the rating policy hid.
  final Future<List<ExtensionEntry>> Function(SourceSelectionRequest request)? onSelectSources;
  final Future<TrustDecision> Function(RepositoryTrustRequest request)? onRepositoryTrust;
  final Future<List<ChapterDecision>> Function(ChapterAmbiguityRequest request)? onResolveChapters;
  final Future<bool> Function(ConversionReport report)? onAcceptPartial;

  /// Answer used when [onAcceptPartial] is not set (an unattended run's
  /// explicit `--accept-partial`).
  final bool acceptPartial;

  @override
  Future<List<ExtensionEntry>> selectSources(SourceSelectionRequest request) =>
      onSelectSources?.call(request) ?? onSelectExtensions(request.available);

  @override
  Future<TrustDecision> decideRepositoryTrust(RepositoryTrustRequest request) async =>
      await onRepositoryTrust?.call(request) ?? TrustDecision.reject;

  @override
  Future<List<MangaMatchConfirmation>> confirmMatches(
    List<String> pluginNames,
    List<SourceMangaData> manga,
    Stream<PluginSearchEvent> Function(String query) onSearch,
    FetchDetails onFetchDetails,
  ) => onConfirmMatches(pluginNames, manga, onSearch, onFetchDetails);

  @override
  Future<List<ChapterDecision>> resolveChapters(ChapterAmbiguityRequest request) async =>
      await onResolveChapters?.call(request) ?? const <ChapterDecision>[];

  @override
  Future<bool> acceptPartialConversion(ConversionReport report) async =>
      await onAcceptPartial?.call(report) ?? acceptPartial;
}
