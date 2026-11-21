import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:source_runtime/source_contracts.dart';

/// The two Paperback host API families this host implements (KTD6, R3).
/// They are separate adapters, never interchangeable.
enum PaperbackApiFamily {
  /// `@paperback/types` 0.8.x: the `App.*` factories and
  /// `new Sources[id](cheerio)`.
  v08('paperback-0.8', 'paperback-bundle-0.8', 'source.js'),

  /// `@paperback/types` 1.0.0-alpha.x (the app's 0.9 API): `Application.*`
  /// and the `source[id]` instance.
  v09('paperback-0.9', 'paperback-bundle-0.9', 'index.js');

  const PaperbackApiFamily(this.wire, this.artifactKind, this.entryFile);

  /// Handshake / capability name, for example `paperback-0.8`.
  final String wire;

  /// [ArtifactBinding.kind] of a bundle admitted for this family. The family
  /// travels in the artifact kind because `package.load` has no family field
  /// (reported as a needed protocol addition).
  final String artifactKind;

  /// The bundle file the app installs from `<repository>/<sourceId>/`.
  /// Verified against real repositories (docs/source-runners.md): 0.8
  /// toolchain 0.8.0-alpha.47 publishes byte-identical `source.js` and
  /// `index.js`, toolchain 0.8.7 publishes only `source.js`, and 0.9
  /// repositories publish `index.js`.
  final String entryFile;

  static PaperbackApiFamily? fromWire(String? wire) {
    for (final PaperbackApiFamily f in values) {
      if (f.wire == wire) return f;
    }
    return null;
  }

  static PaperbackApiFamily? fromArtifactKind(String kind) {
    for (final PaperbackApiFamily f in values) {
      if (f.artifactKind == kind) return f;
    }
    return null;
  }

  /// The family a repository catalog was built for, from
  /// `versioning.json` `builtWith.types`: 0.8.x types are the 0.8 API,
  /// 1.0.0-alpha.x types are the app's 0.9 API. Anything else is unsupported.
  static PaperbackApiFamily? fromTypesVersion(String? types) {
    if (types == null) return null;
    if (RegExp(r'^0\.8\.').hasMatch(types)) return v08;
    if (RegExp(r'^1\.0\.0-alpha\.').hasMatch(types)) return v09;
    return null;
  }
}

/// Lowercase hex SHA-256 of [bytes].
String bundleDigest(List<int> bytes) => sha256.convert(bytes).toString();

/// The family a bundle's own shape declares, from its top-level structure:
/// 0.9 bundles (rolldown) start with `var source=`; 0.8 bundles (browserify
/// or esbuild) assign a `Sources` object on the global. `null` when neither
/// or both match.
PaperbackApiFamily? declaredFamilyOf(Uint8List bytes) {
  final String text = utf8.decode(bytes, allowMalformed: true);
  final String head = text.length > 512 ? text.substring(0, 512) : text;
  final bool v09 = RegExp(r'^\s*(?:"use strict";\s*)?var\s+source\s*=').hasMatch(head);
  final bool v08 = RegExp(r'(?:\bg|\bthis)\.Sources\s*=').hasMatch(text);
  if (v09 == v08) return null;
  return v09 ? PaperbackApiFamily.v09 : PaperbackApiFamily.v08;
}

/// Why a bundle was refused before any JavaScript ran.
final class BundleAdmissionException implements Exception {
  const BundleAdmissionException(this.failure);

  final SourceFailure failure;

  @override
  String toString() => 'BundleAdmissionException($failure)';
}

/// Checks [bytes] against the trust decision recorded in [binding] before
/// evaluation (KTD6): the digest must match, the artifact kind must name a
/// supported family, and the bundle's own shape must declare that family.
/// Runs on every load, including cache hits and restarts.
PaperbackApiFamily admitBundle(Uint8List bytes, ArtifactBinding binding) {
  final String digest = bundleDigest(bytes);
  if (digest != binding.sha256) {
    throw BundleAdmissionException(
      ArtifactIncompatibleFailure(
        'Bundle bytes changed: SHA-256 $digest does not match the admitted ${binding.sha256}',
      ),
    );
  }
  final PaperbackApiFamily? family = PaperbackApiFamily.fromArtifactKind(binding.kind);
  if (family == null) {
    throw BundleAdmissionException(UnsupportedApiFailure('Unsupported Paperback artifact kind "${binding.kind}"'));
  }
  final PaperbackApiFamily? declared = declaredFamilyOf(bytes);
  if (declared != family) {
    throw BundleAdmissionException(
      ArtifactIncompatibleFailure(
        'Bundle admitted as ${family.wire} but its structure declares ${declared?.wire ?? 'no known Paperback API'}',
      ),
    );
  }
  return family;
}

/// The trust fingerprint a Paperback bundle is admitted under (KTD6).
///
/// Paperback repositories are unsigned, so the decision binds the exact
/// bytes and their API family: `paperback-0.9:sha256:<hex>`. The trust key
/// is per bundle (`<repository>#<sourceId>`), so two bundles from one
/// repository never overwrite each other's decision.
String bundleTrustFingerprint(PaperbackApiFamily family, String sha256Hex) => '${family.wire}:sha256:$sha256Hex';

/// The repository-and-source key a bundle's trust decision is stored under.
Uri bundleTrustKey(Uri repository, String sourceId) => repository.replace(fragment: sourceId);
