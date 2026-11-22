// The app's composition root for source runtimes (KTD14, KTD15).
//
// Each platform registers the same three local runtimes; only the backends
// behind them differ:
// - iOS (U15, conversion_composition_ios.dart): Aidoku in wasm3/SwiftSoup
//   (`IosAidokuBackend`), Paperback in a QuickJS worker isolate, Tachi in the
//   process-lifetime embedded JVM; one WKWebView `BrowserPort`.
// - Android (U14, conversion_composition_android.dart): Aidoku in wasm3 and
//   the Rust scraper (`AndroidAidokuBackend`), Paperback in a QuickJS worker
//   isolate, Tachi APK sources in the private `:source_runtime` service
//   process (`AndroidTachiBackend`); the app-process WebView `BrowserPort`
//   serves Paperback, while Tachi's WebViews run inside the service.
//
// [LocalSourceRuntimes] holds what both share: the runtime registry, the
// per-conversion scopes adopted by the job's `ConversionOwner`, the
// Paperback worker isolate and secret registration.
//
// Everything source-related is the user's: no repository, extension or
// settings default exists here. The app passes the repositories in each
// `ConversionRequest`, the extension picks through its `SelectionPort`, and
// the settings through `ConversionService.convert(settingsFor:)`. Nothing
// starts at app launch: a platform's runtimes start when the app calls its
// `start`, and workers start when a conversion first loads a package.

import 'dart:async';
import 'dart:io';

import 'package:aidoku_plugin_loader/source_adapter.dart'
    show AidokuSourceProvider;
import 'package:http/http.dart' as http;
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter/src/features/conversion/application/conversion_service.dart';
import 'package:paperback_plugin_loader/paperback_plugin_loader.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:source_loaders/source_loaders.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_android/source_runtime_android.dart';
import 'package:source_runtime_ios/source_runtime_ios.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';

part 'conversion_composition_android.dart';
part 'conversion_composition_ios.dart';

/// The worker spec of the in-app Paperback isolate (no executable runs).
const WorkerSpec inAppPaperbackWorkerSpec = WorkerSpec(
  label: 'paperback',
  executable: 'in-app-isolate',
);

/// What every platform's local runtimes run with. Production passes live
/// clients; the integration harnesses pass replaying ones, so no test
/// reaches a server.
abstract base class LocalRuntimeConfig {
  LocalRuntimeConfig({
    required this.storageRoot,
    required this.interactionTimeout,
    http.Client? client,
    this.aidokuSiteClient,
    this.paperbackSiteClient = _liveClient,
    TachiFetch? tachiFetch,
    this.tachiPolicy = const TachiArtifactPolicy(),
    this.paperbackPlan,
    this.onLog,
    Redactor? redactor,
  }) : client = client ?? http.Client(),
       redactor = redactor ?? Redactor() {
    this.tachiFetch = tachiFetch ?? _httpFetch(this.client);
  }

  /// App-private directory for artifact caches and worker state.
  final Directory storageRoot;

  /// Bound on a visible browser interaction (`host.browser.show`).
  final Duration interactionTimeout;

  /// Catalogs, Paperback bundles and `.aix` downloads (root isolate).
  final http.Client client;

  /// Aidoku source traffic; a new live client per plugin when `null`.
  final http.Client? aidokuSiteClient;

  /// Paperback source traffic, created inside the worker isolate. It must
  /// capture only sendable state.
  final PaperbackClientFactory paperbackSiteClient;

  /// Tachi `repo.json`/`index.json` and artifact downloads.
  late final TachiFetch tachiFetch;
  final TachiArtifactPolicy tachiPolicy;

  /// The Paperback worker plan; measured on this device when `null`.
  final PaperbackWorkerPlan? paperbackPlan;

  /// Diagnostic lines, already redacted.
  final void Function(String line)? onLog;

  /// Every log line and failure message passes through it; settings secrets
  /// are registered as sources open (KTD9).
  final Redactor redactor;

  static http.Client _liveClient() => http.Client();

  static TachiFetch _httpFetch(http.Client client) => (Uri url) async {
    final http.Response response = await client.get(url);
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    return response.bodyBytes;
  };
}

