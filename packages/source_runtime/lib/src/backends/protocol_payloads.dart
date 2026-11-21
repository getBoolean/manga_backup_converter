/// Typed request and response payloads of worker protocol 1.2 (KTD4).
///
/// These classes are the source of truth for every `payload` (request) and
/// `ok` (response) object; `doc/protocol-v1.md` describes the same shapes for
/// worker authors in other languages. Each class has `toJson` and `fromJson`
/// so both the supervisor and a Dart worker (Paperback, U6) use the same code.
///
/// Decoding is strict: a missing required field or a field of the wrong JSON
/// type throws [FormatException]. Unknown fields are ignored, so a worker may
/// add diagnostics without breaking the supervisor.
///
/// Minor 1 added `HandshakeRequest.protocolMinor` and the reply's
/// `protocolMinor`, `limits` and `sizing`; `ArtifactPrepareRequest
/// .trustedSigners`; string-set setting values; and source-scoped settings
/// (`SettingsPayload.sources`). Minor 2 added browser capabilities on
/// `host.browser.open`, `scriptError` on `host.browser.evaluate`, and the
/// `host.browser.addPageStartScript`, `setRequestInterception` and
/// `respond` reverse requests with the `host.browser.request` event. Fields
/// added in a minor version decode as absent from an older peer.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:source_runtime/src/contracts/browser_port.dart';
import 'package:source_runtime/src/contracts/identity.dart';
import 'package:source_runtime/src/contracts/outcome.dart';
import 'package:source_runtime/src/contracts/source.dart';

/// A JSON object payload.
abstract interface class ProtocolPayload {
  Map<String, Object?> toJson();
}

/// An operation with no data: `{}`.
final class EmptyPayload implements ProtocolPayload {
  const EmptyPayload();

  /// Accepts any object; unknown fields are ignored.
  factory EmptyPayload.fromJson(Map<String, Object?> _) => const EmptyPayload();

  @override
  Map<String, Object?> toJson() => const <String, Object?>{};
}

// -----------------------------------------------------------------------------
// Supervisor → worker operations
// -----------------------------------------------------------------------------

/// Operations the supervisor sends in `req` frames.
enum WorkerOperation {
  handshake('handshake', perPackage: false, requiresLoadedPackage: false),
  artifactPrepare('artifact.prepare', requiresLoadedPackage: false),
  packageLoad('package.load', requiresLoadedPackage: false),
  packageUnload('package.unload'),
  settingsUpdate('settings.update'),
  search('search'),
  details('details'),
  dispose('dispose'),
  shutdown('shutdown', perPackage: false, requiresLoadedPackage: false);

  const WorkerOperation(this.wire, {this.perPackage = true, this.requiresLoadedPackage = true});

  /// The frame's `op` value.
  final String wire;

  /// Whether the frame carries `pkg` and runs in that package's queue.
  final bool perPackage;

  /// Whether a worker must already hold the package to serve the operation.
  ///
  /// `artifact.prepare` runs before the package exists (it produces the
  /// bytes `package.load` loads) and `package.load` creates it; every other
  /// per-package operation, `package.unload` included, needs it loaded.
  final bool requiresLoadedPackage;

  static WorkerOperation? fromWire(String? wire) {
    for (final WorkerOperation o in values) {
      if (o.wire == wire) return o;
    }
    return null;
  }
}

/// A typed `req` payload whose `ok` reply decodes to [R].
sealed class WorkerRequest<R extends ProtocolPayload> implements ProtocolPayload {
  const WorkerRequest();

  WorkerOperation get operation;

  /// Decodes this operation's `ok` reply.
  R decodeResponse(Map<String, Object?> ok);

  /// Decodes a request payload as a worker receives it.
  static WorkerRequest<ProtocolPayload> fromWire(WorkerOperation operation, Map<String, Object?> payload) =>
      switch (operation) {
        WorkerOperation.handshake => HandshakeRequest.fromJson(payload),
        WorkerOperation.artifactPrepare => ArtifactPrepareRequest.fromJson(payload),
        WorkerOperation.packageLoad => PackageLoadRequest.fromJson(payload),
        WorkerOperation.packageUnload => PackageUnloadRequest.fromJson(payload),
        WorkerOperation.settingsUpdate => SettingsUpdateRequest.fromJson(payload),
        WorkerOperation.search => WorkerSearchRequest.fromJson(payload),
        WorkerOperation.details => WorkerDetailsRequest.fromJson(payload),
        WorkerOperation.dispose => DisposeRequest.fromJson(payload),
        WorkerOperation.shutdown => ShutdownRequest.fromJson(payload),
      };

  /// Worker-side admission shared by Dart workers: the failure to reply with
  /// before dispatching this request, or `null` to serve it.
  ///
  /// A per-package operation without `pkg` is a protocol violation; an
  /// operation that [WorkerOperation.requiresLoadedPackage] fails with
  /// `runtime-unavailable` when [isLoaded] says the package is absent. Every
  /// other request, including `artifact.prepare`, is admitted without a
  /// loaded package.
  SourceFailure? admissionFailure({required String? packageId, required bool Function(String packageId) isLoaded}) {
    if (!operation.perPackage) return null;
    if (packageId == null) return ProtocolViolationFailure('${operation.wire} requires pkg');
    if (operation.requiresLoadedPackage && !isLoaded(packageId)) {
      return RuntimeUnavailableFailure('Package $packageId is not loaded');
    }
    return null;
  }
}

/// `handshake` request: the protocol versions and frame limit the supervisor
/// speaks.
final class HandshakeRequest extends WorkerRequest<HandshakeResponse> {
  const HandshakeRequest({required this.protocolVersions, required this.maxFrameBytes, this.protocolMinor = 0});

  factory HandshakeRequest.fromJson(Map<String, Object?> json) => HandshakeRequest(
    protocolVersions: _list(json, 'protocolVersions', _asInt),
    maxFrameBytes: _int(json, 'maxFrameBytes'),
    protocolMinor: _optNonNegativeInt(json, 'protocolMinor') ?? 0,
  );

  /// Major versions the supervisor accepts; the envelope's `v`.
  final List<int> protocolVersions;
  final int maxFrameBytes;

  /// Highest minor version of the chosen major the supervisor speaks; absent
  /// (a 1.0 supervisor) decodes as `0`. The worker replies with the lower of
  /// this and its own highest minor.
  final int protocolMinor;

  @override
  WorkerOperation get operation => WorkerOperation.handshake;

  @override
  HandshakeResponse decodeResponse(Map<String, Object?> ok) => HandshakeResponse.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'protocolVersions': protocolVersions,
    'protocolMinor': protocolMinor,
    'maxFrameBytes': maxFrameBytes,
  };
}

