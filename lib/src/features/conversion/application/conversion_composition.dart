// The app's composition root for source runtimes (KTD14, KTD15).
//
// iOS branch (U15): the three local runtimes run inside the app process.
// - Aidoku (U18): the desktop `AidokuSourceProvider` behind
//   `IosAidokuBackend` (bundled wasm3/SwiftSoup admission, background gate).
// - Paperback (U10): the unchanged worker in a Dart isolate
//   (`isolatePaperbackLauncher`) with limits from the KTD25 sizing rule,
//   measured on this device.
// - Tachi (U9): the shared worker inside the process-lifetime embedded JVM
//   (`IosJvmRuntime`, `IosTachiBackend`), reached through the common
//   `TachiRuntime`.
// Both workers share one WKWebView `BrowserPort`, each through its own
// reverse bridge.
//
// Everything source-related is the user's: no repository, extension or
// settings default exists here. The app passes the repositories in each
// `ConversionRequest`, the extension picks through its `SelectionPort`, and
// the settings through `ConversionService.convert(settingsFor:)`.
//
// The Android branch arrives with U14.

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
import 'package:source_runtime_ios/source_runtime_ios.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';

/// The worker spec of the in-app Paperback isolate (no executable runs).
const WorkerSpec iosPaperbackWorkerSpec = WorkerSpec(
  label: 'paperback',
  executable: 'in-app-isolate',
);

/// Tachi limits on iOS. There is no iOS sizing rule until the KTD25
/// benchmark runs on physical iPhones, so every value is the app's explicit
/// choice; none is invented here.
final class IosTachiLimits {
  const IosTachiLimits({
    required this.supervisor,
    required this.nativeDeadline,
  });

  /// Supervisor limits; [SupervisorLimits.operationDeadline] is the Dart
  /// backstop and must exceed [nativeDeadline].
  final SupervisorLimits supervisor;

  /// The native per-operation deadline (the JVM watchdog, KTD12).
  final Duration nativeDeadline;
}

/// What the iOS runtimes run with. Production passes live clients; the
/// integration harness passes replaying ones, so no test reaches a server.
final class IosConversionConfig {
  IosConversionConfig({
    required this.storageRoot,
    required this.tachiLimits,
    required this.interactionTimeout,
    http.Client? client,
    this.aidokuSiteClient,
    this.paperbackSiteClient = _liveClient,
    TachiFetch? tachiFetch,
    this.tachiPolicy = const TachiArtifactPolicy(),
    this.tachiReplay = const <String>[],
    this.tachiReplayHang = const <String>[],
    this.browser = const WKWebViewBrowserConfig(),
    this.paperbackPlan,
    this.onLog,
    Redactor? redactor,
  }) : client = client ?? http.Client(),
       redactor = redactor ?? Redactor() {
    this.tachiFetch = tachiFetch ?? _httpFetch(this.client);
  }

  /// App-private directory for artifact caches and worker state.
  final Directory storageRoot;
  final IosTachiLimits tachiLimits;

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

  /// Test only: capture directories the in-VM worker replays (fail-closed),
  /// and hosts whose replayed requests never answer.
  final List<String> tachiReplay;
  final List<String> tachiReplayHang;

  final WKWebViewBrowserConfig browser;

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

/// The device's local source runtimes on iOS, created once per app process
/// ([start]) and shared by every conversion. Per-conversion scopes (the
/// Paperback worker isolate, the Tachi worker generation, their browser
/// bridges) are created on first use and closed by the conversion's owner
/// ([attach]); the embedded JVM, the Aidoku backend and the browser port
/// live as long as this object.
final class IosSourceRuntimes {
  IosSourceRuntimes._({
    required this.config,
    required this._aidoku,
    required this._jvm,
    required this.browserPort,
    required this.paperbackPlan,
  });