/// The device's local source runtimes, created once per app process and
/// shared by every conversion. Per-conversion scopes (the Paperback worker
/// isolate, the Tachi worker, their browser bridges) are created on first
/// use and closed by the conversion's owner ([attach]).
abstract base class LocalSourceRuntimes {
  LocalSourceRuntimes._({
    required this.config,
    required SourceOutcome<SourceProvider> aidoku,
    required this.browserPort,
    required this.paperbackPlan,
    this.browserUnavailable,
    this.workerGate,
  }) : _aidokuProvider = aidoku;

  final LocalRuntimeConfig config;
  final SourceOutcome<SourceProvider> _aidokuProvider;

  /// The browser port Paperback's `executeInWebView` uses, or `null` when
  /// the platform could not start one ([browserUnavailable] says why).
  final BrowserPort? browserPort;

  /// Why [browserPort] is `null`, when it is.
  final SourceFailure? browserUnavailable;

  final PaperbackWorkerPlan paperbackPlan;

  /// The app-lifecycle gate the conversion's workers (Paperback isolate,
  /// Tachi worker) pass through, or `null` where the platform gates only
  /// Aidoku (iOS).
  final BackgroundGate? workerGate;

  _ConversionScope? _current;

  /// The current conversion's Paperback worker scope, once started.
  ConversionRuntimeScope? get paperbackScope => _current?.paperback;

  /// Why Paperback cannot run on this device, or `null`.
  SourceFailure? _paperbackProbe() => null;

  /// Why Tachi cannot run on this device, or `null`.
  SourceFailure? _tachiProbe();

  /// The current conversion's [TachiRuntime], created in [scope].
  SourceOutcome<TachiRuntime> _openTachi(_ConversionScope scope);

  /// The runtime registry for [ConversionService]: one entry per ecosystem,
  /// each probed without starting anything.
  late final RuntimeRegistry registry = RuntimeRegistry(<DestinationRuntime>[
    DestinationRuntime(
      ecosystem: 'aidoku',
      serves: (BackupFormat f) => f is Aidoku,
      probe: () => _aidokuProvider.failureOrNull,
      createLoader: (RuntimeContext context) => AidokuPluginLoader(
        providerFactory: () => _aidokuProvider.valueOrNull!,
        client: config.client,
        onSettings: _registerSecrets,
        settingsFor: context.settingsFor,
      ),
    ),
    DestinationRuntime(
      ecosystem: 'paperback',
      serves: (BackupFormat f) => f is Paperback,
      probe: _paperbackProbe,
      createLoader: (RuntimeContext context) => PaperbackPluginLoader(
        client: config.client,
        cache: ArtifactCache(
          Directory('${config.storageRoot.path}/paperback_artifacts'),
        ),
        worker: _paperbackWorker,
        onSettings: _registerSecrets,
        settingsFor: context.settingsFor,
      ),
    ),
    DestinationRuntime(
      ecosystem: tachiTrustEcosystem,
      serves: (BackupFormat f) => f is Tachiyomi,
      probe: _tachiProbe,
      createLoader: (RuntimeContext context) => TachiPluginLoader(
        runtime: _TachiLoaderRuntime(this),
        onSettings: _registerSecrets,
        settingsFor: context.settingsFor,
      ),
    ),
  ]);

  /// A [ConversionService] over [registry] that attaches each conversion.
  ConversionService service({TrustStore? trustStore}) => ConversionService(
    runtimes: registry,
    trustStore: trustStore,
    redact: config.redactor.redact,
    onOwnerOpened: attach,
  );

  /// Makes [owner] the current conversion: scopes created for it from now
  /// on are adopted by it and closed when it closes.
  Future<void> attach(ConversionOwner owner) async {
    final scope = _ConversionScope(owner);
    _current = scope;
    await owner.adopt(() async {
      if (identical(_current, scope)) _current = null;
      await scope.close();
    });
  }

  /// Closes the current conversion's scopes. Platform subclasses also close
  /// their long-lived parts.
  Future<void> close() async {
    await _current?.close();
    _current = null;
  }

  void _registerSecrets(SettingsSnapshot settings) =>
      settings.allSecretValues.forEach(config.redactor.addSecret);

  void _log(String line) => config.onLog?.call(config.redactor.redact(line));

  _ConversionScope? _attached() {
    final _ConversionScope? scope = _current;
    return scope == null || scope.owner.isClosed ? null : scope;
  }

  SourceOutcome<TachiRuntime> _tachiRuntime() {
    final _ConversionScope? scope = _attached();
    if (scope == null) return _notAttached<TachiRuntime>('Tachi');
    final TachiRuntime? existing = scope.tachiRuntime;
    if (existing != null) return SourceSuccess<TachiRuntime>(existing);
    final SourceOutcome<TachiRuntime> opened = _openTachi(scope);
    scope.tachiRuntime = opened.valueOrNull;
    return opened;
  }

  Future<SourceOutcome<WorkerSupervisor>> _paperbackWorker(
    ConversionOwner? owner,
  ) async {
    final _ConversionScope? scope = _attached();
    if (scope == null) return _notAttached<WorkerSupervisor>('Paperback');
    final PaperbackWorkerPlan plan = paperbackPlan;
    final ConversionRuntimeScope
    workers = scope.paperback ??= ConversionRuntimeScope(
      workers: const <WorkerKind, WorkerSpec>{
        WorkerKind.paperback: inAppPaperbackWorkerSpec,
      },
      limits: AdoptWorkerLimits(
        handshakeDeadline: plan.handshakeDeadline,
        maxConcurrentPackages: 1,
        cancelGrace: plan.cancelGrace,
        interactionTimeout: config.interactionTimeout,
        shutdownGrace: plan.cancelGrace,
      ),
      launcher: isolatePaperbackLauncher(
        PaperbackIsolateWorkerConfig(
          limits: plan.sizing.limits,
          deadlineHeadroom: plan.deadlineHeadroom,
          clientFactory: config.paperbackSiteClient,
          browserEnabled: browserPort != null,
        ),
      ),
      browserPort: browserPort,
      resolveBrowserSource: (WorkerKind kind, String? packageId, String id) =>
          _hostedIdentity(scope.paperback, kind, 'paperback', packageId, id),
      onLog: _log,
      redactor: config.redactor,
      gate: workerGate,
    );
    return workers.worker(WorkerKind.paperback);
  }

  /// The identity of [sourceId] in a package the scope's worker hosts now.
  static SourceIdentity? _hostedIdentity(
    ConversionRuntimeScope? scope,
    WorkerKind kind,
    String ecosystem,
    String? packageId,
    String sourceId,
  ) {
    if (scope == null || packageId == null) return null;
    final ArtifactBinding? artifact = scope.supervisors[kind]?.artifactOf(
      packageId,
    );
    if (artifact == null) return null;
    return SourceIdentity(
      ecosystem: ecosystem,
      packageId: packageId,
      sourceId: sourceId,
      artifact: artifact,
    );
  }

  static SourceFailed<T> _notAttached<T>(String runtime) => SourceFailed<T>(
    RuntimeUnavailableFailure(
      'No conversion owns the $runtime runtime (attach it before loading)',
    ),
  );
}

