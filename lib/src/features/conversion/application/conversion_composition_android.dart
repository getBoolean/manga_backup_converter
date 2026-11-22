// Android branch of the composition root (U14).
//
// - Aidoku (U13): the desktop `AidokuSourceProvider` behind
//   `AndroidAidokuBackend` (wasm3 and the Rust scraper must load in the app
//   process before Aidoku is offered).
// - Paperback (U12): the unchanged worker in a Dart isolate
//   (`isolatePaperbackLauncher`) on the vendored QuickJS-ng, with limits from
//   the KTD25 sizing rule measured on this device. `executeInWebView` and the
//   0.8 Cloudflare bypass run on the app-process `AndroidWebViewBrowserPort`.
// - Tachi (U11): the shared worker in the private `:source_runtime` service
//   process (`AndroidTachiBackend`), one worker per conversion, reached
//   through the common `TachiRuntime` with APK artifacts only (KTD17). Its
//   WebViews are real ones inside the service, not the browser port.
//
// Backgrounding (KTD18): one app-lifecycle signal, `AndroidAppForeground`
// (the Activity tracker the browser port's host already used), feeds the
// shared `BackgroundGate` first and the browser port second. The gate sits in
// front of Aidoku (provider decorator) and both workers (supervisor hook):
// while backgrounded new calls fail `cancelled: app-backgrounded`, searches
// and details in flight answer the same at once with late replies dropped,
// and in the foreground work resumes on the same sessions. A conversion
// whose calls failed this way publishes nothing partial unless the user
// accepts the partial result. Activity recreation and process death are
// left to the journal: a destroyed `MainActivity` ends the job with its
// engine, and the next launch resumes from the journal (no cached engine,
// no foreground service).
//
// The app is interactive, so a production configuration lets Cloudflare
// challenges open the service's challenge Activity (`--interactive-challenges`)
// and the browser port show interactions; unattended runs turn both off.

part of 'conversion_composition.dart';

/// What the Android runtimes run with.
final class AndroidConversionConfig extends LocalRuntimeConfig {
  AndroidConversionConfig({
    required super.storageRoot,
    required super.interactionTimeout,
    required this.interactive,
    super.client,
    super.aidokuSiteClient,
    super.paperbackSiteClient,
    super.tachiFetch,
    super.tachiPolicy = const TachiArtifactPolicy(all: TachiArtifactKind.apk),
    this.tachiWorkerArguments = const <String>[],
    this.tachiHandshakeDeadline = androidTachiHandshakeDeadline,
    AndroidBrowserConfig? browser,
    super.paperbackPlan,
    super.onLog,
    super.redactor,
  }) : browser =
           browser ??
           AndroidBrowserConfig(allowInteraction: interactive, onLog: onLog);

  /// Whether a person can answer challenges: Cloudflare challenges open in
  /// the service's challenge Activity for at most [interactionTimeout], and
  /// the browser port may show its interaction Activity. `false` for
  /// unattended runs, where both answer interaction-required.
  final bool interactive;

  /// Test only: extra worker arguments, such as `--replay NAME`,
  /// `--offline-browser` or `--limit NAME=VALUE`. Release builds refuse the
  /// debug-only ones, so production passes none.
  final List<String> tachiWorkerArguments;

  /// Bound on the Tachi worker handshake (KTD25: the one limit the worker
  /// cannot report).
  final Duration tachiHandshakeDeadline;

  /// The app-process browser port's configuration.
  final AndroidBrowserConfig browser;

  /// The Tachi worker's arguments: [tachiWorkerArguments], plus the
  /// interactive challenge bound when [interactive].
  List<String> get tachiArguments => <String>[
    ...tachiWorkerArguments,
    if (interactive) ...<String>[
      '--interactive-challenges',
      '${interactionTimeout.inMilliseconds}',
    ],
  ];
}

/// The device's local source runtimes on Android, created once per app
/// process ([start]). The Aidoku backend and the browser port live as long
/// as this object; the `:source_runtime` service runs only while a
/// conversion's Tachi worker is open.
final class AndroidSourceRuntimes extends LocalSourceRuntimes {
  AndroidSourceRuntimes._({
    required AndroidConversionConfig super.config,
    required SourceOutcome<AndroidAidokuBackend> aidoku,
    required this._paperback,
    required SourceOutcome<AndroidWebViewBrowserPort> browser,
    required super.paperbackPlan,
    required this.appForeground,
    required BackgroundGate gate,
  }) : _aidoku = aidoku,
       _port = browser.valueOrNull,
       tachi = AndroidTachiBackend(
         arguments: config.tachiArguments,
         handshakeDeadline: config.tachiHandshakeDeadline,
       ),
       super._(
         workerGate: gate,
         aidoku: switch (aidoku) {
           SourceSuccess<AndroidAidokuBackend>(
             :final AndroidAidokuBackend value,
           ) =>
             SourceSuccess<SourceProvider>(gate.provider(value.provider)),
           SourceFailed<AndroidAidokuBackend>(:final SourceFailure failure) =>
             SourceFailed<SourceProvider>(failure),
         },
         browserPort: browser.valueOrNull,
         browserUnavailable: browser.failureOrNull,
       );