  /// Starts the long-lived parts. A runtime that cannot start is reported
  /// by its registry probe as a typed failure; the others stay usable.
  static Future<SourceOutcome<IosSourceRuntimes>> start(
    IosConversionConfig config,
  ) async {
    if (!Platform.isIOS) {
      return const SourceFailed<IosSourceRuntimes>(
        RuntimeUnavailableFailure('The iOS source runtimes run on iOS only'),
      );
    }
    final SourceOutcome<IosAidokuBackend> aidoku = IosAidokuBackend.register(
      AidokuSourceProvider(httpClient: config.aidokuSiteClient),
    );
    final WKWebViewBrowserPort? port =
        WKWebViewBrowserPort.unavailableReason == null
        ? WKWebViewBrowserPort(config: config.browser)
        : null;
    final PaperbackWorkerPlan plan =
        config.paperbackPlan ?? await planPaperbackIsolateWorker();
    config.onLog?.call('[paperback] sizing ${plan.sizing.toJson()}');
    return SourceSuccess<IosSourceRuntimes>(
      IosSourceRuntimes._(
        config: config,
        aidoku: aidoku,
        jvm: await _startJvm(config),
        browserPort: port,
        paperbackPlan: plan,
      ),
    );
  }

  static Future<SourceOutcome<IosJvmRuntime>> _startJvm(
    IosConversionConfig config,
  ) async {
    try {
      final bundle = BundledRuntime.prepare();
      final temp = Directory(
        '${config.storageRoot.path}/jvm-tmp',
      )..createSync(recursive: true);
      return SourceSuccess<IosJvmRuntime>(
        await IosJvmRuntime.start(
          javaHome: bundle.javaHome,
          options: bundle.productionOptions(tempDirectory: temp.path),
        ),
      );
    } on Object catch (e) {
      return SourceFailed<IosJvmRuntime>(
        RuntimeUnavailableFailure(
          config.redactor.redact('The embedded JVM did not start: $e'),
        ),
      );
    }
  }

  final IosConversionConfig config;
  final SourceOutcome<IosAidokuBackend> _aidoku;
  final SourceOutcome<IosJvmRuntime> _jvm;

  /// The shared WKWebView port, or `null` off the platform thread.
  final WKWebViewBrowserPort? browserPort;
  final PaperbackWorkerPlan paperbackPlan;

  _ConversionScope? _current;

  /// The Aidoku backend, once registered.
  IosAidokuBackend? get aidoku => _aidoku.valueOrNull;

  /// The embedded JVM, once started.
  IosJvmRuntime? get jvm => _jvm.valueOrNull;

  /// The current conversion's Tachi backend, once a Tachi package loaded.
  IosTachiBackend? get tachiBackend => _current?.tachi;

  /// The current conversion's Paperback worker scope, once started.
  ConversionRuntimeScope? get paperbackScope => _current?.paperback;

