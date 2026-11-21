import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/src/catalog.dart';

/// Which artifact kind to load (KTD5): the repository JAR when the index
/// publishes one, the APK otherwise. A per-package override wins over a
/// per-repository one, which wins over [all]; a forced kind the index does
/// not publish is a typed failure, never a silent switch to the other kind.
@immutable
final class TachiArtifactPolicy {
  const TachiArtifactPolicy({
    this.all,
    this.repositories = const <Uri, TachiArtifactKind>{},
    this.packages = const <String, TachiArtifactKind>{},
  });

  /// Forced kind for every repository.
  final TachiArtifactKind? all;

  /// Forced kind by canonical repository URL ([tachiRepositoryBase]).
  final Map<Uri, TachiArtifactKind> repositories;

  /// Forced kind by repository package identifier.
  final Map<String, TachiArtifactKind> packages;

  /// The kind forced for [listing], or `null` when none is.
  TachiArtifactKind? forcedFor(TachiPackageListing listing) =>
      packages[listing.packageId] ?? repositories[listing.repository.baseUrl] ?? all;

  /// The artifact to load for [listing].
  SourceOutcome<TachiArtifactChoice> select(TachiPackageListing listing) {
    final TachiArtifactKind? forced = forcedFor(listing);
    final TachiArtifactKind kind = forced ?? (listing.jarUrl != null ? TachiArtifactKind.jar : TachiArtifactKind.apk);
    final Uri? url = listing.urlFor(kind);
    if (url == null) {
      return SourceFailed<TachiArtifactChoice>(
        ArtifactIncompatibleFailure(
          '${listing.packageId}: the ${kind.name.toUpperCase()} artifact is forced but '
          '${listing.repository.baseUrl} does not publish one',
        ),
      );
    }
    return SourceSuccess<TachiArtifactChoice>(TachiArtifactChoice(kind: kind, url: url));
  }
}

/// The artifact chosen for a package.
@immutable
final class TachiArtifactChoice {
  const TachiArtifactChoice({required this.kind, required this.url});

  final TachiArtifactKind kind;
  final Uri url;
}

/// Downloads published artifacts and admits them, unprepared, to the
/// content-addressed [ArtifactCache].
///
/// Raw downloads live under [downloadProfile], separate from prepared
/// artifacts, so an unverified download can never be mistaken for a loadable
/// one. Admission re-hashes the bytes; only `artifact.prepare` in the worker
/// verifies signatures, and only its re-hashed output is ever loaded.
final class TachiArtifactStore {
  TachiArtifactStore({required this.cache, required this.fetch});

  /// Cache profile of unprepared downloads.
  static const ArtifactProfile downloadProfile = ArtifactProfile(
    producer: 'tachi-download',
    converterVersion: '1',
    hostCompatibility: 'unprepared',
  );

  final ArtifactCache cache;
  final TachiFetch fetch;

  /// Downloads [choice]; transport failures are typed.
  Future<SourceOutcome<Uint8List>> download(TachiArtifactChoice choice) async {
    try {
      return SourceSuccess<Uint8List>(await fetch(choice.url));
    } on Exception catch (e) {
      return SourceFailed<Uint8List>(SourceErrorFailure('Download of ${choice.url} failed: $e'));
    }
  }

  /// Admits downloaded [bytes] of [kind] under [downloadProfile]. The binding
  /// carries the digest of exactly these bytes, so a URL that now serves
  /// different bytes yields a different binding (and different source
  /// identities) rather than reusing earlier handles or cache entries.
  Future<SourceOutcome<ArtifactLease>> admit(
    Uint8List bytes, {
    required TachiArtifactKind kind,
    required String version,
  }) async {
    if (!_isZip(bytes)) {
      return SourceFailed<ArtifactLease>(
        ArtifactIncompatibleFailure('Downloaded ${kind.name.toUpperCase()} is not a ZIP archive'),
      );
    }
    try {
      return SourceSuccess<ArtifactLease>(
        await cache.admit(
          bytes,
          binding: ArtifactBinding(sha256: sha256.convert(bytes).toString(), kind: kind.name, version: version),
          profile: downloadProfile,
          verifier: _structural,
        ),
      );
    } on ArtifactIntegrityException catch (e) {
      return SourceFailed<ArtifactLease>(ArtifactIncompatibleFailure(e.message));
    }
  }

  /// Signatures are verified by the worker during `artifact.prepare`.
  static void _structural(Uint8List bytes, ArtifactBinding binding) {}

  static bool _isZip(Uint8List bytes) =>
      bytes.length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4b && bytes[2] == 0x03 && bytes[3] == 0x04;
}
