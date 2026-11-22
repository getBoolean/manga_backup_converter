import 'dart:async';
import 'dart:typed_data';

import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_loaders/src/provider_plugin_loader.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';

/// Ecosystem name used for Tachi repository trust decisions.
const String tachiTrustEcosystem = tachiEcosystem;

/// What [TachiPluginLoader] needs from a host's Tachi runtime: how it
/// downloads catalogs and artifacts, which artifact kind it picks, and the
/// conversion's [TachiRuntime], created on first use (a typed failure when
/// the host cannot run one).
abstract interface class TachiLoaderRuntime {
  TachiFetch get fetch;
  TachiArtifactPolicy get policy;
  SourceOutcome<TachiRuntime> runtime();
}

/// A listing admitted through the trust gate in this run, with the artifact
/// chosen for it and the fingerprint the gate approved.
final class _Admitted {
  const _Admitted(this.listing, this.choice, this.trust);

  final TachiPackageListing listing;
  final TachiArtifactChoice choice;
  final TachiTrustIdentity trust;
}

/// Tachi loader: lists repositories through `repo.json` → `index.json`,
/// admits each repository's signing fingerprint through the core trust gate,
/// and loads each selected package through the conversion's single JVM
/// worker, returning every source the package enumerates.
///
/// Entries are package-level. Only entries listed by this loader after their
/// repository was admitted can load; their trust anchor is the fingerprint
/// the gate admitted, never one read beside the artifact. Capability and
/// trust failures are typed load failures, never stub sources.
class TachiPluginLoader extends ProviderPluginLoader<TachiExtensionEntry> {
  TachiPluginLoader({required this.runtime, super.settingsFor, super.onSettings, super.cache});

  /// The conversion's Tachi runtime: the desktop JVM worker in the CLI, the
  /// embedded VM on iOS.
  final TachiLoaderRuntime runtime;

  final Map<String, _Admitted> _admitted = <String, _Admitted>{};

  /// Trust failures of repositories this run refused, by base URL.
  final Map<String, TrustFailure> _refused = <String, TrustFailure>{};

  TachiCatalog get _catalog => TachiCatalog(runtime.fetch);

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async {
    final entries = <ExtensionEntry>[];
    for (final url in repoUrls) {
      final TachiRepository repository;
      try {
        repository = await _catalog.fetchRepository(Uri.parse(url));
      } on Exception catch (e) {
        onWarning?.call('Failed to fetch repo $url: $e');
        continue;
      }
      // KTD5: a repository is used only after its published fingerprint is
      // trusted (stored, pinned, or approved now through the SelectionPort).
      final TrustFailure? refused = trust == null
          ? TrustFailure(TrustFailureReason.firstSeen, 'No trust gate in this run for ${repository.baseUrl}')
          : await trust.check(tachiTrustEcosystem, repository.baseUrl, repository.signingKeyFingerprint);
      if (refused != null) {
        _refused[repository.baseUrl.toString()] = refused;
        onWarning?.call(
          'Repository ${repository.baseUrl} was not admitted (${refused.reason.wire}): ${refused.message}',
        );
        continue;
      }
      _refused.remove(repository.baseUrl.toString());
      final trustIdentity = TachiTrustIdentity(
        repository: repository.baseUrl,
        fingerprint: repository.signingKeyFingerprint,
      );
      final List<TachiPackageListing> listings;
      try {
        listings = await _catalog.fetchPackages(repository);
      } on Exception catch (e) {
        onWarning?.call('Failed to read the index of ${repository.baseUrl}: $e');
        continue;
      }
      for (final listing in listings) {
        switch (runtime.policy.select(listing)) {
          case SourceFailed<TachiArtifactChoice>(:final SourceFailure failure):
            onWarning?.call(failure.message);
          case SourceSuccess<TachiArtifactChoice>(value: final TachiArtifactChoice choice):
            final entry = TachiExtensionEntry(
              id: listing.packageId,
              name: listing.name,
              repositoryUrl: repository.baseUrl.toString(),
              versionName: listing.versionName,
              versionCode: listing.versionCode,
              artifactKind: choice.kind.name,
              languages: listing.languages,
              contentRating: SourceRatingPolicy.ratingOf(listing.contentRating),
              sourceIds: <String>[for (final TachiIndexSource s in listing.sources) s.id.decimal],
            );
            _admitted[_keyOf(entry)] = _Admitted(listing, choice, trustIdentity);
            entries.add(entry);
        }
      }
    }
    return entries;
  }

  /// Downloads the artifact chosen for [entry]; an entry this loader did not
  /// admit fails as a typed trust failure without any download.
  @override
  Future<SourceOutcome<Uint8List>> download(TachiExtensionEntry entry) async {
    final _Admitted? admitted = _admittedFor(entry);
    if (admitted == null) return SourceFailed<Uint8List>(_notAdmitted(entry));
    try {
      return SourceSuccess<Uint8List>(await runtime.fetch(admitted.choice.url));
    } on Exception catch (e) {
      return SourceFailed<Uint8List>(SourceErrorFailure('Download of ${admitted.choice.url} failed: $e'));
    }
  }

  /// Prepares [bytes] in the shared worker (signature verified against the
  /// admitted repository fingerprint, APKs converted) and loads the package,
  /// returning a source per enumerated source ID.
  @override
  Future<SourceOutcome<List<PluginSource>>> open(
    TachiExtensionEntry entry,
    Uint8List bytes,
    SettingsSnapshot settings,
    ConversionOwner? owner,
  ) async {
    final _Admitted? admitted = _admittedFor(entry);
    if (admitted == null) return SourceFailed<List<PluginSource>>(_notAdmitted(entry));
    return runtime.runtime().andThen(
      (TachiRuntime tachi) => tachi
          .prepare(admitted.listing, admitted.choice, trust: admitted.trust, bytes: bytes)
          .andThen((TachiPreparedArtifact artifact) => tachi.openPackage(artifact, settings))
          .andThen(
            (SourcePackage package) => ProviderPluginLoader.adoptPackage(
              package,
              owner,
              close: package.close,
              // Each source keeps its index language, so the pipeline can
              // narrow a multi-language package to the backup's languages.
              plugins: (List<SourceSession> sessions) => <PluginSource>[
                for (final SourceSession s in sessions)
                  SessionPluginSource(s, language: s is TachiSourceSession ? s.language : null),
              ],
            ),
          ),
    );
  }

  _Admitted? _admittedFor(ExtensionEntry entry) => entry is TachiExtensionEntry ? _admitted[_keyOf(entry)] : null;

  /// Two repositories may list the same package and version; each entry
  /// keeps its own repository's URL and trust.
  static String _keyOf(TachiExtensionEntry entry) => '${entry.repositoryUrl}|${entry.cacheKey}';

  /// Why [entry] cannot load: its repository's trust failure from this run
  /// (first-seen, changed or refused), or first-seen when no admitted
  /// repository listed it.
  SourceFailure _notAdmitted(ExtensionEntry entry) =>
      (entry is TachiExtensionEntry ? _refused[entry.repositoryUrl] : null) ??
      TrustFailure(
        TrustFailureReason.firstSeen,
        '${entry.id} was not listed by an admitted Tachi repository in this run, so no trusted signer is known',
      );
}