/// `handshake` reply: the version the worker chose and what it can do.
final class HandshakeResponse implements ProtocolPayload {
  const HandshakeResponse({
    required this.protocolVersion,
    required this.worker,
    required this.capabilities,
    this.protocolMinor = 0,
    this.workerVersion,
    this.pid,
    this.limits,
    this.sizing,
  });

  factory HandshakeResponse.fromJson(Map<String, Object?> json) => HandshakeResponse(
    protocolVersion: _int(json, 'protocolVersion'),
    protocolMinor: _optNonNegativeInt(json, 'protocolMinor') ?? 0,
    worker: _string(json, 'worker'),
    workerVersion: _optString(json, 'workerVersion'),
    pid: _optInt(json, 'pid'),
    capabilities: WorkerCapabilities.fromJson(_object(json, 'capabilities')),
    limits: json['limits'] == null ? null : WorkerReportedLimits.fromJson(_object(json, 'limits')),
    sizing: json['sizing'] == null ? null : WorkerSizing.fromJson(_object(json, 'sizing')),
  );

  /// One of [HandshakeRequest.protocolVersions].
  final int protocolVersion;

  /// The negotiated minor version: at most [HandshakeRequest.protocolMinor].
  /// Absent (a 1.0 worker) decodes as `0`.
  final int protocolMinor;

  /// Worker implementation name, for example `tachi-jvm` or `paperback`.
  final String worker;
  final String? workerVersion;

  /// The worker's own PID, for diagnostics.
  final int? pid;
  final WorkerCapabilities capabilities;

  /// The runtime limits in effect in the worker (KTD25), when it reports
  /// them. A supervisor that opts in adopts the ones it understands.
  final WorkerReportedLimits? limits;

  /// How the worker derived [limits] (KTD25), when it reports it.
  final WorkerSizing? sizing;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'protocolVersion': protocolVersion,
    'protocolMinor': protocolMinor,
    'worker': worker,
    'workerVersion': workerVersion,
    'pid': pid,
    'capabilities': capabilities.toJson(),
    if (limits case final WorkerReportedLimits l) 'limits': l.toJson(),
    if (sizing case final WorkerSizing z) 'sizing': z.toJson(),
  };
}

/// The handshake's `limits` object: the runtime limits the worker runs with,
/// derived from its sizing rule on this device or from explicit overrides
/// (KTD25).
///
/// The supervisor-relevant limits have fixed names, each optional and a
/// positive integer when present: `poolSize` (packages that may run at
/// once), `operationDeadlineMs`, `cancelGraceMs`, `interactionTimeoutMs` and
/// `shutdownGraceMs`. Runtime-specific limits (for example Paperback's
/// QuickJS `memoryLimitBytes`) travel alongside and are kept in [fields]
/// without interpretation.
final class WorkerReportedLimits implements ProtocolPayload {
  WorkerReportedLimits({
    this.poolSize,
    this.operationDeadline,
    this.cancelGrace,
    this.interactionTimeout,
    this.shutdownGrace,
    Map<String, Object?> fields = const <String, Object?>{},
  }) : fields = Map<String, Object?>.unmodifiable(<String, Object?>{
         ...fields,
         if (poolSize != null) 'poolSize': poolSize,
         if (operationDeadline != null) 'operationDeadlineMs': operationDeadline.inMilliseconds,
         if (cancelGrace != null) 'cancelGraceMs': cancelGrace.inMilliseconds,
         if (interactionTimeout != null) 'interactionTimeoutMs': interactionTimeout.inMilliseconds,
         if (shutdownGrace != null) 'shutdownGraceMs': shutdownGrace.inMilliseconds,
       });

  factory WorkerReportedLimits.fromJson(Map<String, Object?> json) => WorkerReportedLimits(
    poolSize: _optPositiveInt(json, 'poolSize'),
    operationDeadline: _optMillis(json, 'operationDeadlineMs'),
    cancelGrace: _optMillis(json, 'cancelGraceMs'),
    interactionTimeout: _optMillis(json, 'interactionTimeoutMs'),
    shutdownGrace: _optMillis(json, 'shutdownGraceMs'),
    fields: json,
  );

  /// Packages the worker may execute concurrently.
  final int? poolSize;
  final Duration? operationDeadline;
  final Duration? cancelGrace;
  final Duration? interactionTimeout;
  final Duration? shutdownGrace;

  /// Every reported field, including runtime-specific ones.
  final Map<String, Object?> fields;

  static Duration? _optMillis(Map<String, Object?> json, String key) {
    final int? ms = _optPositiveInt(json, key);
    return ms == null ? null : Duration(milliseconds: ms);
  }

  @override
  Map<String, Object?> toJson() => fields;
}

/// The handshake's `sizing` object: the KTD25 sizing rule, the device
/// inputs it was applied to, the limits it derived, and which limits were
/// explicitly overridden. Every field is optional; the rule's own shape is
/// runtime-specific and kept as reported.
final class WorkerSizing implements ProtocolPayload {
  WorkerSizing({
    Map<String, Object?>? rule,
    Map<String, Object?> inputs = const <String, Object?>{},
    this.derived,
    Set<String> overridden = const <String>{},
    Map<String, Object?> fields = const <String, Object?>{},
  }) : rule = rule == null ? null : Map<String, Object?>.unmodifiable(rule),
       inputs = Map<String, Object?>.unmodifiable(inputs),
       overridden = Set<String>.unmodifiable(overridden),
       fields = Map<String, Object?>.unmodifiable(fields);

  factory WorkerSizing.fromJson(Map<String, Object?> json) => WorkerSizing(
    rule: json['rule'] == null ? null : _object(json, 'rule'),
    inputs: json['inputs'] == null ? const <String, Object?>{} : _object(json, 'inputs'),
    derived: json['derived'] == null ? null : WorkerReportedLimits.fromJson(_object(json, 'derived')),
    overridden: json['overridden'] == null ? const <String>{} : _list(json, 'overridden', _asString).toSet(),
    fields: json,
  );

  /// The committed sizing rule (coefficients and the benchmark it came
  /// from), or `null` when explicit overrides cover every limit.
  final Map<String, Object?>? rule;

  /// The measured device capability the rule was applied to, for example
  /// `cores` and `maxHeapMiB`.
  final Map<String, Object?> inputs;

  /// The limits the rule produced before overrides.
  final WorkerReportedLimits? derived;

  /// Names of limits set by explicit overrides rather than the rule.
  final Set<String> overridden;

  /// Every reported field, as received.
  final Map<String, Object?> fields;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    ...fields,
    'rule': rule,
    'inputs': inputs,
    'derived': derived?.toJson(),
    'overridden': overridden.toList()..sort(),
  };
}