  /// The runtime registry for [ConversionService]: one entry per ecosystem,
  /// each probed without starting anything.
  late final RuntimeRegistry registry = RuntimeRegistry(<DestinationRuntime>[
    DestinationRuntime(
      ecosystem: IosAidokuBackend.ecosystem,
      serves: (BackupFormat f) => f is Aidoku,
      probe: () => _aidoku.failureOrNull,
      createLoader: (RuntimeContext context) => AidokuPluginLoader(
        providerFactory: () => _aidoku.valueOrNull!.provider,
        client: config.client,
        onSettings: _registerSecrets,
        settingsFor: context.settingsFor,
      ),
    ),
    DestinationRuntime(
      ecosystem: 'paperback',
      serves: (BackupFormat f) => f is Paperback,
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
      probe: () => _jvm.failureOrNull,
      createLoader: (RuntimeContext context) => TachiPluginLoader(
        runtime: _IosTachiLoaderRuntime(this),
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

  /// App backgrounding (KTD12): pending Aidoku calls and browser operations
  /// end as cancelled, new ones are refused, late results are discarded;
  /// everything is usable again in the foreground.
  void setBackgrounded(bool backgrounded) {
    _aidoku.valueOrNull?.setBackgrounded(backgrounded);
    browserPort?.setBackgrounded(backgrounded);
  }

  /// Follows the app lifecycle with [setBackgrounded].
  void bindToAppLifecycle() {
    _aidoku.valueOrNull?.bindToAppLifecycle();
    browserPort?.bindToAppLifecycle();
  }

  /// Closes the current conversion's scopes and the browser port. The JVM
  /// is never destroyed (KTD11).
  Future<void> close() async {
    await _current?.close();
    _current = null;
    _aidoku.valueOrNull?.dispose();
    await browserPort?.dispose();
  }

  void _registerSecrets(SettingsSnapshot settings) =>
      settings.secrets.values.forEach(config.redactor.addSecret);

  void _log(String line) => config.onLog?.call(config.redactor.redact(line));

  _ConversionScope? _attached() {
    final _ConversionScope? scope = _current;
    return scope == null || scope.owner.isClosed ? null : scope;
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
        WorkerKind.paperback: iosPaperbackWorkerSpec,
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
    );
    return workers.worker(WorkerKind.paperback);
  }

  SourceOutcome<TachiRuntime> _tachiRuntime() {
    final _ConversionScope? scope = _attached();
    if (scope == null) return _notAttached<TachiRuntime>('Tachi');
    final TachiRuntime? existing = scope.tachiRuntime;
    if (existing != null) return SourceSuccess<TachiRuntime>(existing);
    final IosJvmRuntime? vm = _jvm.valueOrNull;
    if (vm == null) return SourceFailed<TachiRuntime>(_jvm.failureOrNull!);
    final cache = ArtifactCache(
      Directory('${config.storageRoot.path}/tachi_artifacts'),
    );
    final IosTachiBackend backend = scope.tachi = IosTachiBackend(
      runtime: vm,
      config: IosTachiConfig(
        limits: config.tachiLimits.supervisor,
        nativeDeadline: config.tachiLimits.nativeDeadline,
        stateRoot: Directory('${config.storageRoot.path}/tachi_state')
          ..createSync(recursive: true),
        cache: cache,
        replay: config.tachiReplay,
        replayHang: config.tachiReplayHang,
        browser: browserPort != null,
      ),
      browserPort: browserPort,
      onLog: _log,
    );
    final runtime = TachiRuntime(
      worker: backend.worker,
      store: TachiArtifactStore(cache: cache, fetch: config.tachiFetch),
      catalog: TachiCatalog(config.tachiFetch),
      policy: config.tachiPolicy,
      hostCompatibility: iosTachiHostCompatibility,
    );
    scope.tachiRuntime = runtime;
    return SourceSuccess<TachiRuntime>(runtime);
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
  IosTachiBackend? tachi;
  TachiRuntime? tachiRuntime;
  Future<void>? _closing;

  Future<void> close() => _closing ??= () async {
    await paperback?.close();
    await tachi?.close();
  }();
}

final class _IosTachiLoaderRuntime implements TachiLoaderRuntime {
  _IosTachiLoaderRuntime(this._runtimes);

  final IosSourceRuntimes _runtimes;

  @override
  TachiFetch get fetch => _runtimes.config.tachiFetch;

  @override
  TachiArtifactPolicy get policy => _runtimes.config.tachiPolicy;

  @override
  SourceOutcome<TachiRuntime> runtime() => _runtimes._tachiRuntime();
}

/// The app's [conversionServiceProvider] on iOS: the local runtimes in
/// [runtimes] and the app's remembered repository trust in [trustStore].
Override iosConversionServiceOverride(
  IosSourceRuntimes runtimes, {
  TrustStore? trustStore,
}) => conversionServiceProvider.overrideWithValue(
  runtimes.service(trustStore: trustStore),
);
