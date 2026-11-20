/// Typed request and response payloads of worker protocol v1 (KTD4).
///
/// These classes are the source of truth for every `payload` (request) and
/// `ok` (response) object; `doc/protocol-v1.md` describes the same shapes for
/// worker authors in other languages. Each class has `toJson` and `fromJson`
/// so both the supervisor and a Dart worker (Paperback, U6) use the same code.
///
/// Decoding is strict: a missing required field or a field of the wrong JSON
/// type throws [FormatException]. Unknown fields are ignored, so a worker may
/// add diagnostics without breaking the supervisor.
library;

import 'package:source_runtime/src/contracts/browser_port.dart';
import 'package:source_runtime/src/contracts/identity.dart';
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
  handshake('handshake', perPackage: false),
  artifactPrepare('artifact.prepare'),
  packageLoad('package.load'),
  packageUnload('package.unload'),
  settingsUpdate('settings.update'),
  search('search'),
  details('details'),
  dispose('dispose'),
  shutdown('shutdown', perPackage: false);

  const WorkerOperation(this.wire, {this.perPackage = true});

  /// The frame's `op` value.
  final String wire;

  /// Whether the frame carries `pkg` and runs in that package's queue.
  final bool perPackage;

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
}

/// `handshake` request: the protocol versions and frame limit the supervisor
/// speaks.
final class HandshakeRequest extends WorkerRequest<HandshakeResponse> {
  const HandshakeRequest({required this.protocolVersions, required this.maxFrameBytes});

  factory HandshakeRequest.fromJson(Map<String, Object?> json) => HandshakeRequest(
    protocolVersions: _list(json, 'protocolVersions', _asInt),
    maxFrameBytes: _int(json, 'maxFrameBytes'),
  );

  final List<int> protocolVersions;
  final int maxFrameBytes;

  @override
  WorkerOperation get operation => WorkerOperation.handshake;

  @override
  HandshakeResponse decodeResponse(Map<String, Object?> ok) => HandshakeResponse.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'protocolVersions': protocolVersions,
    'maxFrameBytes': maxFrameBytes,
  };
}

/// `handshake` reply: the version the worker chose and what it can do.
final class HandshakeResponse implements ProtocolPayload {
  const HandshakeResponse({
    required this.protocolVersion,
    required this.worker,
    required this.capabilities,
    this.workerVersion,
    this.pid,
  });

  factory HandshakeResponse.fromJson(Map<String, Object?> json) => HandshakeResponse(
    protocolVersion: _int(json, 'protocolVersion'),
    worker: _string(json, 'worker'),
    workerVersion: _optString(json, 'workerVersion'),
    pid: _optInt(json, 'pid'),
    capabilities: WorkerCapabilities.fromJson(_object(json, 'capabilities')),
  );

  /// One of [HandshakeRequest.protocolVersions].
  final int protocolVersion;

  /// Worker implementation name, for example `tachi-jvm` or `paperback`.
  final String worker;
  final String? workerVersion;

  /// The worker's own PID, for diagnostics.
  final int? pid;
  final WorkerCapabilities capabilities;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'protocolVersion': protocolVersion,
    'worker': worker,
    'workerVersion': workerVersion,
    'pid': pid,
    'capabilities': capabilities.toJson(),
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
/// and writes only to [outputPath], which the supervisor chose inside its
/// private staging area.
final class ArtifactPrepareRequest extends WorkerRequest<ArtifactPrepareResponse> {
  const ArtifactPrepareRequest({required this.artifact, required this.inputPath, required this.outputPath});

  factory ArtifactPrepareRequest.fromJson(Map<String, Object?> json) => ArtifactPrepareRequest(
    artifact: _binding(json, 'artifact'),
    inputPath: _string(json, 'inputPath'),
    outputPath: _string(json, 'outputPath'),
  );

  final ArtifactBinding artifact;
  final String inputPath;
  final String outputPath;

  @override
  WorkerOperation get operation => WorkerOperation.artifactPrepare;

  @override
  ArtifactPrepareResponse decodeResponse(Map<String, Object?> ok) => ArtifactPrepareResponse.fromJson(ok);

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'artifact': artifact.toJson(),
    'inputPath': inputPath,
    'outputPath': outputPath,
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

/// Settings as sent to a worker: typed non-secret values, secret values, and
/// the durable revision. Secrets cross the pipe to the worker only; the
/// supervisor registers them with its redactor first (KTD9).
final class SettingsPayload implements ProtocolPayload {
  SettingsPayload({
    required Map<String, Object> values,
    required Map<String, String> secrets,
    required this.revision,
  }) : values = Map<String, Object>.unmodifiable(values),
       secrets = Map<String, String>.unmodifiable(secrets);

  factory SettingsPayload.fromSnapshot(SettingsSnapshot snapshot) =>
      SettingsPayload(values: snapshot.values, secrets: snapshot.secrets, revision: snapshot.revision);

  factory SettingsPayload.fromJson(Map<String, Object?> json) => SettingsPayload(
    values: SettingsSnapshot.valuesFromJson(_object(json, 'values')),
    secrets: _stringMap(json, 'secrets'),
    revision: _string(json, 'revision'),
  );

  /// Each a `String`, `bool` or `int`.
  final Map<String, Object> values;
  final Map<String, String> secrets;
  final String revision;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'values': values, 'secrets': secrets, 'revision': revision};
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
  close('host.browser.close');

  const HostBrowserOperation(this.wire);

  final String wire;

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
  const HostBrowserOpened({required this.session});

  factory HostBrowserOpened.fromJson(Map<String, Object?> json) => HostBrowserOpened(session: _string(json, 'session'));

  final String session;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'session': session};
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
  const HostBrowserEvaluated({required this.result});

  factory HostBrowserEvaluated.fromJson(Map<String, Object?> json) =>
      HostBrowserEvaluated(result: _string(json, 'result'));

  /// The script's value as JSON text (`"ok"`, `42`, `null`).
  final String result;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'result': result};
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

bool _bool(Map<String, Object?> json, String key) => switch (json[key]) {
  final bool b => b,
  final Object? v => _bad(key, 'a boolean', v),
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