/// Worker-wide capabilities announced in the handshake (KTD4).
final class WorkerCapabilities implements ProtocolPayload {
  WorkerCapabilities({Set<String> apiFamilies = const <String>{}, this.browser = false})
    : apiFamilies = Set<String>.unmodifiable(apiFamilies);

  factory WorkerCapabilities.fromJson(Map<String, Object?> json) => WorkerCapabilities(
    apiFamilies: _list(json, 'apiFamilies', _asString).toSet(),
    browser: _bool(json, 'browser'),
  );

  /// Source API versions the worker can host, for example `tachi-1.5` or
  /// `paperback-0.8`.
  final Set<String> apiFamilies;

  /// Whether the worker may send `host.browser.*` reverse requests.
  final bool browser;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'apiFamilies': apiFamilies.toList()..sort(),
    'browser': browser,
  };
}

/// `artifact.prepare` request: convert a verified input artifact into the
/// form the worker loads (for example APK → JAR through dex2jar, or JAR
/// signature verification), writing the result to [outputPath].
///
/// The worker re-verifies [inputPath] against [artifact] before reading it,
/// verifies the artifact's signature against [trustedSigners], and writes
/// only to [outputPath], which the supervisor chose inside its private
/// staging area. The package need not be loaded.
final class ArtifactPrepareRequest extends WorkerRequest<ArtifactPrepareResponse> {
  ArtifactPrepareRequest({
    required this.artifact,
    required this.inputPath,
    required this.outputPath,
    required Iterable<String> trustedSigners,
  }) : trustedSigners = List<String>.unmodifiable(
         trustedSigners.map(ArtifactTrustAnchor.normalizeFingerprint).toSet().toList()..sort(),
       );

  factory ArtifactPrepareRequest.fromJson(Map<String, Object?> json) => ArtifactPrepareRequest(
    artifact: _binding(json, 'artifact'),
    inputPath: _string(json, 'inputPath'),
    outputPath: _string(json, 'outputPath'),
    trustedSigners: json['trustedSigners'] == null ? const <String>[] : _list(json, 'trustedSigners', _asString),
  );

  final ArtifactBinding artifact;
  final String inputPath;
  final String outputPath;

  /// Certificate SHA-256 fingerprints (64 lowercase hex digits, sorted) from
  /// the stored trust anchor (KTD5). The artifact must be signed by one of
  /// them. A 1.0 supervisor omits the field, which decodes as empty; a
  /// worker must then refuse anything that needs a signer rather than trust
  /// one read beside the artifact.
  final List<String> trustedSigners;

  @override
  WorkerOperation get operation => WorkerOperation.artifactPrepare;

  @override
  ArtifactPrepareResponse decodeResponse(Map<String, Object?> ok) => ArtifactPrepareResponse.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'artifact': artifact.toJson(),
    'inputPath': inputPath,
    'outputPath': outputPath,
    'trustedSigners': trustedSigners,
  };
}

/// `artifact.prepare` reply: the binding of the bytes written to the output
/// path and the converter that produced them. The caller that sent the
/// request must re-hash the output and admit it to the artifact cache under
/// an `ArtifactProfile` built from [producer] and [converterVersion]; it
/// must never trust [artifact]'s digest alone.
final class ArtifactPrepareResponse implements ProtocolPayload {
  const ArtifactPrepareResponse({required this.artifact, required this.producer, required this.converterVersion});

  factory ArtifactPrepareResponse.fromJson(Map<String, Object?> json) => ArtifactPrepareResponse(
    artifact: _binding(json, 'artifact'),
    producer: _string(json, 'producer'),
    converterVersion: _string(json, 'converterVersion'),
  );

  final ArtifactBinding artifact;
  final String producer;
  final String converterVersion;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'artifact': artifact.toJson(),
    'producer': producer,
    'converterVersion': converterVersion,
  };
}

/// Settings as sent to a worker: typed non-secret values, secret values,
/// per-source overrides, and the durable revision. Secrets cross the pipe to
/// the worker only; the supervisor registers them with its redactor first
/// (KTD9).
///
/// [values] and [secrets] apply to every source of the package. [sources]
/// overrides them for one source, keyed by the source ID from
/// `package.load`: the effective settings of source `S` are [values] with
/// `sources[S].values` laid over them (likewise for secrets). Keys are
/// plain setting keys; they carry no source prefix.
final class SettingsPayload implements ProtocolPayload {
  SettingsPayload({
    required Map<String, Object> values,
    required Map<String, String> secrets,
    required this.revision,
    Map<String, SourceScopedSettings> sources = const <String, SourceScopedSettings>{},
  }) : values = Map<String, Object>.unmodifiable(values),
       secrets = Map<String, String>.unmodifiable(secrets),
       sources = Map<String, SourceScopedSettings>.unmodifiable(sources);

  factory SettingsPayload.fromSnapshot(SettingsSnapshot snapshot) => SettingsPayload(
    values: snapshot.values,
    secrets: snapshot.secrets,
    sources: snapshot.sources,
    revision: snapshot.revision,
  );

  factory SettingsPayload.fromJson(Map<String, Object?> json) => SettingsPayload(
    values: SettingsSnapshot.valuesFromJson(_object(json, 'values')),
    secrets: _stringMap(json, 'secrets'),
    revision: _string(json, 'revision'),
    sources: json['sources'] == null
        ? const <String, SourceScopedSettings>{}
        : <String, SourceScopedSettings>{
            for (final MapEntry<String, Object?> e in _object(json, 'sources').entries)
              e.key: _scope('sources.${e.key}', e.value),
          },
  );

  /// Each a `String`, `bool`, `int` or sorted, deduplicated `List<String>`.
  final Map<String, Object> values;
  final Map<String, String> secrets;

  /// Per-source overrides keyed by source ID; absent from a 1.0 supervisor.
  final Map<String, SourceScopedSettings> sources;
  final String revision;

  /// Whether a 1.0 worker could not read this payload (string sets or
  /// source scopes).
  bool get needsProtocol11 => sources.isNotEmpty || values.values.any((Object v) => v is List<String>);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'values': values,
    'secrets': secrets,
    if (sources.isNotEmpty)
      'sources': <String, Object?>{
        for (final MapEntry<String, SourceScopedSettings> e in sources.entries)
          e.key: <String, Object?>{'values': e.value.values, 'secrets': e.value.secrets},
      },
    'revision': revision,
  };
}

SourceScopedSettings _scope(String key, Object? json) {
  if (json is! Map<Object?, Object?>) _bad(key, 'an object', json);
  final Map<String, Object?> scope = json.cast<String, Object?>();
  return SourceScopedSettings(
    values: scope['values'] == null
        ? const <String, Object>{}
        : SettingsSnapshot.valuesFromJson(_object(scope, 'values')),
    secrets: scope['secrets'] == null ? const <String, String>{} : _stringMap(scope, 'secrets'),
  );
}

