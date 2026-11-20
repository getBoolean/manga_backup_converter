import 'dart:async';
import 'dart:typed_data';

import 'package:aidoku_plugin_loader/src/aidoku/aidoku_plugin.dart';
import 'package:aidoku_plugin_loader/src/models/chapter.dart';
import 'package:aidoku_plugin_loader/src/models/manga.dart';
import 'package:aidoku_plugin_loader/src/source_list/source_entry.dart';
import 'package:aidoku_plugin_loader/src/source_list/source_list.dart';
import 'package:aidoku_plugin_loader/src/source_list/source_list_manager.dart';
import 'package:http/http.dart' as http;
import 'package:source_runtime/source_contracts.dart';

/// Loads an `.aix` plugin; [AidokuPlugin.fromAix] by default. Injected so
/// tests and composition roots control plugin construction.
typedef AidokuPluginLoader =
    Future<AidokuPlugin> Function(Uint8List aixBytes, {Map<String, dynamic>? defaults, http.Client? httpClient});

/// Maps a settings snapshot to Aidoku `defaults` (raw keys, no source prefix).
typedef AidokuDefaultsMapper = Map<String, dynamic> Function(SettingsSnapshot settings);

/// The default [AidokuDefaultsMapper]: every setting keeps its Dart type, so
/// [AidokuPlugin.fromAix] postcard-encodes it as the source reads it — `bool`
/// with `writeBool`, `int` with `writeSignedVarInt` (zigzag varint), `String`
/// with `writeString`. Secrets are strings and win over a non-secret value
/// with the same key.
Map<String, dynamic> aidokuDefaultsFor(SettingsSnapshot settings) => <String, dynamic>{
  ...settings.values,
  ...settings.secrets,
};

Future<AidokuPlugin> _loadAix(Uint8List aixBytes, {Map<String, dynamic>? defaults, http.Client? httpClient}) =>
    AidokuPlugin.fromAix(aixBytes, defaults: defaults, httpClient: httpClient);

/// Aidoku behind the backend-neutral [SourceProvider] contract (KTD3, KTD15).
///
/// Aidoku keeps executing in its existing WASM host; this adapter only maps
/// the contract onto `AidokuPlugin`. A package yields exactly one source.
class AidokuSourceProvider implements SourceProvider {
  AidokuSourceProvider({
    this.httpClient,
    AidokuPluginLoader? loadPlugin,
    AidokuDefaultsMapper? defaultsFor,
  }) : _loadPlugin = loadPlugin ?? _loadAix,
       _defaultsFor = defaultsFor ?? aidokuDefaultsFor;

  /// Client for repository discovery and plugin network requests; `null`
  /// uses the loader's shared client. Tests pass a replay client.
  final http.Client? httpClient;
  final AidokuPluginLoader _loadPlugin;
  final AidokuDefaultsMapper _defaultsFor;

  /// Artifact kind accepted by [openPackage].
  static const String artifactKind = 'aix';

  @override
  String get ecosystem => 'aidoku';

  @override
  Future<SourceOutcome<List<PackageListing>>> discoverPackages(Uri repository, {CancellationToken? cancel}) async {
    try {
      final RemoteSourceList list = await SourceListManager(
        httpClient: httpClient,
      ).fetchRemoteSourceList(repository.toString());
      if (cancel?.isCancelled ?? false) return const SourceFailed<List<PackageListing>>(CancelledFailure('cancelled'));
      return SourceSuccess<List<PackageListing>>(<PackageListing>[
        for (final SourceEntry e in list.sources)
          PackageListing(
            packageId: e.id,
            name: e.name,
            version: '${e.version}',
            downloadUrl: repository.resolve(e.downloadUrl),
            languages: e.languages,
            contentRating: switch (e.contentRating) {
              0 => ContentRatingLevel.safe,
              1 => ContentRatingLevel.suggestive,
              2 => ContentRatingLevel.nsfw,
              _ => ContentRatingLevel.unknown,
            },
          ),
      ]);
    } on Object catch (e) {
      return SourceFailed<List<PackageListing>>(SourceErrorFailure('Could not list $repository: $e'));
    }
  }

  @override
  Future<SourceOutcome<SourcePackage>> openPackage(
    VerifiedArtifact artifact,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  }) async {
    if (artifact.binding.kind != artifactKind) {
      return SourceFailed<SourcePackage>(
        ArtifactIncompatibleFailure('Aidoku expects an "$artifactKind" artifact, got "${artifact.binding.kind}"'),
      );
    }
    final Uint8List bytes;
    try {
      bytes = await artifact.readVerified();
    } on Object catch (e) {
      return SourceFailed<SourcePackage>(ArtifactIncompatibleFailure('Artifact failed verification: $e'));
    }
    final AidokuPlugin plugin;
    try {
      plugin = await _loadPlugin(bytes, defaults: _defaultsFor(settings), httpClient: httpClient);
    } on Object catch (e) {
      return SourceFailed<SourcePackage>(ArtifactIncompatibleFailure('Could not load Aidoku plugin: $e'));
    }
    if (cancel?.isCancelled ?? false) {
      plugin.dispose();
      return const SourceFailed<SourcePackage>(CancelledFailure('cancelled'));
    }
    final session = AidokuSourceSession(
      plugin,
      identity: SourceIdentity(
        ecosystem: ecosystem,
        packageId: plugin.sourceInfo.id,
        sourceId: plugin.sourceInfo.id,
        artifact: artifact.binding,
      ),
      settingsRevision: settings.revision,
    );
    return SourceSuccess<SourcePackage>(_AidokuPackage(session));
  }
}

final class _AidokuPackage implements SourcePackage {
  _AidokuPackage(this._session);

  final AidokuSourceSession _session;

