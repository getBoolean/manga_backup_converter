import 'package:source_runtime/src/backends/protocol_payloads.dart';
import 'package:source_runtime/src/backends/worker_supervisor.dart';
import 'package:source_runtime/src/contracts/cancellation.dart';
import 'package:source_runtime/src/contracts/identity.dart';
import 'package:source_runtime/src/contracts/outcome.dart';
import 'package:source_runtime/src/contracts/source.dart';

/// A [SourceSession] backed by a source hosted in a supervised worker.
///
/// Searches for one source coalesce (newest query wins). Ephemeral session
/// handles are forwarded only within the generation that issued them; after a
/// restart the worker receives the durable native reference alone and must
/// rehydrate from it (KTD3).
///
/// [settingsRevision] follows the package's current settings in the
/// supervisor, so after [WorkerSupervisor.updateSettings] references
/// confirmed under the previous revision are stale.
class WorkerSourceSession implements SourceSession {
  WorkerSourceSession({
    required this.supervisor,
    required this.identity,
    required this.displayName,
    required this.capabilities,
    required String settingsRevision,
  }) : _initialRevision = settingsRevision;

  final WorkerSupervisor supervisor;

  @override
  final SourceIdentity identity;

  @override
  final String displayName;

  @override
  final SourceCapabilities capabilities;

  final String _initialRevision;

  @override
  String get settingsRevision => supervisor.settingsOf(identity.packageId)?.revision ?? _initialRevision;

  bool _closed = false;

  @override
  Future<SourceOutcome<SearchPage>> search(SearchRequest request, {CancellationToken? cancel}) async {
    if (_closed) return const SourceFailed<SearchPage>(RuntimeUnavailableFailure('Session closed'));
    if (!capabilities.supports(SourceOperation.search)) {
      return SourceFailed<SearchPage>(capabilities.unavailable(SourceOperation.search));
    }
    final SourceOutcome<WorkerSearchResponse> outcome = await supervisor.send(
      identity.packageId,
      WorkerSearchRequest(source: identity, settingsRevision: settingsRevision, request: request),
      cancel: cancel,
      coalesceKey: 'search:${identity.sourceId}',
    );
    return outcome.map((WorkerSearchResponse ok) {
      // The reply came from the current worker, so its handles belong to the
      // current generation.
      final int replyGeneration = supervisor.generation;
      return SearchPage(
        hits: <SearchHit>[
          for (final WorkerSearchHit h in ok.hits)
            SearchHit(
              ref: h.hit.ref.withHandle(
                h.handle == null ? null : SessionHandle(generation: replyGeneration, value: h.handle!),
              ),
              title: h.hit.title,
              coverUrl: h.hit.coverUrl,
              authors: h.hit.authors,
            ),
        ],
        nextCursor: ok.nextCursor,
        warnings: ok.warnings,
      );
    });
  }

  @override
  Future<SourceOutcome<MangaSnapshot>> fetchManga(NativeMangaRef ref, {CancellationToken? cancel}) async {
    if (_closed) return const SourceFailed<MangaSnapshot>(RuntimeUnavailableFailure('Session closed'));
    if (!capabilities.supports(SourceOperation.mangaDetails)) {
      return SourceFailed<MangaSnapshot>(capabilities.unavailable(SourceOperation.mangaDetails));
    }
    final StaleReferenceFailure? stale = staleReferenceFor(this, ref);
    if (stale != null) return SourceFailed<MangaSnapshot>(stale);
    final SessionHandle? handle = ref.handle;
    final SourceOutcome<WorkerDetailsResponse> outcome = await supervisor.send(
      identity.packageId,
      WorkerDetailsRequest(
        source: identity,
        settingsRevision: settingsRevision,
        ref: ref,
        handle: handle != null && handle.generation == supervisor.generation ? handle.value : null,
      ),
      cancel: cancel,
    );
    return outcome.map(
      (WorkerDetailsResponse ok) =>
          MangaSnapshot(ref: ref.withHandle(null), metadata: ok.metadata, chapters: ok.chapters),
    );
  }

  /// Closes the session and asks the worker to drop every live object it
  /// cached for this source (`dispose`). Durable references stay valid.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (supervisor.state != WorkerState.ready || supervisor.settingsOf(identity.packageId) == null) return;
    // Best effort: a failed dispose only delays freeing worker memory.
    await supervisor.send(identity.packageId, DisposeRequest(source: identity));
  }
}