/// `package.load` request: load the verified artifact at [path] into its own
/// class loader or runtime with [settings].
final class PackageLoadRequest extends WorkerRequest<PackageLoadResponse> {
  const PackageLoadRequest({required this.artifact, required this.path, required this.settings});

  factory PackageLoadRequest.fromJson(Map<String, Object?> json) => PackageLoadRequest(
    artifact: _binding(json, 'artifact'),
    path: _string(json, 'path'),
    settings: SettingsPayload.fromJson(_object(json, 'settings')),
  );

  final ArtifactBinding artifact;

  /// Path of the privately staged, just re-verified artifact.
  final String path;
  final SettingsPayload settings;

  @override
  WorkerOperation get operation => WorkerOperation.packageLoad;

  @override
  PackageLoadResponse decodeResponse(Map<String, Object?> ok) => PackageLoadResponse.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'artifact': artifact.toJson(),
    'path': path,
    'settings': settings.toJson(),
  };
}

/// `package.load` reply: every source the package's factory enumerated.
final class PackageLoadResponse implements ProtocolPayload {
  PackageLoadResponse({required List<LoadedSource> sources}) : sources = List<LoadedSource>.unmodifiable(sources);

  factory PackageLoadResponse.fromJson(Map<String, Object?> json) =>
      PackageLoadResponse(sources: _list(json, 'sources', (Object? s) => LoadedSource.fromJson(_asObject(s))));

  final List<LoadedSource> sources;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'sources': <Object?>[for (final LoadedSource s in sources) s.toJson()],
  };
}

/// One source enumerated by a loaded package.
final class LoadedSource implements ProtocolPayload {
  const LoadedSource({required this.sourceId, required this.name, required this.capabilities, this.language});

  factory LoadedSource.fromJson(Map<String, Object?> json) => LoadedSource(
    sourceId: _string(json, 'sourceId'),
    name: _string(json, 'name'),
    language: _optString(json, 'language'),
    capabilities: SourceCapabilities.fromJson(_object(json, 'capabilities')),
  );

  /// Always a string; Tachi sends the decimal form of its int64 ID (KTD3).
  final String sourceId;
  final String name;
  final String? language;
  final SourceCapabilities capabilities;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'name': name,
    'language': language,
    'capabilities': capabilities.toJson(),
  };
}

/// `package.unload` request: release the package, its sources, live handles
/// and class loader. The supervisor stops reloading it after restarts.
final class PackageUnloadRequest extends WorkerRequest<EmptyPayload> {
  const PackageUnloadRequest();

  factory PackageUnloadRequest.fromJson(Map<String, Object?> _) => const PackageUnloadRequest();

  @override
  WorkerOperation get operation => WorkerOperation.packageUnload;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => const <String, Object?>{};
}

/// `settings.update` request: replace the package's whole settings snapshot.
/// Later operations carry the new revision; references confirmed under the
/// old one are stale (KTD3).
final class SettingsUpdateRequest extends WorkerRequest<EmptyPayload> {
  const SettingsUpdateRequest({required this.settings});

  factory SettingsUpdateRequest.fromJson(Map<String, Object?> json) =>
      SettingsUpdateRequest(settings: SettingsPayload.fromJson(_object(json, 'settings')));

  final SettingsPayload settings;

  @override
  WorkerOperation get operation => WorkerOperation.settingsUpdate;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'settings': settings.toJson()};
}

/// `search` request for one source of the package.
final class WorkerSearchRequest extends WorkerRequest<WorkerSearchResponse> {
  const WorkerSearchRequest({required this.source, required this.settingsRevision, required this.request});

  factory WorkerSearchRequest.fromJson(Map<String, Object?> json) => WorkerSearchRequest(
    source: SourceIdentity.fromJson(_object(json, 'source')),
    settingsRevision: _string(json, 'settingsRevision'),
    request: SearchRequest(query: _string(json, 'query'), cursor: _optString(json, 'cursor')),
  );

  final SourceIdentity source;
  final String settingsRevision;
  final SearchRequest request;

  @override
  WorkerOperation get operation => WorkerOperation.search;

  @override
  WorkerSearchResponse decodeResponse(Map<String, Object?> ok) => WorkerSearchResponse.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'source': source.toJson(),
    'settingsRevision': settingsRevision,
    ...request.toJson(),
  };
}

/// `search` reply: one page of hits. An empty [hits] list is a successful
/// empty result.
final class WorkerSearchResponse implements ProtocolPayload {
  WorkerSearchResponse({required List<WorkerSearchHit> hits, this.nextCursor, List<String> warnings = const <String>[]})
    : hits = List<WorkerSearchHit>.unmodifiable(hits),
      warnings = List<String>.unmodifiable(warnings);

  factory WorkerSearchResponse.fromJson(Map<String, Object?> json) => WorkerSearchResponse(
    hits: _list(json, 'hits', (Object? h) => WorkerSearchHit.fromJson(_asObject(h))),
    nextCursor: _optString(json, 'nextCursor'),
    warnings: json['warnings'] == null ? const <String>[] : _list(json, 'warnings', _asString),
  );

  final List<WorkerSearchHit> hits;

  /// Opaque token for the next page; `null` when there is none.
  final String? nextCursor;
  final List<String> warnings;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'hits': <Object?>[for (final WorkerSearchHit h in hits) h.toJson()],
    'nextCursor': nextCursor,
    'warnings': warnings,
  };
}

/// A search hit plus the optional ephemeral handle of the live object the
/// worker cached for it. The handle is valid only in the generation of the
/// reply (KTD3).
final class WorkerSearchHit implements ProtocolPayload {
  const WorkerSearchHit({required this.hit, this.handle});

  factory WorkerSearchHit.fromJson(Map<String, Object?> json) {
    _requireObject(json, 'ref');
    _string(json, 'title');
    return WorkerSearchHit(hit: SearchHit.fromJson(json), handle: _optString(json, 'handle'));
  }

  final SearchHit hit;
  final String? handle;

  @override
  Map<String, Object?> toJson() => <String, Object?>{...hit.toJson(), 'handle': handle};
}

/// `details` request: metadata and the complete chapter list for [ref].
///
/// [handle] is sent only when it was issued in the current generation; after
/// a restart the worker must rehydrate from [ref] alone or fail with
/// `stale-reference` (KTD3).
final class WorkerDetailsRequest extends WorkerRequest<WorkerDetailsResponse> {
  const WorkerDetailsRequest({required this.source, required this.settingsRevision, required this.ref, this.handle});