  /// Starts the long-lived parts: Aidoku and Paperback admission (their
  /// native libraries load in this process) and the browser port. Nothing
  /// else starts: no service binding, no worker, no isolate. A runtime that
  /// cannot start is reported by its registry probe as a typed failure; a
  /// browser port that cannot start leaves Paperback running without
  /// `executeInWebView` ([browserUnavailable] says why).
  static Future<SourceOutcome<AndroidSourceRuntimes>> start(
    AndroidConversionConfig config,
  ) async {
    if (!Platform.isAndroid) {
      return const SourceFailed<AndroidSourceRuntimes>(
        RuntimeUnavailableFailure(
          'The Android source runtimes run on Android only',
        ),
      );
    }
    final SourceOutcome<AndroidAidokuBackend> aidoku =
        AndroidAidokuBackend.register(
          AidokuSourceProvider(httpClient: config.aidokuSiteClient),
        );
    final SourceFailure? paperback =
        AndroidPaperbackBackend.checkNativeLibrary();
    // The one lifecycle signal: the gate hears it before the port does.
    final gate = BackgroundGate();
    final SourceOutcome<AndroidAppForeground> started =
        AndroidAppForeground.start();
    final AndroidAppForeground? foreground = started.valueOrNull;
    if (foreground == null) {
      config.onLog?.call(
        config.redactor.redact(
          '[lifecycle] unavailable: ${started.failureOrNull!.message}',
        ),
      );
    } else {
      foreground.addListener(gate.setBackgrounded);
      gate.setBackgrounded(foreground.isBackgrounded);
    }
    final SourceOutcome<AndroidWebViewBrowserPort> browser =
        await AndroidWebViewBrowserPort.start(
          config: config.browser,
          foreground: foreground,
        );
    if (browser case SourceFailed<AndroidWebViewBrowserPort>(
      :final SourceFailure failure,
    )) {
      config.onLog?.call(
        config.redactor.redact('[browser] unavailable: ${failure.message}'),
      );
    }
    final PaperbackWorkerPlan plan =
        config.paperbackPlan ?? await planPaperbackIsolateWorker();
    config.onLog?.call('[paperback] sizing ${plan.sizing.toJson()}');
    return SourceSuccess<AndroidSourceRuntimes>(
      AndroidSourceRuntimes._(
        config: config,
        aidoku: aidoku,
        paperback: paperback,
        browser: browser,
        paperbackPlan: plan,
        appForeground: foreground,
        gate: gate,
      ),
    );
  }

  final SourceOutcome<AndroidAidokuBackend> _aidoku;
  final SourceFailure? _paperback;
  final AndroidWebViewBrowserPort? _port;

  /// The Tachi backend: the `:source_runtime` service worker's launcher.
  final AndroidTachiBackend tachi;

  /// The app's lifecycle signal, or `null` when its monitor did not start
  /// (then nothing is gated and the port follows its own host).
  final AndroidAppForeground? appForeground;

  /// The background gate in front of Aidoku, Paperback and Tachi.
  BackgroundGate get backgroundGate => workerGate!;

  /// Whether source work is gated as backgrounded.
  bool get isBackgrounded => backgroundGate.isBackgrounded;

  /// The app-process WebView port, or `null` when it could not start.
  @override
  AndroidWebViewBrowserPort? get browserPort => _port;

  /// The Aidoku backend, once registered.
  AndroidAidokuBackend? get aidoku => _aidoku.valueOrNull;

  /// The current conversion's Tachi worker scope, once a Tachi package
  /// loaded.
  ConversionRuntimeScope? get tachiScope => _tachiScope;
  ConversionRuntimeScope? _tachiScope;

  @override
  SourceFailure? _paperbackProbe() => _paperback;

  @override
  SourceFailure? _tachiProbe() => null;

  @override
  SourceOutcome<TachiRuntime> _openTachi(_ConversionScope scope) {
    final ConversionRuntimeScope workers = tachi.scope(
      onLog: _log,
      redactor: config.redactor,
      gate: workerGate,
    );
    _tachiScope = workers;
    scope.closeTachi = () async {
      if (identical(_tachiScope, workers)) _tachiScope = null;
      await workers.close();
    };
    return SourceSuccess<TachiRuntime>(
      TachiRuntime(
        worker: () => workers.worker(WorkerKind.jvm),
        store: TachiArtifactStore(
          cache: ArtifactCache(
            Directory('${config.storageRoot.path}/tachi_artifacts'),
          ),
          fetch: config.tachiFetch,
        ),
        catalog: TachiCatalog(config.tachiFetch),
        policy: config.tachiPolicy,
      ),
    );
  }

  /// Closes the current conversion's scopes (ending the service worker)
  /// and the browser port.
  @override
  Future<void> close() async {
    await super.close();
    await _port?.dispose();
    appForeground?.dispose();
  }
}
