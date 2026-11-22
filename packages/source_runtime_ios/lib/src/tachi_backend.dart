import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:source_runtime_ios/src/in_vm_worker.dart';
import 'package:source_runtime_ios/src/ios_jvm_runtime.dart';

/// [SourceIdentity.ecosystem] of Tachi sources (same value as the desktop
/// provider, so references are portable).
const String iosTachiEcosystem = 'tachi';

/// Host compatibility of artifacts prepared by the iOS worker. Part of their
/// cache identity together with the worker-reported converter version, which
/// carries the rewrite pass version (KTD5, KTD11): an iOS-prepared JAR is never
/// mistaken for a desktop one and the reverse.
const String iosTachiHostCompatibility = 'tachi-host.1+ios';

/// Cache profile of unprepared artifacts admitted on the device.
const ArtifactProfile iosTachiDownloadProfile = ArtifactProfile(
  producer: 'tachi-download',
  converterVersion: '1',
  hostCompatibility: 'unprepared',
);

/// How the iOS Tachi backend runs (U9).
///
/// Every limit is explicit: there is no iOS sizing rule until the KTD25
/// benchmark runs on physical iPhones, and nothing here is a default.
@immutable
final class IosTachiConfig {
  const IosTachiConfig({
    required this.limits,
    required this.nativeDeadline,
    required this.stateRoot,
    required this.cache,
    this.replay = const <String>[],
    this.replayHang = const <String>[],
    this.browser = true,
    this.browserReplacementTimeout,
  });

  /// Supervisor limits. [SupervisorLimits.operationDeadline] is the Dart-side
  /// backstop and must exceed [nativeDeadline].
  final SupervisorLimits limits;

  /// Native per-operation deadline armed in the dispatcher's watchdog. It
  /// stops rewritten code at its next back-edge and ends host waits without
  /// any Dart involvement (KTD12 "iOS deadlines").
  final Duration nativeDeadline;

  /// Parent of each worker generation's package state directory.
  final Directory stateRoot;

  /// Content-addressed cache for unprepared and prepared artifacts (KTD5).
  final ArtifactCache cache;

  /// Capture directories for fail-closed replay (tests); empty for live use.
  final List<String> replay;

  /// Replay only: hosts whose requests never get an answer (deadline tests).
  final List<String> replayHang;

  /// Whether the worker may use the browser port.
  final bool browser;

  /// Replace-tier hold timeout for the browser bridge (see
  /// [BrowserReverseBridge.replacementTimeout]).
  final Duration? browserReplacementTimeout;
}

/// An artifact verified, converted (APK) and rewritten by the in-VM worker
/// (`artifact.prepare`), re-hashed and admitted to the cache. The only
/// artifact [IosTachiBackend.openPackage] accepts.
final class IosTachiPreparedArtifact implements VerifiedArtifact {
  IosTachiPreparedArtifact._({required this.packageId, required this.lease, required this.input});

  final String packageId;

  /// The prepared JAR the worker loads (re-verified by digest on every load).
  final ArtifactLease lease;

  /// Binding of the verified input (the repository JAR or APK).
  final ArtifactBinding input;

  @override
  ArtifactBinding get binding => lease.binding;

  @override
  Future<Uint8List> readVerified() => lease.readVerified();
}

/// Local Tachi execution on iOS (U9; KTD11, KTD12, KTD23).
///
/// One embedded VM serves the app for its lifetime ([IosJvmRuntime]). Inside
/// it the shared Tachi worker, the desktop worker's own classes, speaks the
/// source worker protocol over a native channel ([InVmWorkerProcess]), so
/// this backend reuses [WorkerSupervisor], [WorkerSourceSession] and
/// [BrowserReverseBridge] unchanged: per-package serialisation, generation
/// fencing, durable references, settings revisions and the browser reverse
/// requests behave as on desktop.
///
/// What differs is enforcement. Every operation runs under a native deadline
/// (the watchdog marks the thread for the rewritten back-edge polls and ends
/// its host waits), and a supervisor restart closes the channel and fires the
/// generation's deadlines instead of killing a process. Closing a session,
/// a package or this backend never destroys the VM.
///
/// The composition root may also hand [worker] to the common Tachi provider
/// (`TachiRuntime` in `tachi_plugin_loader`) for catalog discovery and package
/// sharing; this class implements the [SourceProvider] contract directly so
/// the plugin does not depend on that loader (KTD16).
final class IosTachiBackend implements SourceProvider {
  /// Starts nothing yet: the worker starts on first use.
  factory IosTachiBackend({
    required IosJvmRuntime runtime,
    required IosTachiConfig config,
    BrowserPort? browserPort,
    void Function(String line)? onLog,
  }) {
    if (config.nativeDeadline >= config.limits.operationDeadline) {
      throw ArgumentError('nativeDeadline must be shorter than limits.operationDeadline (the Dart backstop)');
    }
    late final IosTachiBackend backend;
    var generation = 0;
    final scope = ConversionRuntimeScope(
      workers: const <WorkerKind, WorkerSpec>{
        WorkerKind.jvm: WorkerSpec(label: 'jvm-ios', executable: 'in-vm:mangabackup.tachi.ios.IosWorkerHost'),
      },
      limits: config.limits,
      launcher: inVmWorkerLauncher(runtime, () => backend._options(++generation)),
      browserPort: browserPort,
      resolveBrowserSource: (WorkerKind kind, String? packageId, String sourceId) =>
          backend._resolveBrowserSource(packageId, sourceId),
      browserReplacementTimeout: config.browserReplacementTimeout,
      onLog: onLog,
    );
    return backend = IosTachiBackend._(runtime, config, scope);
  }