  factory WorkerDetailsRequest.fromJson(Map<String, Object?> json) => WorkerDetailsRequest(
    source: SourceIdentity.fromJson(_object(json, 'source')),
    settingsRevision: _string(json, 'settingsRevision'),
    ref: NativeMangaRef.fromJson(_object(json, 'ref')),
    handle: _optString(json, 'handle'),
  );

  final SourceIdentity source;
  final String settingsRevision;
  final NativeMangaRef ref;
  final String? handle;

  @override
  WorkerOperation get operation => WorkerOperation.details;

  @override
  WorkerDetailsResponse decodeResponse(Map<String, Object?> ok) => WorkerDetailsResponse.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'source': source.toJson(),
    'settingsRevision': settingsRevision,
    'ref': ref.toJson(),
    'handle': handle,
  };
}

/// `details` reply: a complete fetch. Missing data is an `err` reply, never
/// an empty `ok`.
final class WorkerDetailsResponse implements ProtocolPayload {
  WorkerDetailsResponse({required this.metadata, required List<NativeChapter> chapters})
    : chapters = List<NativeChapter>.unmodifiable(chapters);

  factory WorkerDetailsResponse.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> metadata = _object(json, 'metadata');
    _string(metadata, 'title');
    return WorkerDetailsResponse(
      metadata: MangaMetadata.fromJson(metadata),
      chapters: _list(json, 'chapters', (Object? c) {
        final Map<String, Object?> chapter = _asObject(c);
        _string(chapter, 'chapterId');
        _int(chapter, 'sourceOrder');
        return NativeChapter.fromJson(chapter);
      }),
    );
  }

  final MangaMetadata metadata;
  final List<NativeChapter> chapters;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'metadata': metadata.toJson(),
    'chapters': <Object?>[for (final NativeChapter c in chapters) c.toJson()],
  };
}

/// `dispose` request: drop the live objects behind ephemeral handles of
/// [source]. `null` [handles] releases every handle issued for that source.
/// Durable references stay valid; the worker rehydrates from them later.
final class DisposeRequest extends WorkerRequest<EmptyPayload> {
  DisposeRequest({required this.source, List<String>? handles})
    : handles = handles == null ? null : List<String>.unmodifiable(handles);

  factory DisposeRequest.fromJson(Map<String, Object?> json) => DisposeRequest(
    source: SourceIdentity.fromJson(_object(json, 'source')),
    handles: json['handles'] == null ? null : _list(json, 'handles', _asString),
  );

  final SourceIdentity source;
  final List<String>? handles;

  @override
  WorkerOperation get operation => WorkerOperation.dispose;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'source': source.toJson(), 'handles': handles};
}

/// `shutdown` request: reply, flush, and exit. The supervisor kills the
/// process if it has not exited within its shutdown grace.
final class ShutdownRequest extends WorkerRequest<EmptyPayload> {
  const ShutdownRequest();

  factory ShutdownRequest.fromJson(Map<String, Object?> _) => const ShutdownRequest();

  @override
  WorkerOperation get operation => WorkerOperation.shutdown;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => const <String, Object?>{};
}

// -----------------------------------------------------------------------------
// Worker → supervisor reverse requests (`host.browser.*`, KTD20)
// -----------------------------------------------------------------------------

/// Reverse operations a worker sends in `rreq` frames.
enum HostBrowserOperation {
  open('host.browser.open'),
  load('host.browser.load'),
  loadData('host.browser.loadData'),
  evaluate('host.browser.evaluate'),
  setMessageHandler('host.browser.setMessageHandler'),
  getCookies('host.browser.getCookies'),
  setCookie('host.browser.setCookie'),
  setUserAgent('host.browser.setUserAgent'),
  show('host.browser.show'),
  close('host.browser.close'),
  addPageStartScript('host.browser.addPageStartScript', sinceMinor: 2),
  setRequestInterception('host.browser.setRequestInterception', sinceMinor: 2),
  respond('host.browser.respond', sinceMinor: 2);

  const HostBrowserOperation(this.wire, {this.sinceMinor = 0});

  final String wire;

  /// The protocol minor version that introduced this operation. A worker
  /// that negotiated a lower minor may not send it.
  final int sinceMinor;

  static HostBrowserOperation? fromWire(String? wire) {
    for (final HostBrowserOperation o in values) {
      if (o.wire == wire) return o;
    }
    return null;
  }
}

/// A typed `rreq` payload whose `ok` reply decodes to [R].
sealed class HostBrowserRequest<R extends ProtocolPayload> implements ProtocolPayload {
  const HostBrowserRequest();

  HostBrowserOperation get operation;

  /// Decodes this operation's `ok` reply.
  R decodeResponse(Map<String, Object?> ok);

  /// Decodes a reverse request payload as the supervisor receives it.
  static HostBrowserRequest<ProtocolPayload> fromWire(HostBrowserOperation operation, Map<String, Object?> p) =>
      switch (operation) {
        HostBrowserOperation.open => HostBrowserOpen.fromJson(p),
        HostBrowserOperation.load => HostBrowserLoad.fromJson(p),
        HostBrowserOperation.loadData => HostBrowserLoadData.fromJson(p),
        HostBrowserOperation.evaluate => HostBrowserEvaluate.fromJson(p),
        HostBrowserOperation.setMessageHandler => HostBrowserSetMessageHandler.fromJson(p),
        HostBrowserOperation.getCookies => HostBrowserGetCookies.fromJson(p),
        HostBrowserOperation.setCookie => HostBrowserSetCookie.fromJson(p),
        HostBrowserOperation.setUserAgent => HostBrowserSetUserAgent.fromJson(p),
        HostBrowserOperation.show => HostBrowserShow.fromJson(p),
        HostBrowserOperation.close => HostBrowserClose.fromJson(p),
        HostBrowserOperation.addPageStartScript => HostBrowserAddPageStartScript.fromJson(p),
        HostBrowserOperation.setRequestInterception => HostBrowserSetRequestInterception.fromJson(p),
        HostBrowserOperation.respond => HostBrowserRespond.fromJson(p),
      };
}

/// A reverse request addressed to an open browser session.
sealed class HostBrowserSessionRequest<R extends ProtocolPayload> extends HostBrowserRequest<R> {
  const HostBrowserSessionRequest({required this.session});

  /// Session ID from [HostBrowserOpened.session].
  final String session;
}

/// `host.browser.open`: open a session scoped to [sourceId] of the
/// requesting package.
final class HostBrowserOpen extends HostBrowserRequest<HostBrowserOpened> {
  const HostBrowserOpen({required this.sourceId, this.userAgent});

  factory HostBrowserOpen.fromJson(Map<String, Object?> json) =>
      HostBrowserOpen(sourceId: _string(json, 'sourceId'), userAgent: _optString(json, 'userAgent'));

