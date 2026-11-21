import 'dart:async';

import 'package:manga_backup_core/src/conversion/details_outcome.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:source_runtime/source_contracts.dart';

/// Temporary adapter from the backend-neutral [SourceSession] contract to the
/// pipeline's [PluginSource] boundary (KTD15). Every ecosystem reaches the
/// pipeline through this adapter, so search results carry the session's
/// durable [NativeMangaRef]s and detail calls return typed outcomes.
final class SessionPluginSource implements PluginSource {
  SessionPluginSource(this.session, {FutureOr<void> Function()? onDispose, this.language})
    : _onDispose = onDispose; // ignore: prefer_initializing_formals

  final SourceSession session;

  @override
  final String? language;
  final FutureOr<void> Function()? _onDispose;
  Future<void>? _disposing;

  @override
  SourceIdentity get identity => session.identity;

  @override
  String get settingsRevision => session.settingsRevision;

  @override
  String get sourceId => session.identity.sourceId;

  @override
  String get sourceName => session.displayName;

  @override
  Future<SourceOutcome<PluginSearchPageResult>> search(String query, int page) async {
    if (!session.capabilities.supports(SourceOperation.search)) {
      return SourceFailed<PluginSearchPageResult>(session.capabilities.unavailable(SourceOperation.search));
    }
    final SourceOutcome<SearchPage> outcome = await session.search(
      SearchRequest(query: query, cursor: page <= 1 ? null : '$page'),
    );
    return outcome.map(
      (SearchPage p) => PluginSearchPageResult(
        results: <PluginSearchResult>[
          for (final SearchHit hit in p.hits)
            PluginSearchResult(
              ref: hit.ref,
              pluginSourceName: sourceName,
              title: hit.title,
              coverUrl: hit.coverUrl,
              authors: hit.authors,
            ),
        ],
        hasNextPage: p.nextCursor != null,
        warnings: p.warnings,
      ),
    );
  }

  @override
  Future<DetailsOutcome> fetchDetails(NativeMangaRef ref) async {
    final StaleReferenceFailure? stale = staleReferenceFor(session, ref);
    if (stale != null) return DetailsFailed(stale);
    return DetailsOutcome.fromSnapshot(await session.fetchManga(ref));
  }

  @override
  Future<void> dispose() => _disposing ??= () async {
    await session.close();
    await _onDispose?.call();
  }();
}
