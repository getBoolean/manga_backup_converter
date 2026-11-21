import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:source_runtime/source_contracts.dart';

/// Artifact bytes held in memory, verified against the digest computed when
/// they were admitted.
final class BytesArtifact implements VerifiedArtifact {
  BytesArtifact(Uint8List bytes, {required String kind, required String version})
    : _bytes = Uint8List.fromList(bytes),
      binding = ArtifactBinding(sha256: sha256.convert(bytes).toString(), kind: kind, version: version);

  final Uint8List _bytes;

  @override
  final ArtifactBinding binding;

  @override
  Future<Uint8List> readVerified() async {
    if (sha256.convert(_bytes).toString() != binding.sha256) {
      throw StateError('Artifact bytes no longer match ${binding.sha256}');
    }
    return Uint8List.fromList(_bytes);
  }
}