  final String sourceId;
  final String? userAgent;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.open;

  @override
  HostBrowserOpened decodeResponse(Map<String, Object?> ok) => HostBrowserOpened.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'sourceId': sourceId, 'userAgent': userAgent};
}

/// Reply to [HostBrowserOpen].
final class HostBrowserOpened implements ProtocolPayload {
  const HostBrowserOpened({required this.session, this.capabilities});

  factory HostBrowserOpened.fromJson(Map<String, Object?> json) => HostBrowserOpened(
    session: _string(json, 'session'),
    capabilities: json['capabilities'] == null ? null : BrowserCapabilities.fromJson(_object(json, 'capabilities')),
  );

  final String session;

  /// The session's optional features (1.2); `null` from an older peer,
  /// which reads as [BrowserCapabilities.unreported]. The supervisor sends
  /// it only to a worker that negotiated 1.2.
  final BrowserCapabilities? capabilities;

  /// [capabilities], or nothing optional when absent.
  BrowserCapabilities get effectiveCapabilities => capabilities ?? BrowserCapabilities.unreported();

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'session': session,
    if (capabilities != null) 'capabilities': capabilities!.toJson(),
  };
}

/// `host.browser.load`: navigate to an http(s) [url].
final class HostBrowserLoad extends HostBrowserSessionRequest<HostBrowserPage> {
  HostBrowserLoad({required super.session, required this.url, Map<String, String> headers = const <String, String>{}})
    : headers = Map<String, String>.unmodifiable(headers);

  factory HostBrowserLoad.fromJson(Map<String, Object?> json) => HostBrowserLoad(
    session: _string(json, 'session'),
    url: _uri(json, 'url'),
    headers: json['headers'] == null ? const <String, String>{} : _stringMap(json, 'headers'),
  );

  final Uri url;
  final Map<String, String> headers;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.load;

  @override
  HostBrowserPage decodeResponse(Map<String, Object?> ok) => HostBrowserPage.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session, 'url': url.toString(), 'headers': headers};
}

/// `host.browser.loadData`: load [html] with an http(s) [baseUrl].
final class HostBrowserLoadData extends HostBrowserSessionRequest<HostBrowserPage> {
  const HostBrowserLoadData({required super.session, required this.html, required this.baseUrl});

  factory HostBrowserLoadData.fromJson(Map<String, Object?> json) => HostBrowserLoadData(
    session: _string(json, 'session'),
    html: _string(json, 'html'),
    baseUrl: _uri(json, 'baseUrl'),
  );

  final String html;
  final Uri baseUrl;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.loadData;

  @override
  HostBrowserPage decodeResponse(Map<String, Object?> ok) => HostBrowserPage.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session, 'html': html, 'baseUrl': baseUrl.toString()};
}

/// Reply to [HostBrowserLoad] and [HostBrowserLoadData].
final class HostBrowserPage implements ProtocolPayload {
  const HostBrowserPage({required this.finalUrl, this.status});

  factory HostBrowserPage.fromJson(Map<String, Object?> json) =>
      HostBrowserPage(finalUrl: _uri(json, 'finalUrl'), status: _optInt(json, 'status'));

  /// URL after redirects.
  final Uri finalUrl;

  /// HTTP status of the main document, when the platform reports it.
  final int? status;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'finalUrl': finalUrl.toString(), 'status': status};
}

/// `host.browser.evaluate`: run [script] in the page.
final class HostBrowserEvaluate extends HostBrowserSessionRequest<HostBrowserEvaluated> {
  const HostBrowserEvaluate({required super.session, required this.script});

  factory HostBrowserEvaluate.fromJson(Map<String, Object?> json) =>
      HostBrowserEvaluate(session: _string(json, 'session'), script: _string(json, 'script'));

  final String script;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.evaluate;

  @override
  HostBrowserEvaluated decodeResponse(Map<String, Object?> ok) => HostBrowserEvaluated.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session, 'script': script};
}

/// Reply to [HostBrowserEvaluate].
final class HostBrowserEvaluated implements ProtocolPayload {
  const HostBrowserEvaluated({required this.result, this.scriptError});

  /// The reply for a script that threw: `result` is `null`, so a peer that
  /// ignores [scriptError] sees Android `evaluateJavascript` semantics.
  const HostBrowserEvaluated.scriptError(String this.scriptError) : result = 'null';

  factory HostBrowserEvaluated.fromJson(Map<String, Object?> json) =>
      HostBrowserEvaluated(result: _string(json, 'result'), scriptError: _optString(json, 'scriptError'));

  /// The script's value as JSON text (`"ok"`, `42`, `null`). `null` when the
  /// script threw.
  final String result;

  /// The thrown value's description when the script threw (1.2); absent
  /// otherwise, and always absent from an engine without
  /// `BrowserFeature.scriptErrors`.
  final String? scriptError;

  /// This reply as a [BrowserOutcome]: [BrowserScriptError] when the script
  /// threw.
  BrowserOutcome<String> toOutcome() =>
      scriptError == null ? BrowserCompleted<String>(result) : BrowserScriptError<String>(scriptError!);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'result': result, 'scriptError': ?scriptError};
}

/// `host.browser.setMessageHandler`: start or stop delivering page messages
/// posted to [name] as [HostBrowserMessage] events.
final class HostBrowserSetMessageHandler extends HostBrowserSessionRequest<EmptyPayload> {
  const HostBrowserSetMessageHandler({required super.session, required this.name, required this.enabled});

  factory HostBrowserSetMessageHandler.fromJson(Map<String, Object?> json) => HostBrowserSetMessageHandler(
    session: _string(json, 'session'),
    name: _string(json, 'name'),
    enabled: _bool(json, 'enabled'),
  );

  final String name;
  final bool enabled;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.setMessageHandler;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session, 'name': name, 'enabled': enabled};
}

/// `host.browser.getCookies`: cookies the session would send to [url].
final class HostBrowserGetCookies extends HostBrowserSessionRequest<HostBrowserCookies> {
  const HostBrowserGetCookies({required super.session, required this.url});

  factory HostBrowserGetCookies.fromJson(Map<String, Object?> json) =>
      HostBrowserGetCookies(session: _string(json, 'session'), url: _uri(json, 'url'));

  final Uri url;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.getCookies;

  @override
  HostBrowserCookies decodeResponse(Map<String, Object?> ok) => HostBrowserCookies.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session, 'url': url.toString()};
}

/// Reply to [HostBrowserGetCookies].
final class HostBrowserCookies implements ProtocolPayload {
  HostBrowserCookies({required List<BrowserCookie> cookies}) : cookies = List<BrowserCookie>.unmodifiable(cookies);

