import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime/src/contracts/identity.dart';
import 'package:source_runtime/src/contracts/source.dart';

/// The bytes did not match their expected or recorded digest.
final class ArtifactIntegrityException implements Exception {
  const ArtifactIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'ArtifactIntegrityException: $message';
}

/// Producer and host profile that is part of a cache identity (KTD5): the
/// same input digest prepared by a different converter or for a different
/// host compatibility version is a different cache entry.
@immutable
final class ArtifactProfile {
  const ArtifactProfile({required this.producer, required this.converterVersion, required this.hostCompatibility});

  /// Ecosystem/preparation producer, for example `tachi-jar` or `aidoku-aix`.
  final String producer;
  final String converterVersion;
  final String hostCompatibility;

  /// Filesystem-safe key for this profile.
  String get key => sha256.convert('$producer\u0000$converterVersion\u0000$hostCompatibility'.codeUnits).toString();
}

/// Ecosystem-specific admission (signature, trust, API compatibility). Runs
/// on every admission, including cache hits, and throws to reject.
typedef ArtifactVerifier = FutureOr<void> Function(Uint8List bytes, ArtifactBinding binding);

/// Content-addressed store of privately staged artifact bytes.
///
/// One implementation owns hashing, cache integrity, and byte leases; each
/// ecosystem supplies its own [ArtifactVerifier]. Staged bytes are re-hashed
/// on every read, so the digest checked is the artifact actually loaded.
class ArtifactCache {
  ArtifactCache(this.root);

  final Directory root;
  final Map<String, int> _leaseCounts = <String, int>{};
  final Map<String, Future<void>> _locks = <String, Future<void>>{};
  final Random _random = Random.secure();

  String _objectPath(ArtifactProfile profile, String digest) =>
      p.join(root.path, 'objects', profile.key, '$digest.bin');

  /// Admits [bytes]: checks them against [binding]'s digest, runs [verifier],
  /// stages them privately, and returns a lease. An existing entry is re-hashed
  /// and replaced if it was tampered with.
  Future<ArtifactLease> admit(
    Uint8List bytes, {
    required ArtifactBinding binding,
    required ArtifactProfile profile,
    required ArtifactVerifier verifier,
  }) async {
    final digest = sha256.convert(bytes).toString();
    if (digest != binding.sha256) {
      throw ArtifactIntegrityException('Artifact digest $digest does not match expected ${binding.sha256}');
    }
    await verifier(bytes, binding);
    final String path = _objectPath(profile, digest);
    await _withLock(path, () async {
      final file = File(path);
      if (file.existsSync() && await _digestOf(file) == digest) return;
      await _stage(bytes, file);
    });
    return _lease(path, binding);
  }

  /// Returns a lease for an already admitted entry, after re-hashing it and
  /// running [verifier] on the cached bytes. Returns `null` when absent; a
  /// tampered entry is deleted and `null` returned.
  Future<ArtifactLease?> lookup({
    required ArtifactBinding binding,
    required ArtifactProfile profile,
    required ArtifactVerifier verifier,
  }) async {
    final String path = _objectPath(profile, binding.sha256);
    Uint8List? bytes;
    await _withLock(path, () async {
      final file = File(path);
      if (!file.existsSync()) return;
      final Uint8List data = await file.readAsBytes();
      if (sha256.convert(data).toString() != binding.sha256) {
        if ((_leaseCounts[path] ?? 0) == 0) await file.delete();
        return;
      }
      bytes = data;
    });
    final found = bytes;
    if (found == null) return null;
    await verifier(found, binding);
    return _lease(path, binding);
  }

  /// Creates a new private directory under the cache root for a worker to
  /// write prepared bytes into (`artifact.prepare`). The caller deletes it
  /// after admitting the result.
  Future<Directory> createScratchDirectory() async {
    final scratch = Directory(p.join(root.path, 'prepare'));
    await scratch.create(recursive: true);
    return scratch.createTemp('p');
  }

