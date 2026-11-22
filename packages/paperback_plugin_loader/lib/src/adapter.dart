import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:paperback_plugin_loader/src/admission.dart';
import 'package:paperback_plugin_loader/src/host/browser.dart';
import 'package:paperback_plugin_loader/src/host/network.dart';
import 'package:paperback_plugin_loader/src/paperback_runtime.dart';
import 'package:paperback_plugin_loader/src/runtime/quickjs_runtime.dart';
import 'package:paperback_plugin_loader/src/runtime/worker.dart';
import 'package:source_runtime/source_runtime.dart';

/// The Paperback 0.8 and 0.9 host adapters behind the worker's protocol
/// (KTD6): `package.load` admits and evaluates a bundle, `search` and
/// `details` run its original methods, `settings.update` re-seeds state.
final class PaperbackApiAdapter implements PaperbackPackageAdapter {
  PaperbackApiAdapter({required this.http, this.browser, this.log});

  /// Shared by every package: live, recording or replaying (worker flags).
  final PaperbackHttp http;

  /// Browser channel for `executeInWebView`, or `null` when this host has
  /// none (the call then fails as `capability-unavailable`).
  final PaperbackBrowserChannel? browser;
  final void Function(String line)? log;

  final Expando<_Package> _packages = Expando<_Package>('paperback package');

  @override
  Set<String> get apiFamilies => <String>{for (final PaperbackApiFamily f in PaperbackApiFamily.values) f.wire};

  @override
  Future<PackageLoadResponse> load(
    SourceJsRuntime runtime,
    PackageLoadRequest request,
    CancellationToken cancel,
  ) async {
    // Re-read and re-hash the staged bytes here, immediately before
    // evaluation: the digest checked is the artifact executed (KTD6).
    final Uint8List bytes = await File(request.path).readAsBytes();
    final host = PaperbackSourceHost(runtime: runtime, http: http, browser: browser, log: log);
    final List<PaperbackLoadedSource> sources = await host.load(
      bytes,
      request.artifact,
      request.settings,
      apiFamily: request.apiFamily,
      cancel: cancel,
    );
    final bool usesBrowser = _mentions(bytes, 'executeInWebView');
    // A 0.8 Cloudflare bypass needs the browser only when a challenge appears.
    final bool bypasses = _mentions(bytes, 'getCloudflareBypassRequestAsync');
    _packages[runtime] = _Package(host, request.settings.revision);
    return PackageLoadResponse(
      sources: <LoadedSource>[
        for (final PaperbackLoadedSource s in sources)
          LoadedSource(
            sourceId: s.sourceId,
            name: s.name,
            language: s.language,
            capabilities: SourceCapabilities(
              operations: <SourceOperation>{
                SourceOperation.search,
                SourceOperation.mangaDetails,
                SourceOperation.chapterList,
                SourceOperation.settings,
                if ((usesBrowser || bypasses) && browser != null) SourceOperation.browser,
              },
              apiFamilies: <String>{host.family.wire},
              requiresBrowser: usesBrowser,
            ),
          ),
      ],
    );
  }

  @override
  Future<ProtocolPayload> handle(
    SourceJsRuntime runtime,
    WorkerRequest<ProtocolPayload> request,
    CancellationToken cancel,
  ) async {
    final _Package package = _packages[runtime] ?? (throw StateError('Package was not loaded by this adapter'));
    final PaperbackSourceHost host = package.host;
    switch (request) {
      case SettingsUpdateRequest(:final SettingsPayload settings):
        await host.updateSettings(settings, cancel: cancel);
        package.revision = settings.revision;
        return const EmptyPayload();
      case WorkerSearchRequest(
        :final SourceIdentity source,
        :final String settingsRevision,
        request: final SearchRequest search,
      ):
        _check(package, source.sourceId, settingsRevision);
        final PaperbackSearchPage page = await host.withCancel(
          cancel,
          () => host.search(source.sourceId, search.query, search.cursor, cancel: cancel),
        );
        return WorkerSearchResponse(
          hits: <WorkerSearchHit>[
            for (final Map<String, Object?> item in page.items)
              WorkerSearchHit(
                hit: SearchHit(
                  ref: NativeMangaRef(
                    source: source,
                    mangaId: item['mangaId']! as String,
                    settingsRevision: settingsRevision,
                    context: <String, Object?>{
                      'apiFamily': host.family.wire,
                      if (item['subtitle'] != null) 'subtitle': item['subtitle'],
                    },
                  ),
                  title: item['title'] as String? ?? item['mangaId']! as String,
                  coverUrl: item['imageUrl'] as String?,
                ),
              ),
          ],
          nextCursor: page.items.isEmpty ? null : page.nextCursor,
        );
      case WorkerDetailsRequest(
        :final SourceIdentity source,
        :final String settingsRevision,
        :final NativeMangaRef ref,
      ):
        _check(package, source.sourceId, settingsRevision);
        if (ref.source != source) {
          throw PaperbackRuntimeException(
            StaleReferenceFailure('Reference is bound to ${ref.source}, request is for $source'),
            reason: PaperbackFailureReason.sourceError,
          );
        }
        final Map<String, Object?> details = await host.withCancel(
          cancel,
          () => host.details(source.sourceId, ref.mangaId, cancel: cancel),
        );
        return WorkerDetailsResponse(metadata: metadataOf(details), chapters: chaptersOf(details, host.family));
      case DisposeRequest():
        // Paperback sessions issue no live handles; references are durable.
        return const EmptyPayload();
      default:
        throw PaperbackRuntimeException(
          UnsupportedApiFailure('The Paperback worker does not serve ${request.runtimeType}'),
          reason: PaperbackFailureReason.sourceError,
        );
    }
  }