  factory HostBrowserCookies.fromJson(Map<String, Object?> json) =>
      HostBrowserCookies(cookies: _list(json, 'cookies', (Object? c) => _cookie(_asObject(c))));

  final List<BrowserCookie> cookies;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'cookies': <Object?>[for (final BrowserCookie c in cookies) c.toJson()],
  };
}

/// `host.browser.setCookie`: store [cookie] for [url] in the session.
final class HostBrowserSetCookie extends HostBrowserSessionRequest<EmptyPayload> {
  const HostBrowserSetCookie({required super.session, required this.url, required this.cookie});

  factory HostBrowserSetCookie.fromJson(Map<String, Object?> json) => HostBrowserSetCookie(
    session: _string(json, 'session'),
    url: _uri(json, 'url'),
    cookie: _cookie(_object(json, 'cookie')),
  );

  final Uri url;
  final BrowserCookie cookie;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.setCookie;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'session': session,
    'url': url.toString(),
    'cookie': cookie.toJson(),
  };
}

/// `host.browser.setUserAgent`.
final class HostBrowserSetUserAgent extends HostBrowserSessionRequest<EmptyPayload> {
  const HostBrowserSetUserAgent({required super.session, required this.userAgent});

  factory HostBrowserSetUserAgent.fromJson(Map<String, Object?> json) =>
      HostBrowserSetUserAgent(session: _string(json, 'session'), userAgent: _string(json, 'userAgent'));

  final String userAgent;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.setUserAgent;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session, 'userAgent': userAgent};
}

/// `host.browser.show`: show the session for a user interaction. The
/// originating operation's deadline is paused while it is open and the
/// interaction is bounded separately (KTD4).
final class HostBrowserShow extends HostBrowserSessionRequest<EmptyPayload> {
  const HostBrowserShow({required super.session});

  factory HostBrowserShow.fromJson(Map<String, Object?> json) => HostBrowserShow(session: _string(json, 'session'));

  @override
  HostBrowserOperation get operation => HostBrowserOperation.show;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session};
}

/// `host.browser.close`: close the session and delete its storage.
final class HostBrowserClose extends HostBrowserSessionRequest<EmptyPayload> {
  const HostBrowserClose({required super.session});

  factory HostBrowserClose.fromJson(Map<String, Object?> json) => HostBrowserClose(session: _string(json, 'session'));

  @override
  HostBrowserOperation get operation => HostBrowserOperation.close;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session};
}

/// `host.browser.addPageStartScript` (1.2): run [script] at document start
/// in every frame of every later document of the session
/// (`BrowserSession.addPageStartScript`).
final class HostBrowserAddPageStartScript extends HostBrowserSessionRequest<EmptyPayload> {
  const HostBrowserAddPageStartScript({required super.session, required this.script});

  factory HostBrowserAddPageStartScript.fromJson(Map<String, Object?> json) =>
      HostBrowserAddPageStartScript(session: _string(json, 'session'), script: _string(json, 'script'));

  final String script;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.addPageStartScript;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session, 'script': script};
}

/// Interception mode of [HostBrowserSetRequestInterception].
enum HostBrowserInterception {
  /// No interception.
  none,

  /// Observe tier: `host.browser.request` events without `requestId`;
  /// requests proceed unchanged.
  observe,

  /// Replace tier: `host.browser.request` events with `requestId`, each
  /// answered by `host.browser.respond`.
  replace;

  static HostBrowserInterception? fromWire(String wire) {
    for (final HostBrowserInterception m in values) {
      if (m.name == wire) return m;
    }
    return null;
  }
}

/// `host.browser.setRequestInterception` (1.2): select the session's
/// request interceptor (`BrowserSession.setRequestObserver` and
/// `setRequestReplacer`; at most one at a time).
final class HostBrowserSetRequestInterception extends HostBrowserSessionRequest<EmptyPayload> {
  const HostBrowserSetRequestInterception({required super.session, required this.mode});

  factory HostBrowserSetRequestInterception.fromJson(Map<String, Object?> json) {
    final String wire = _string(json, 'mode');
    return HostBrowserSetRequestInterception(
      session: _string(json, 'session'),
      mode: HostBrowserInterception.fromWire(wire) ?? _bad('mode', 'one of none, observe, replace', wire),
    );
  }

  final HostBrowserInterception mode;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.setRequestInterception;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session, 'mode': mode.name};
}

/// `host.browser.respond` (1.2): answer the held request [requestId] of a
/// `host.browser.request` event with [response], or with `null` to let it
/// proceed unchanged.
final class HostBrowserRespond extends HostBrowserSessionRequest<EmptyPayload> {
  const HostBrowserRespond({required super.session, required this.requestId, this.response});

  factory HostBrowserRespond.fromJson(Map<String, Object?> json) => HostBrowserRespond(
    session: _string(json, 'session'),
    requestId: _string(json, 'requestId'),
    response: json['response'] == null ? null : browserReplacementFromJson(_object(json, 'response')),
  );

  final String requestId;
  final BrowserReplacement? response;

  @override
  HostBrowserOperation get operation => HostBrowserOperation.respond;

  @override
  EmptyPayload decodeResponse(Map<String, Object?> ok) => EmptyPayload.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'session': session,
    'requestId': requestId,
    'response': response == null ? null : browserReplacementToJson(response!),
  };
}

/// Largest request body a `host.browser.request` event carries (1 MiB).
/// Larger bodies are omitted (`bodyOmitted: true`) so that one upload can
/// never push an event past the frame limit.
const int hostBrowserMaxForwardedBodyBytes = 1024 * 1024;

/// `host.browser.request` event (1.2, supervisor → worker): a page of
/// [session] made [request]. With [requestId] the request is held until the
/// worker answers with [HostBrowserRespond]; without it the request is only
/// observed.
final class HostBrowserRequestEvent implements ProtocolPayload {
  const HostBrowserRequestEvent({required this.session, required this.request, this.requestId});

  factory HostBrowserRequestEvent.fromJson(Map<String, Object?> json) {
    final String? bodyBase64 = _optString(json, 'bodyBase64');
    final Uint8List? body;
    try {
      body = bodyBase64 == null ? null : base64Decode(bodyBase64);
    } on FormatException {
      _bad('bodyBase64', 'base64 text', bodyBase64);
    }
    return HostBrowserRequestEvent(
      session: _string(json, 'session'),
      requestId: _optString(json, 'requestId'),
      request: BrowserRequest(
        url: _uri(json, 'url'),
        method: _string(json, 'method'),
        headers: json['headers'] == null ? const <String, String>{} : _stringMap(json, 'headers'),
        body: body,
        bodyOmitted: _optBool(json, 'bodyOmitted') ?? false,
        mainFrame: _optBool(json, 'mainFrame') ?? false,
        redirect: _optBool(json, 'redirect') ?? false,
        context: BrowserRequestContext.fromWire(_optString(json, 'context')),
      ),
    );
  }

