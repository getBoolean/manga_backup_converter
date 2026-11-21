import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';

/// Ecosystem name used for Tachi repository trust decisions.
const String tachiTrustEcosystem = tachiEcosystem;

/// Downloads over HTTP(S); non-200 responses throw.
Future<Uint8List> httpTachiFetch(Uri url) async {
  final http.Response response = await http.get(url);
  if (response.statusCode != 200) throw HttpException('HTTP ${response.statusCode}', uri: url);
  return response.bodyBytes;
}

/// The desktop Tachi runtime of one conversion (KTD1, KTD4 ownership).
///
/// Nothing starts until a Tachi package is loaded: the first [runtime] call
/// resolves the worker location, builds the [ConversionRuntimeScope] that
/// owns the single JVM worker, and hands it to the conversion owner given to
/// [attach], so the worker is closed in the pipeline's `finally`. Limits are
/// adopted from the worker's handshake (its benchmarked sizing rule); only
/// the handshake deadline comes from the location, and a location without
/// one is a typed [RuntimeUnavailableFailure] for every Tachi package.
final class DesktopTachiRuntime {
  DesktopTachiRuntime({
    required this.locate,
    required this.cacheDirectory,
    required this.fetch,
    this.policy = const TachiArtifactPolicy(),
    this.replay = const <String>[],
    this.stateDirectory,
    this.launcher,
    this.onLog,
    this.redactor,
  });

  /// Resolves where the worker is (see [TachiWorkerLocation.resolve]).
  final SourceOutcome<TachiWorkerLocation> Function() locate;
  final Directory cacheDirectory;
  final TachiFetch fetch;
  final TachiArtifactPolicy policy;

  /// Capture directories for replay mode (tests); empty for live runs.
  final List<String> replay;
  final String? stateDirectory;
  final WorkerLauncher? launcher;
  final void Function(String line)? onLog;
  final Redactor? redactor;

  ConversionOwner? _owner;
  ConversionRuntimeScope? _scope;
  SourceOutcome<TachiRuntime>? _runtime;

  /// The scope, once a Tachi package has been loaded.
  ConversionRuntimeScope? get scope => _scope;

  /// Registers the conversion owner; the scope it creates later is closed by
  /// that owner. Called from the pipeline's `onOwnerOpened`.
  Future<void> attach(ConversionOwner owner) {
    _owner = owner;
    return owner.adopt(() => _scope?.close());
  }

  /// The conversion's Tachi runtime, created on first use.
  SourceOutcome<TachiRuntime> runtime() => _runtime ??= _create();

  SourceOutcome<TachiRuntime> _create() {
    if (_owner == null || _owner!.isClosed) {
      return const SourceFailed<TachiRuntime>(
        RuntimeUnavailableFailure('No conversion owns the Tachi runtime (attach it before loading)'),
      );
    }
    switch (locate()) {
      case SourceFailed<TachiWorkerLocation>(:final SourceFailure failure):
        return SourceFailed<TachiRuntime>(failure);
      case SourceSuccess<TachiWorkerLocation>(value: final TachiWorkerLocation location):
        final scope = ConversionRuntimeScope(
          workers: <WorkerKind, WorkerSpec>{
            WorkerKind.jvm: location.spec(stateDirectory: stateDirectory, replay: replay),
          },
          limits: location.limits,
          launcher: launcher,
          onLog: onLog,
          redactor: redactor,
        );
        _scope = scope;
        return SourceSuccess<TachiRuntime>(
          TachiRuntime(
            worker: () => scope.worker(WorkerKind.jvm),
            store: TachiArtifactStore(cache: ArtifactCache(cacheDirectory), fetch: fetch),
            catalog: TachiCatalog(fetch),
            policy: policy,
          ),
        );
    }
  }
}