  void _check(_Package package, String sourceId, String settingsRevision) {
    if (!package.host.sources.containsKey(sourceId)) {
      throw PaperbackRuntimeException(
        StaleReferenceFailure('This package does not host source "$sourceId"'),
        reason: PaperbackFailureReason.sourceError,
      );
    }
    if (settingsRevision != package.revision) {
      throw const PaperbackRuntimeException(
        StaleReferenceFailure('The request was made under a different settings revision'),
        reason: PaperbackFailureReason.sourceError,
      );
    }
  }

  static bool _mentions(Uint8List bytes, String needle) {
    final List<int> n = needle.codeUnits;
    outer:
    for (var i = 0; i + n.length <= bytes.length; i++) {
      for (var j = 0; j < n.length; j++) {
        if (bytes[i + j] != n[j]) continue outer;
      }
      return true;
    }
    return false;
  }
}

final class _Package {
  _Package(this.host, this.revision);

  final PaperbackSourceHost host;
  String revision;
}

/// Maps adapter details output to [MangaMetadata].
MangaMetadata metadataOf(Map<String, Object?> details) {
  final m = details['metadata']! as Map<String, Object?>;
  // Bundle output is free-form: the status is normalized and non-string list
  // items are dropped before the contract's wire shape is read.
  return MangaMetadata.fromJson(<String, Object?>{
    ...m,
    'status': publishingStatusOf(m['status'] as String?).name,
    for (final String key in const <String>['altTitles', 'authors', 'artists', 'tags']) key: _strings(m[key]),
  });
}

/// Maps adapter details output to [NativeChapter]s, keeping the source's
/// chapter IDs and order exactly.
List<NativeChapter> chaptersOf(Map<String, Object?> details, PaperbackApiFamily family) => <NativeChapter>[
  for (final Object? c in details['chapters'] as List<Object?>? ?? const <Object?>[])
    if (c is Map<String, Object?> && c['chapterId'] is String)
      NativeChapter(
        chapterId: c['chapterId']! as String,
        sourceOrder: c['sourceOrder']! as int,
        context: <String, Object?>{
          'apiFamily': family.wire,
          for (final MapEntry<String, Object?> e
              in (c['context'] as Map<String, Object?>? ?? const <String, Object?>{}).entries)
            if (e.value != null) e.key: e.value,
        },
        title: c['title'] as String?,
        chapterNumber: (c['chapterNumber'] as num?)?.toDouble(),
        volumeNumber: (c['volumeNumber'] as num?)?.toDouble(),
        scanlators: _strings(c['scanlators']),
        language: c['language'] as String?,
        dateUploaded: c['dateUploaded'] is String ? DateTime.tryParse(c['dateUploaded']! as String)?.toUtc() : null,
      ),
];

/// Paperback status strings are free text; map the common spellings.
PublishingStatus publishingStatusOf(String? status) {
  final String s = (status ?? '').toLowerCase();
  if (s.contains('ongoing') || s.contains('releasing') || s.contains('publishing')) return PublishingStatus.ongoing;
  if (s.contains('complete') || s.contains('finished') || s.contains('ended')) return PublishingStatus.completed;
  if (s.contains('hiatus')) return PublishingStatus.hiatus;
  if (s.contains('cancel') || s.contains('dropped') || s.contains('abandon')) return PublishingStatus.cancelled;
  return PublishingStatus.unknown;
}

List<String> _strings(Object? v) => v is List<Object?>
    ? <String>[
        for (final Object? s in v)
          if (s is String) s,
      ]
    : const <String>[];
