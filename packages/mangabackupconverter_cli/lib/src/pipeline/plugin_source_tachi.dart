import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_loaders/source_loaders.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';

export 'package:source_loaders/source_loaders.dart' show TachiLoaderRuntime, TachiPluginLoader, tachiTrustEcosystem;

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
///
/// With a [browserPort], the worker's `host.browser.*` reverse requests
/// (the `android.webkit` shim) are served by it: each package may open
/// sessions only for the sources it enumerated
/// ([TachiRuntime.browserIdentity]).
final class DesktopTachiRuntime implements TachiLoaderRuntime {
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
    this.browserPort,
    this.browserReplacementTimeout,
    this.interactionTimeout,
  });

  /// Resolves where the worker is (see [TachiWorkerLocation.resolve]).
  final SourceOutcome<TachiWorkerLocation> Function() locate;
  final Directory cacheDirectory;
  @override
  final TachiFetch fetch;
  @override
  final TachiArtifactPolicy policy;

  /// Capture directories for replay mode (tests); empty for live runs.
  final List<String> replay;
  final String? stateDirectory;
  final WorkerLauncher? launcher;
  final void Function(String line)? onLog;
  final Redactor? redactor;

  /// The conversion's browser (the desktop WebView helper), or `null`:
  /// every browser request then fails as capability-unavailable.
  final BrowserPort? browserPort;

  /// How long a request held for the worker's replacement waits
  /// ([ConversionRuntimeScope.browserReplacementTimeout]).
  final Duration? browserReplacementTimeout;

  /// Bound on a visible browser interaction (`host.browser.show`).
  final Duration? interactionTimeout;

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
  @override
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
        late final TachiRuntime runtime;
        final scope = ConversionRuntimeScope(
          workers: <WorkerKind, WorkerSpec>{
            WorkerKind.jvm: location.spec(stateDirectory: stateDirectory, replay: replay),
          },
          limits: AdoptWorkerLimits(
            handshakeDeadline: location.handshakeDeadline,
            interactionTimeout: interactionTimeout,
          ),
          launcher: launcher,
          onLog: onLog,
          redactor: redactor,
          browserPort: browserPort,
          resolveBrowserSource: (WorkerKind kind, String? packageId, String sourceId) =>
              kind == WorkerKind.jvm ? runtime.browserIdentity(packageId, sourceId) : null,
          browserReplacementTimeout: browserReplacementTimeout,
        );
        _scope = scope;
        runtime = TachiRuntime(
          worker: () => scope.worker(WorkerKind.jvm),
          store: TachiArtifactStore(cache: ArtifactCache(cacheDirectory), fetch: fetch),
          catalog: TachiCatalog(fetch),
          policy: policy,
        );
        return SourceSuccess<TachiRuntime>(runtime);
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
