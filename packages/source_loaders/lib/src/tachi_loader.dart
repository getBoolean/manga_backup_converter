import 'dart:async';
import 'dart:typed_data';

import 'package:manga_backup_core/manga_backup_core.dart';
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
class TachiPluginLoader extends PluginLoader {
  TachiPluginLoader({required this.runtime, this.settingsFor = _noSettings, this.onSettings});

  /// The conversion's Tachi runtime: the desktop JVM worker in the CLI, the
  /// embedded VM on iOS.
  final TachiLoaderRuntime runtime;

  /// Settings a package runs with.
  final SettingsSnapshot Function(TachiExtensionEntry entry) settingsFor;

  /// Receives each settings snapshot, so the host registers its secrets with
  /// the log redactor (KTD9).
  final void Function(SettingsSnapshot settings)? onSettings;

  static SettingsSnapshot _noSettings(TachiExtensionEntry entry) => SettingsSnapshot();

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
        onWarning?.call('Repository ${repository.baseUrl} was not admitted (${refused.reason.wire}): ${refused.message}');
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

  @override
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  }) async {
    final plugins = <PluginSource>[];
    for (final (int i, ExtensionEntry entry) in extensions.indexed) {
      void fail(SourceFailure failure) {
        onFailure?.call(PluginLoadFailure(extensionId: entry.id, failure: failure));
        onProgress?.call(i + 1, extensions.length, 'Warning: failed to load ${entry.name}: ${failure.message}');
      }

      onProgress?.call(i + 1, extensions.length, 'Loading package: ${entry.name}');
      final _Admitted? admitted = _admittedFor(entry);
      if (admitted == null) {
        fail(_notAdmitted(entry));
        continue;
      }
      final Uint8List bytes;
      try {
        bytes = await runtime.fetch(admitted.choice.url);
      } on Exception catch (e) {
        fail(SourceErrorFailure('Download of ${admitted.choice.url} failed: $e'));
        continue;
      }
      switch (await loadPluginFromBytes(entry, bytes, owner: owner)) {
        case SourceSuccess<List<PluginSource>>(:final List<PluginSource> value):
          plugins.addAll(value);
        case SourceFailed<List<PluginSource>>(:final SourceFailure failure):
          fail(failure);
      }
    }
    return plugins;
  }

  /// Downloads the artifact chosen for [entry]; `null` (no download) for an
  /// entry this loader did not admit, which then fails as a typed trust
  /// failure when loaded.
  @override
  Future<Uint8List?> downloadPluginBytes(ExtensionEntry entry) async {
    final _Admitted? admitted = _admittedFor(entry);
    return admitted == null ? null : runtime.fetch(admitted.choice.url);
  }

  /// Prepares [bytes] in the shared worker (signature verified against the
  /// admitted repository fingerprint, APKs converted) and loads the package,
  /// returning a source per enumerated source ID. Each source and the package
  /// are adopted into [owner] as soon as they open.
  @override
  Future<SourceOutcome<List<PluginSource>>> loadPluginFromBytes(
    ExtensionEntry entry,
    Uint8List bytes, {
    ConversionOwner? owner,
  }) async {
    final _Admitted? admitted = _admittedFor(entry);
    if (admitted == null) return SourceFailed<List<PluginSource>>(_notAdmitted(entry));
    final TachiRuntime tachi;
    switch (runtime.runtime()) {
      case SourceFailed<TachiRuntime>(:final SourceFailure failure):
        return SourceFailed<List<PluginSource>>(failure);
      case SourceSuccess<TachiRuntime>(:final TachiRuntime value):
        tachi = value;
    }
    final SourceOutcome<TachiPreparedArtifact> prepared = await tachi.prepare(
      admitted.listing,
      admitted.choice,
      trust: admitted.trust,
      bytes: bytes,
    );
    final TachiPreparedArtifact artifact;
    switch (prepared) {
      case SourceFailed<TachiPreparedArtifact>(:final SourceFailure failure):
        return SourceFailed<List<PluginSource>>(failure);
      case SourceSuccess<TachiPreparedArtifact>(:final TachiPreparedArtifact value):
        artifact = value;
    }
    final SettingsSnapshot settings = settingsFor(entry as TachiExtensionEntry);
    onSettings?.call(settings);
    switch (await tachi.openPackage(artifact, settings)) {
      case SourceFailed<SourcePackage>(:final SourceFailure failure):
        return SourceFailed<List<PluginSource>>(failure);
      case SourceSuccess<SourcePackage>(value: final SourcePackage package):
        await owner?.adopt(package.close);
        // Each source keeps its index language, so the pipeline can narrow a
        // multi-language package to the backup's languages.
        final plugins = <PluginSource>[
          for (final SourceSession s in package.sessions)
            SessionPluginSource(s, language: s is TachiSourceSession ? s.language : null),
        ];
        for (final plugin in plugins) {
          await owner?.adopt(plugin.dispose);
        }
        return SourceSuccess<List<PluginSource>>(plugins);
    }
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