/// The scopes one conversion created, closed with its owner.
final class _ConversionScope {
  _ConversionScope(this.owner);

  final ConversionOwner owner;
  ConversionRuntimeScope? paperback;
  TachiRuntime? tachiRuntime;

  /// Closes the platform's Tachi worker scope.
  Future<void> Function()? closeTachi;
  Future<void>? _closing;

  Future<void> close() => _closing ??= () async {
    await paperback?.close();
    await closeTachi?.call();
  }();
}

final class _TachiLoaderRuntime implements TachiLoaderRuntime {
  _TachiLoaderRuntime(this._runtimes);

  final LocalSourceRuntimes _runtimes;

  @override
  TachiFetch get fetch => _runtimes.config.tachiFetch;

  @override
  TachiArtifactPolicy get policy => _runtimes.config.tachiPolicy;

  @override
  SourceOutcome<TachiRuntime> runtime() => _runtimes._tachiRuntime();
}

/// The app's [conversionServiceProvider] over a platform's local runtimes
/// and the app's remembered repository trust in [trustStore].
Override localConversionServiceOverride(
  LocalSourceRuntimes runtimes, {
  TrustStore? trustStore,
}) => conversionServiceProvider.overrideWithValue(
  runtimes.service(trustStore: trustStore),
);

/// The app's [conversionServiceProvider] on iOS.
Override iosConversionServiceOverride(
  IosSourceRuntimes runtimes, {
  TrustStore? trustStore,
}) => localConversionServiceOverride(runtimes, trustStore: trustStore);

/// The app's [conversionServiceProvider] on Android.
Override androidConversionServiceOverride(
  AndroidSourceRuntimes runtimes, {
  TrustStore? trustStore,
}) => localConversionServiceOverride(runtimes, trustStore: trustStore);
