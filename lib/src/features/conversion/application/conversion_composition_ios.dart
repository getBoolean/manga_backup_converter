// iOS branch of the composition root (U15).
//
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

part of 'conversion_composition.dart';

/// The worker spec of the in-app Paperback isolate on iOS.
const WorkerSpec iosPaperbackWorkerSpec = inAppPaperbackWorkerSpec;

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

/// What the iOS runtimes run with.
final class IosConversionConfig extends LocalRuntimeConfig {
  IosConversionConfig({
    required super.storageRoot,
    required this.tachiLimits,
    required super.interactionTimeout,
    super.client,
    super.aidokuSiteClient,
    super.paperbackSiteClient,
    super.tachiFetch,
    super.tachiPolicy,
    this.tachiReplay = const <String>[],
    this.tachiReplayHang = const <String>[],
    this.browser = const WKWebViewBrowserConfig(),
    super.paperbackPlan,
    super.onLog,
    super.redactor,
  });

  final IosTachiLimits tachiLimits;

  /// Test only: capture directories the in-VM worker replays (fail-closed),
  /// and hosts whose replayed requests never answer.
  final List<String> tachiReplay;
  final List<String> tachiReplayHang;

  final WKWebViewBrowserConfig browser;
}

/// The device's local source runtimes on iOS, created once per app process
/// ([start]). The embedded JVM, the Aidoku backend and the browser port live
/// as long as this object.
final class IosSourceRuntimes extends LocalSourceRuntimes {
  IosSourceRuntimes._({
    required IosConversionConfig super.config,
    required SourceOutcome<IosAidokuBackend> aidoku,
    required this._jvm,
    required WKWebViewBrowserPort? browserPort,
    required super.paperbackPlan,
  }) : _aidoku = aidoku,
       _port = browserPort,
       super._(aidoku: _providerOf(aidoku), browserPort: browserPort);

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
      final temp = Directory('${config.storageRoot.path}/jvm-tmp')
        ..createSync(recursive: true);
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

  static SourceOutcome<SourceProvider> _providerOf(
    SourceOutcome<IosAidokuBackend> aidoku,
  ) => switch (aidoku) {
    SourceSuccess<IosAidokuBackend>(:final IosAidokuBackend value) =>
      SourceSuccess<SourceProvider>(value.provider),
    SourceFailed<IosAidokuBackend>(:final SourceFailure failure) =>
      SourceFailed<SourceProvider>(failure),
  };

  final SourceOutcome<IosAidokuBackend> _aidoku;
  final SourceOutcome<IosJvmRuntime> _jvm;
  final WKWebViewBrowserPort? _port;

  IosConversionConfig get _config => config as IosConversionConfig;

  /// The shared WKWebView port, or `null` off the platform thread.
  @override
  WKWebViewBrowserPort? get browserPort => _port;

  /// The Aidoku backend, once registered.
  IosAidokuBackend? get aidoku => _aidoku.valueOrNull;

  /// The embedded JVM, once started.
  IosJvmRuntime? get jvm => _jvm.valueOrNull;

  /// The current conversion's Tachi backend, once a Tachi package loaded.
  IosTachiBackend? get tachiBackend => _tachiBackend;
  IosTachiBackend? _tachiBackend;

  @override
  SourceFailure? _tachiProbe() => _jvm.failureOrNull;

  @override
  SourceOutcome<TachiRuntime> _openTachi(_ConversionScope scope) =>
      switch (_jvm) {
        SourceFailed<IosJvmRuntime>(:final SourceFailure failure) =>
          SourceFailed<TachiRuntime>(failure),
        SourceSuccess<IosJvmRuntime>(:final IosJvmRuntime value) =>
          _openTachiIn(value, scope),
      };

  SourceOutcome<TachiRuntime> _openTachiIn(
    IosJvmRuntime vm,
    _ConversionScope scope,
  ) {
    final cache = ArtifactCache(
      Directory('${config.storageRoot.path}/tachi_artifacts'),
    );
    final backend = IosTachiBackend(
      runtime: vm,
      config: IosTachiConfig(
        limits: _config.tachiLimits.supervisor,
        nativeDeadline: _config.tachiLimits.nativeDeadline,
        stateRoot: Directory('${config.storageRoot.path}/tachi_state')
          ..createSync(recursive: true),
        cache: cache,
        replay: _config.tachiReplay,
        replayHang: _config.tachiReplayHang,
        browser: _port != null,
      ),
      browserPort: _port,
      onLog: _log,
    );
    _tachiBackend = backend;
    scope.closeTachi = () async {
      if (identical(_tachiBackend, backend)) _tachiBackend = null;
      await backend.close();
    };
    return SourceSuccess<TachiRuntime>(
      TachiRuntime.cached(
        worker: backend.worker,
        cache: cache,
        fetch: config.tachiFetch,
        policy: config.tachiPolicy,
        hostCompatibility: iosTachiHostCompatibility,
      ),
    );
  }

  /// App backgrounding (KTD12): pending Aidoku calls and browser operations
  /// end as cancelled, new ones are refused, late results are discarded;
  /// everything is usable again in the foreground.
  void setBackgrounded(bool backgrounded) {
    _aidoku.valueOrNull?.setBackgrounded(backgrounded);
    _port?.setBackgrounded(backgrounded);
  }

  /// Follows the app lifecycle with [setBackgrounded].
  void bindToAppLifecycle() {
    _aidoku.valueOrNull?.bindToAppLifecycle();
    _port?.bindToAppLifecycle();
  }

  /// Closes the current conversion's scopes and the browser port. The JVM
  /// is never destroyed (KTD11).
  @override
  Future<void> close() async {
    await super.close();
    _aidoku.valueOrNull?.dispose();
    await _port?.dispose();
  }
}