  IosTachiBackend._(this.runtime, this.config, this._scope);

  final IosJvmRuntime runtime;
  final IosTachiConfig config;
  final ConversionRuntimeScope _scope;
  final Map<String, SourceIdentity> _identities = <String, SourceIdentity>{};
  final Map<String, _IosPackage> _packages = <String, _IosPackage>{};

  @override
  String get ecosystem => iosTachiEcosystem;

  /// The started worker supervisor (a `TachiWorkerAccess` for the common
  /// Tachi provider).
  Future<SourceOutcome<WorkerSupervisor>> worker() => _scope.worker(WorkerKind.jvm);

  /// The identity a browser reverse request from [packageId]'s source
  /// [sourceId] is scoped to: the session this backend opened, or, for a
  /// package the common `TachiRuntime` opened over [worker] (the app's
  /// composition), one built from the artifact the current worker generation
  /// hosts. A package that is not hosted resolves to nothing, so the bridge
  /// refuses the request.
  SourceIdentity? _resolveBrowserSource(String? packageId, String sourceId) {
    final SourceIdentity? opened = _identities['$packageId\u0000$sourceId'];
    if (opened != null || packageId == null) return opened;
    final ArtifactBinding? artifact = supervisor?.artifactOf(packageId);
    if (artifact == null) return null;
    return SourceIdentity(ecosystem: iosTachiEcosystem, packageId: packageId, sourceId: sourceId, artifact: artifact);
  }

  /// The supervisor, once started.
  WorkerSupervisor? get supervisor => _scope.supervisors[WorkerKind.jvm];

  /// The browser bridge, when a browser port was given and the worker started.
  BrowserReverseBridge? get browserBridge => _scope.bridges[WorkerKind.jvm];

  String _options(int generation) {
    final state = '${config.stateRoot.path}/gen-$generation-${DateTime.now().microsecondsSinceEpoch}';
    final SupervisorLimits l = config.limits;
    return <String>[
      'stateDir=$state',
      'nativeDeadlineMs=${config.nativeDeadline.inMilliseconds}',
      'browser=${config.browser}',
      // The worker reports the limits the supervisor enforces (KTD25); they
      // are explicit overrides, not a sizing rule.
      'limit.poolSize=${l.maxConcurrentPackages}',
      'limit.operationDeadlineMs=${l.operationDeadline.inMilliseconds}',
      'limit.cancelGraceMs=${l.cancelGrace.inMilliseconds}',
      'limit.interactionTimeoutMs=${l.interactionTimeout.inMilliseconds}',
      'limit.shutdownGraceMs=${l.shutdownGrace.inMilliseconds}',
      for (final String r in config.replay) 'replay=$r',
      for (final String h in config.replayHang) 'replayHang=$h',
    ].join('\n');
  }