  @override
  String get packageId => _session.identity.packageId;

  @override
  List<SourceSession> get sessions => <SourceSession>[_session];

  @override
  Future<void> close() => _session.close();
}

/// One Aidoku source as a [SourceSession].
///
/// Calls are serialised (WASM plugins are single-threaded). Cancelling an
/// in-progress call answers the caller at once; the plugin call finishes in
/// the background and the next call waits for it. Search pagination uses
/// the page number as the opaque cursor.
class AidokuSourceSession implements SourceSession {
  AidokuSourceSession(this._plugin, {required this.identity, required this.settingsRevision});

  final AidokuPlugin _plugin;

  @override
  final SourceIdentity identity;

  @override
  final String settingsRevision;

  @override
  late final SourceCapabilities capabilities = SourceCapabilities(
    operations: const <SourceOperation>{
      SourceOperation.search,
      SourceOperation.mangaDetails,
      SourceOperation.chapterList,
    },
    apiFamilies: const <String>{'aidoku-wasm'},
  );

  Future<void> _tail = Future<void>.value();
  bool _closed = false;

  @override
  String get displayName => _plugin.sourceInfo.name;

  Future<SourceOutcome<T>> _serial<T>(CancellationToken? cancel, Future<SourceOutcome<T>> Function() body) async {
    if (_closed) return SourceFailed<T>(const RuntimeUnavailableFailure('Session closed'));
    final Future<void> previous = _tail;
    final done = Completer<SourceOutcome<T>>();
    _tail = done.future.then((_) {}, onError: (Object _) {});
    unawaited(
      previous.then((_) async {
        if (cancel?.isCancelled ?? false) {
          done.complete(SourceFailed<T>(CancelledFailure(cancel?.reason ?? 'cancelled')));
          return;
        }
        try {
          done.complete(await body());
        } on Object catch (e) {
          done.complete(SourceFailed<T>(SourceErrorFailure('$e')));
        }
      }),
    );
    if (cancel == null) return done.future;
    return Future.any(<Future<SourceOutcome<T>>>[
      done.future,
      cancel.whenCancelled.then((_) => SourceFailed<T>(CancelledFailure(cancel.reason ?? 'cancelled'))),
    ]);
  }

  @override
  Future<SourceOutcome<SearchPage>> search(SearchRequest request, {CancellationToken? cancel}) {
    final int? page = request.cursor == null ? 1 : int.tryParse(request.cursor!);
    if (page == null || page < 1) {
      return Future<SourceOutcome<SearchPage>>.value(
        SourceFailed<SearchPage>(StaleReferenceFailure('Invalid Aidoku page cursor "${request.cursor}"')),
      );
    }
    return _serial(cancel, () async {
      final MangaPageResult result = await _plugin.searchManga(request.query, page);
      return SourceSuccess<SearchPage>(
        SearchPage(
          hits: <SearchHit>[
            for (final Manga m in result.manga)
              SearchHit(
                ref: NativeMangaRef(
                  source: identity,
                  mangaId: m.key,
                  settingsRevision: settingsRevision,
                  context: <String, Object?>{'url': ?m.url},
                ),
                title: m.title,
                coverUrl: m.coverUrl,
                authors: m.authors,
              ),
          ],
          nextCursor: result.hasNextPage ? '${page + 1}' : null,
          warnings: _plugin.drainWarnings(),
        ),
      );
    });
  }

  @override
  Future<SourceOutcome<MangaSnapshot>> fetchManga(NativeMangaRef ref, {CancellationToken? cancel}) {
    final StaleReferenceFailure? stale = staleReferenceFor(this, ref);
    if (stale != null) return Future<SourceOutcome<MangaSnapshot>>.value(SourceFailed<MangaSnapshot>(stale));
    return _serial(cancel, () async {
      final Manga? manga = await _plugin.getMangaDetails(ref.mangaId, includeChapters: true);
      final List<String> warnings = _plugin.drainWarnings();
      if (manga == null) {
        // Missing data is a typed failure, never an empty successful snapshot.
        return SourceFailed<MangaSnapshot>(
          SourceErrorFailure(
            'Aidoku source ${identity.sourceId} returned no details for ${ref.mangaId}'
            '${warnings.isEmpty ? '' : ': ${warnings.join('; ')}'}',
          ),
        );
      }
      return SourceSuccess<MangaSnapshot>(
        MangaSnapshot(
          ref: ref.withHandle(null),
          metadata: MangaMetadata(
            title: manga.title,
            authors: manga.authors,
            artists: manga.artists,
            description: manga.description,
            tags: manga.tags,
            status: switch (manga.status) {
              MangaStatus.unknown => PublishingStatus.unknown,
              MangaStatus.ongoing => PublishingStatus.ongoing,
              MangaStatus.completed => PublishingStatus.completed,
              MangaStatus.cancelled => PublishingStatus.cancelled,
              MangaStatus.hiatus => PublishingStatus.hiatus,
            },
            contentRating: switch (manga.contentRating) {
              ContentRating.safe => ContentRatingLevel.safe,
              ContentRating.suggestive => ContentRatingLevel.suggestive,
              ContentRating.nsfw => ContentRatingLevel.nsfw,
            },
            url: manga.url,
            coverUrl: manga.coverUrl,
          ),
          chapters: <NativeChapter>[
            for (final (int i, Chapter c) in manga.chapters.indexed)
              NativeChapter(
                chapterId: c.key,
                sourceOrder: i,
                title: c.title,
                chapterNumber: c.chapterNumber,
                volumeNumber: c.volumeNumber,
                scanlators: c.scanlators,
                language: c.language,
                dateUploaded: c.dateUploaded,
                url: c.url,
              ),
          ],
        ),
      );
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _tail;
    _plugin.dispose();
  }
}