  /// Builds the event for [request], omitting a body larger than
  /// [hostBrowserMaxForwardedBodyBytes].
  factory HostBrowserRequestEvent.forward({
    required String session,
    required BrowserRequest request,
    String? requestId,
  }) {
    final Uint8List? body = request.body;
    if (body == null || body.length <= hostBrowserMaxForwardedBodyBytes) {
      return HostBrowserRequestEvent(session: session, request: request, requestId: requestId);
    }
    return HostBrowserRequestEvent(
      session: session,
      requestId: requestId,
      request: BrowserRequest(
        url: request.url,
        method: request.method,
        headers: request.headers,
        bodyOmitted: true,
        mainFrame: request.mainFrame,
        redirect: request.redirect,
        context: request.context,
      ),
    );
  }

  /// The event frame's `op`.
  static const String op = 'host.browser.request';

  final String session;

  /// Present when the request is held for a [HostBrowserRespond].
  final String? requestId;
  final BrowserRequest request;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'session': session,
    'requestId': requestId,
    'method': request.method,
    'url': request.url.toString(),
    'headers': request.headers,
    'bodyBase64': request.body == null ? null : base64Encode(request.body!),
    'bodyOmitted': request.bodyOmitted,
    'mainFrame': request.mainFrame,
    'redirect': request.redirect,
    'context': request.context.name,
  };
}

/// Encodes [r] as `{status, reason, headers, bodyBase64}`.
Map<String, Object?> browserReplacementToJson(BrowserReplacement r) => <String, Object?>{
  'status': r.status,
  'reason': r.reason,
  'headers': r.headers,
  'bodyBase64': base64Encode(r.body),
};

/// Decodes `{status, reason?, headers?, bodyBase64?}`, refusing a
/// replacement with a [BrowserReplacement.invalidReason].
BrowserReplacement browserReplacementFromJson(Map<String, Object?> json) {
  final String? bodyBase64 = _optString(json, 'bodyBase64');
  final List<int> body;
  try {
    body = bodyBase64 == null ? const <int>[] : base64Decode(bodyBase64);
  } on FormatException {
    _bad('bodyBase64', 'base64 text', bodyBase64);
  }
  final replacement = BrowserReplacement(
    status: _int(json, 'status'),
    reason: _optString(json, 'reason') ?? 'OK',
    headers: json['headers'] == null ? const <String, String>{} : _stringMap(json, 'headers'),
    body: body,
  );
  final String? invalid = replacement.invalidReason;
  if (invalid != null) throw FormatException('Invalid replacement: $invalid');
  return replacement;
}

/// `host.browser.message` event (supervisor → worker): a page posted
/// [message] to the handler [name] of [session].
final class HostBrowserMessage implements ProtocolPayload {
  const HostBrowserMessage({required this.session, required this.name, required this.message});

  factory HostBrowserMessage.fromJson(Map<String, Object?> json) => HostBrowserMessage(
    session: _string(json, 'session'),
    name: _string(json, 'name'),
    message: _string(json, 'message'),
  );

  /// The event frame's `op`.
  static const String op = 'host.browser.message';

  final String session;
  final String name;
  final String message;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session, 'name': name, 'message': message};
}

// -----------------------------------------------------------------------------
// Strict JSON field readers
// -----------------------------------------------------------------------------

Never _bad(String key, String expected, Object? value) =>
    throw FormatException('Field "$key" must be $expected, got ${value == null ? 'null' : value.runtimeType}');

String _string(Map<String, Object?> json, String key) => switch (json[key]) {
  final String s => s,
  final Object? v => _bad(key, 'a string', v),
};

String? _optString(Map<String, Object?> json, String key) => switch (json[key]) {
  null => null,
  final String s => s,
  final Object v => _bad(key, 'a string or null', v),
};

int _int(Map<String, Object?> json, String key) => switch (json[key]) {
  final int i => i,
  final Object? v => _bad(key, 'an integer', v),
};

int? _optInt(Map<String, Object?> json, String key) => switch (json[key]) {
  null => null,
  final int i => i,
  final Object v => _bad(key, 'an integer or null', v),
};

int? _optPositiveInt(Map<String, Object?> json, String key) => switch (json[key]) {
  null => null,
  final int i when i > 0 => i,
  final Object v => _bad(key, 'a positive integer or null', v),
};

int? _optNonNegativeInt(Map<String, Object?> json, String key) => switch (json[key]) {
  null => null,
  final int i when i >= 0 => i,
  final Object v => _bad(key, 'a non-negative integer or null', v),
};

bool _bool(Map<String, Object?> json, String key) => switch (json[key]) {
  final bool b => b,
  final Object? v => _bad(key, 'a boolean', v),
};

bool? _optBool(Map<String, Object?> json, String key) => switch (json[key]) {
  null => null,
  final bool b => b,
  final Object v => _bad(key, 'a boolean or null', v),
};

Map<String, Object?> _object(Map<String, Object?> json, String key) => switch (json[key]) {
  final Map<Object?, Object?> m => m.cast<String, Object?>(),
  final Object? v => _bad(key, 'an object', v),
};

void _requireObject(Map<String, Object?> json, String key) => _object(json, key);

Map<String, String> _stringMap(Map<String, Object?> json, String key) => <String, String>{
  for (final MapEntry<String, Object?> e in _object(json, key).entries)
    e.key: switch (e.value) {
      final String s => s,
      final Object? v => _bad('$key.${e.key}', 'a string', v),
    },
};

List<T> _list<T>(Map<String, Object?> json, String key, T Function(Object? item) item) => switch (json[key]) {
  final List<Object?> l => <T>[for (final Object? e in l) item(e)],
  final Object? v => _bad(key, 'an array', v),
};

Uri _uri(Map<String, Object?> json, String key) => Uri.parse(_string(json, key));

ArtifactBinding _binding(Map<String, Object?> json, String key) {
  final Map<String, Object?> b = _object(json, key);
  return ArtifactBinding(sha256: _string(b, 'sha256'), kind: _string(b, 'kind'), version: _string(b, 'version'));
}

BrowserCookie _cookie(Map<String, Object?> json) {
  _string(json, 'name');
  _string(json, 'value');
  return BrowserCookie.fromJson(json);
}

String _asString(Object? v) => v is String ? v : _bad('item', 'a string', v);

int _asInt(Object? v) => v is int ? v : _bad('item', 'an integer', v);

Map<String, Object?> _asObject(Object? v) =>
    v is Map<Object?, Object?> ? v.cast<String, Object?>() : _bad('item', 'an object', v);