  /// Admits downloaded [bytes] (a repository JAR or an APK) and prepares them
  /// in the VM: signature verification against [trust] (every JAR entry signed
  /// by the one trusted signer; APKs with pinned apksig), dex2jar for APKs,
  /// then the back-edge rewrite pass on both paths. The output is re-hashed
  /// and cached by its KTD5 identity, including the rewrite version.
  Future<SourceOutcome<IosTachiPreparedArtifact>> prepare({
    required String packageId,
    required Uint8List bytes,
    required String kind,
    required String version,
    required ArtifactTrustAnchor trust,
    CancellationToken? cancel,
  }) async {
    if (kind != 'jar' && kind != 'apk') {
      return SourceFailed<IosTachiPreparedArtifact>(ArtifactIncompatibleFailure('$kind is not a Tachi artifact'));
    }
    final SourceOutcome<WorkerSupervisor> started = await worker();
    final WorkerSupervisor? supervisor = started.valueOrNull;
    if (supervisor == null) return SourceFailed<IosTachiPreparedArtifact>(started.failureOrNull!);
    final ArtifactLease raw;
    try {
      raw = await config.cache.admit(
        bytes,
        binding: ArtifactBinding(sha256: sha256.convert(bytes).toString(), kind: kind, version: version),
        profile: iosTachiDownloadProfile,
        verifier: (Uint8List b, ArtifactBinding binding) {},
      );
    } on ArtifactIntegrityException catch (e) {
      return SourceFailed<IosTachiPreparedArtifact>(ArtifactIncompatibleFailure(e.message));
    }
    try {
      final SourceOutcome<ArtifactLease> prepared = await supervisor.prepareArtifact(
        packageId: packageId,
        input: raw,
        trust: trust,
        cache: config.cache,
        hostCompatibility: iosTachiHostCompatibility,
        cancel: cancel,
      );
      return prepared.map(
        (ArtifactLease lease) => IosTachiPreparedArtifact._(packageId: packageId, lease: lease, input: raw.binding),
      );
    } finally {
      raw.release();
    }
  }

  @override
  Future<SourceOutcome<SourcePackage>> openPackage(
    VerifiedArtifact artifact,
    SettingsSnapshot settings, {
    CancellationToken? cancel,
  }) async {
    if (artifact is! IosTachiPreparedArtifact) {
      return const SourceFailed<SourcePackage>(
        ArtifactIncompatibleFailure('iOS Tachi packages load only artifacts prepared and verified in the VM'),
      );
    }
    if (artifact.lease.isReleased) {
      return const SourceFailed<SourcePackage>(ArtifactIncompatibleFailure('Prepared artifact lease was released'));
    }
    final _IosPackage? existing = _packages.remove(artifact.packageId);
    if (existing != null) await existing.close();
    final SourceOutcome<WorkerSupervisor> started = await worker();
    final WorkerSupervisor? supervisor = started.valueOrNull;
    if (supervisor == null) return SourceFailed<SourcePackage>(started.failureOrNull!);
    final SourceOutcome<PackageLoadResponse> loaded = await supervisor.loadPackage(
      WorkerPackage(packageId: artifact.packageId, artifact: artifact.lease, settings: settings),
      cancel: cancel,
    );
    final PackageLoadResponse? response = loaded.valueOrNull;
    if (response == null) return SourceFailed<SourcePackage>(loaded.failureOrNull!);
    if (response.sources.isEmpty) {
      await supervisor.unloadPackage(artifact.packageId);
      return SourceFailed<SourcePackage>(ArtifactIncompatibleFailure('${artifact.packageId} enumerates no sources'));
    }
    final sessions = <WorkerSourceSession>[
      for (final LoadedSource s in response.sources)
        WorkerSourceSession(
          supervisor: supervisor,
          identity: SourceIdentity(
            ecosystem: iosTachiEcosystem,
            packageId: artifact.packageId,
            sourceId: s.sourceId,
            artifact: artifact.binding,
          ),
          displayName: s.language == null ? s.name : '${s.name} (${s.language})',
          capabilities: s.capabilities,
          settingsRevision: settings.revision,
        ),
    ];
    for (final s in sessions) {
      _identities['${artifact.packageId}\u0000${s.identity.sourceId}'] = s.identity;
    }
    final package = _IosPackage(this, supervisor, artifact, sessions);
    _packages[artifact.packageId] = package;
    return SourceSuccess<SourcePackage>(package);
  }

  /// Shuts the worker down (protocol `shutdown`) and closes browser sessions.
  /// The VM stays up; a later call starts a new worker generation in it.
  Future<void> close() async {
    for (final _IosPackage p in _packages.values.toList()) {
      await p.close();
    }
    _packages.clear();
    await _scope.close();
  }
}

final class _IosPackage implements SourcePackage {
  _IosPackage(this._backend, this._supervisor, this.artifact, this.sessions);

  final IosTachiBackend _backend;
  final WorkerSupervisor _supervisor;
  final IosTachiPreparedArtifact artifact;
  bool _closed = false;

  @override
  String get packageId => artifact.packageId;

  @override
  final List<WorkerSourceSession> sessions;

  /// Closes the sessions (worker `dispose`) and unloads the package, releasing
  /// its class loader. The VM and other packages are unaffected.
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final WorkerSourceSession s in sessions) {
      await s.close();
      _backend._identities.remove('$packageId\u0000${s.identity.sourceId}');
    }
    if (identical(_backend._packages[packageId], this)) _backend._packages.remove(packageId);
    if (_supervisor.state == WorkerState.ready || _supervisor.state == WorkerState.restarting) {
      await _supervisor.unloadPackage(packageId);
    }
    artifact.lease.release();
  }
}