/// A [TrustStore] overlaid with explicitly pre-approved Tachi repository
/// fingerprints (`--trust-tachi-repo URL=SHA256`), so unattended runs can
/// admit a repository without a prompt (KTD5). A pin wins over a stored
/// fingerprint; anything else is read from and written to [inner].
final class PinnedTrustStore implements TrustStore {
  PinnedTrustStore(this.inner, Map<Uri, String> tachiPins)
    : _pins = <String, String>{
        for (final MapEntry<Uri, String> pin in tachiPins.entries)
          InMemoryTrustStore.keyOf(tachiTrustEcosystem, tachiRepositoryBase(pin.key)):
              ArtifactTrustAnchor.normalizeFingerprint(pin.value),
      };

  final TrustStore inner;
  final Map<String, String> _pins;

  /// Parses `URL=SHA256` pins; throws [FormatException] for malformed ones.
  static Map<Uri, String> parsePins(Iterable<String> values) {
    final pins = <Uri, String>{};
    for (final value in values) {
      final int i = value.lastIndexOf('=');
      final Uri? url = i > 0 ? Uri.tryParse(value.substring(0, i)) : null;
      if (url == null || (url.scheme != 'https' && url.scheme != 'http')) {
        throw FormatException('Expected URL=SHA256, got "$value"');
      }
      pins[url] = ArtifactTrustAnchor.normalizeFingerprint(value.substring(i + 1));
    }
    return pins;
  }

  @override
  Future<String?> fingerprintFor(String ecosystem, Uri repository) async =>
      _pins[InMemoryTrustStore.keyOf(ecosystem, repository)] ?? await inner.fingerprintFor(ecosystem, repository);

  @override
  Future<void> remember(String ecosystem, Uri repository, String fingerprint) =>
      inner.remember(ecosystem, repository, fingerprint);
}

/// Parses `--tachi-artifact` values: `jar|apk` (every repository),
/// `REPO_URL=jar|apk` (one repository) or `PACKAGE=jar|apk` (one package).
/// Throws [FormatException] for anything else.
TachiArtifactPolicy parseTachiArtifactOverrides(Iterable<String> values) {
  TachiArtifactKind kindOf(String value) => TachiArtifactKind.values.firstWhere(
    (TachiArtifactKind k) => k.name == value.toLowerCase(),
    orElse: () => throw FormatException('Tachi artifact kind must be jar or apk, got "$value"'),
  );
  TachiArtifactKind? all;
  final repositories = <Uri, TachiArtifactKind>{};
  final packages = <String, TachiArtifactKind>{};
  for (final value in values) {
    final int i = value.lastIndexOf('=');
    if (i < 0) {
      all = kindOf(value);
      continue;
    }
    final String target = value.substring(0, i);
    final TachiArtifactKind kind = kindOf(value.substring(i + 1));
    final Uri? uri = Uri.tryParse(target);
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      repositories[tachiRepositoryBase(uri)] = kind;
    } else if (target.isNotEmpty) {
      packages[target] = kind;
    } else {
      throw FormatException('Expected [REPO_URL|PACKAGE=]jar|apk, got "$value"');
    }
  }
  return TachiArtifactPolicy(all: all, repositories: repositories, packages: packages);
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

  final DesktopTachiRuntime runtime;

  /// Settings a package runs with.
  final SettingsSnapshot Function(TachiExtensionEntry entry) settingsFor;

  /// Receives each settings snapshot, so the host registers its secrets with
  /// the log redactor (KTD9).
  final void Function(SettingsSnapshot settings)? onSettings;

  static SettingsSnapshot _noSettings(TachiExtensionEntry entry) => SettingsSnapshot();

  final Map<String, _Admitted> _admitted = <String, _Admitted>{};

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
      final bool admitted =
          trust != null && await trust.admit(tachiTrustEcosystem, repository.baseUrl, repository.signingKeyFingerprint);
      if (!admitted) {
        onWarning?.call(
          'Repository ${repository.baseUrl} was not admitted: its signing fingerprint '
          '${repository.signingKeyFingerprint} is not trusted',
        );
        continue;
      }
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
        final plugins = <PluginSource>[for (final SourceSession s in package.sessions) SessionPluginSource(s)];
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

  static SourceFailure _notAdmitted(ExtensionEntry entry) => ArtifactIncompatibleFailure(
    'trust: ${entry.id} was not listed by an admitted Tachi repository in this run, so no trusted signer is known',
  );
}