  /// Number of live leases on the entry for [binding] under [profile].
  int leaseCount(ArtifactBinding binding, ArtifactProfile profile) =>
      _leaseCounts[_objectPath(profile, binding.sha256)] ?? 0;

  /// Deletes the entry unless it is leased. Returns whether it was deleted.
  Future<bool> evict(ArtifactBinding binding, ArtifactProfile profile) async {
    final String path = _objectPath(profile, binding.sha256);
    var deleted = false;
    await _withLock(path, () async {
      if ((_leaseCounts[path] ?? 0) > 0) return;
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
        deleted = true;
      }
    });
    return deleted;
  }

  ArtifactLease _lease(String path, ArtifactBinding binding) {
    _leaseCounts[path] = (_leaseCounts[path] ?? 0) + 1;
    return ArtifactLease._(this, path, binding);
  }

  void _release(String path) {
    final int count = (_leaseCounts[path] ?? 1) - 1;
    if (count <= 0) {
      _leaseCounts.remove(path);
    } else {
      _leaseCounts[path] = count;
    }
  }

  Future<void> _stage(Uint8List bytes, File target) async {
    final staging = Directory(p.join(root.path, 'staging'));
    await staging.create(recursive: true);
    await target.parent.create(recursive: true);
    final tmp = File(p.join(staging.path, '${_random.nextInt(1 << 32).toRadixString(16)}.tmp'));
    final RandomAccessFile raf = await tmp.open(mode: FileMode.writeOnly);
    try {
      await raf.writeFrom(bytes);
      await raf.flush();
    } finally {
      await raf.close();
    }
    if (await _digestOf(tmp) != sha256.convert(bytes).toString()) {
      await tmp.delete();
      throw const ArtifactIntegrityException('Staged bytes do not match the admitted bytes');
    }
    if (target.existsSync()) await target.delete();
    await tmp.rename(target.path);
  }

  Future<T> _withLock<T>(String key, Future<T> Function() body) async {
    final Future<void> previous = _locks[key] ?? Future<void>.value();
    final done = Completer<void>();
    final Future<void> mine = done.future;
    _locks[key] = mine;
    try {
      await previous;
      return await body();
    } finally {
      done.complete();
      if (identical(_locks[key], mine)) unawaited(_locks.remove(key));
    }
  }

  static Future<String> _digestOf(File file) async => (await sha256.bind(file.openRead()).first).toString();
}

/// A lease on privately staged, verified artifact bytes.
///
/// Every read re-hashes the staged file; a mismatch throws
/// [ArtifactIntegrityException] rather than loading changed bytes.
final class ArtifactLease implements VerifiedArtifact {
  ArtifactLease._(this._cache, this.path, this.binding);

  final ArtifactCache _cache;

  /// Path of the staged bytes. Use [verifiedPath] before handing it to a loader.
  final String path;

  @override
  final ArtifactBinding binding;
  bool _released = false;

  bool get isReleased => _released;

  @override
  Future<Uint8List> readVerified() async {
    _checkLive();
    final Uint8List bytes = await File(path).readAsBytes();
    final digest = sha256.convert(bytes).toString();
    if (digest != binding.sha256) {
      throw ArtifactIntegrityException('Staged artifact changed: $digest != ${binding.sha256}');
    }
    return bytes;
  }

  /// Re-hashes the staged file and returns its path for a loader that reads
  /// from disk (for example the JVM worker).
  Future<String> verifiedPath() async {
    _checkLive();
    final String digest = await ArtifactCache._digestOf(File(path));
    if (digest != binding.sha256) {
      throw ArtifactIntegrityException('Staged artifact changed: $digest != ${binding.sha256}');
    }
    return path;
  }

  /// Releases the lease. Idempotent.
  void release() {
    if (_released) return;
    _released = true;
    _cache._release(path);
  }

  void _checkLive() {
    if (_released) throw StateError('ArtifactLease used after release');
  }
}
