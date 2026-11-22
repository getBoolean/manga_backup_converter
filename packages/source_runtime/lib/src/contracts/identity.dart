import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// A 64-bit signed integer identifier carried as a decimal string (KTD3).
///
/// Tachi source IDs exceed JavaScript's exact integer range (2^53), so they
/// never cross JSON as numbers. [Int64Id.fromJson] rejects JSON numbers.
@immutable
final class Int64Id {
  const Int64Id._(this.decimal);

  /// Parses a canonical decimal string in the signed 64-bit range.
  factory Int64Id.parse(String decimal) {
    if (!_pattern.hasMatch(decimal) || decimal == '-0') {
      throw FormatException('Not a canonical decimal int64: "$decimal"');
    }
    final BigInt value = BigInt.parse(decimal);
    if (value < _min || value > _max) throw FormatException('Out of int64 range: $decimal');
    return Int64Id._(decimal);
  }

  /// Decodes a JSON value, which must be a string.
  factory Int64Id.fromJson(Object? json) {
    if (json is! String) {
      throw FormatException('int64 IDs must be decimal strings, got ${json.runtimeType}');
    }
    return Int64Id.parse(json);
  }

  static final RegExp _pattern = RegExp(r'^-?(0|[1-9][0-9]*)$');
  static final BigInt _min = -(BigInt.one << 63);
  static final BigInt _max = (BigInt.one << 63) - BigInt.one;

  final String decimal;

  String toJson() => decimal;

  @override
  bool operator ==(Object other) => other is Int64Id && other.decimal == decimal;

  @override
  int get hashCode => decimal.hashCode;

  @override
  String toString() => decimal;
}

/// The verified artifact a source was loaded from.
@immutable
final class ArtifactBinding {
  const ArtifactBinding({required this.sha256, required this.kind, required this.version});

  factory ArtifactBinding.fromJson(Map<String, Object?> json) => ArtifactBinding(
    sha256: json['sha256']! as String,
    kind: json['kind']! as String,
    version: json['version']! as String,
  );

  /// Lowercase hex SHA-256 of the admitted artifact bytes.
  final String sha256;

  /// Artifact kind, for example `aix`, `jar`, `apk`, `paperback-bundle`.
  final String kind;

  /// Artifact version as published by its repository.
  final String version;

  Map<String, Object?> toJson() => <String, Object?>{'sha256': sha256, 'kind': kind, 'version': version};

  @override
  bool operator ==(Object other) =>
      other is ArtifactBinding && other.sha256 == sha256 && other.kind == kind && other.version == version;

  @override
  int get hashCode => Object.hash(sha256, kind, version);
}

/// Identity of a running source: ecosystem, repository package, the source
/// ID enumerated by the running package, and the artifact it came from.
///
/// [sourceId] is always a string. Tachi uses the decimal form of its int64 ID
/// (see [Int64Id]); Aidoku and Paperback use their own string IDs.
@immutable
final class SourceIdentity {
  const SourceIdentity({
    required this.ecosystem,
    required this.packageId,
    required this.sourceId,
    required this.artifact,
  });

  factory SourceIdentity.fromJson(Map<String, Object?> json) {
    final Object? sourceId = json['sourceId'];
    if (sourceId is! String) {
      throw FormatException('sourceId must be a string, got ${sourceId.runtimeType}');
    }
    return SourceIdentity(
      ecosystem: json['ecosystem']! as String,
      packageId: json['packageId']! as String,
      sourceId: sourceId,
      artifact: ArtifactBinding.fromJson(json['artifact']! as Map<String, Object?>),
    );
  }

  final String ecosystem;
  final String packageId;
  final String sourceId;
  final ArtifactBinding artifact;

  Map<String, Object?> toJson() => <String, Object?>{
    'ecosystem': ecosystem,
    'packageId': packageId,
    'sourceId': sourceId,
    'artifact': artifact.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is SourceIdentity &&
      other.ecosystem == ecosystem &&
      other.packageId == packageId &&
      other.sourceId == sourceId &&
      other.artifact == artifact;

  @override
  int get hashCode => Object.hash(ecosystem, packageId, sourceId, artifact);

  @override
  String toString() {
    final String digest = artifact.sha256;
    return '$ecosystem:$packageId/$sourceId@${digest.length > 12 ? digest.substring(0, 12) : digest}';
  }
}

/// Effective per-source settings, shared by [SettingsSnapshot] and the wire
/// `SettingsPayload` so supervisors and workers resolve a source's settings
/// with one rule: package-wide entries overlaid with that source's scope.
/// Setting keys that name a credential: `pass`, `token`, `secret`, `cookie`
/// or `auth` anywhere in the key, case-insensitively (`password`,
/// `apiToken`, `sessionCookie`, `authKey`). `author` is not one: author
/// display toggles are common non-secret settings.
final RegExp secretLikeSettingKey = RegExp('pass|token|secret|cookie|auth(?!or)', caseSensitive: false);

/// Whether a setting [key] names a credential (see [secretLikeSettingKey]).
///
/// A value placed under `values` with such a key is treated as a secret
/// everywhere except delivery (L4): it keeps its type and still reaches the
/// source as a value, so a source reading it from its preferences is
/// unaffected, but it is left out of the durable [SettingsSnapshot.revision]
/// and of [SettingsSnapshot.toJson] (only its name is kept, with the secret
/// keys), and its string forms are registered for redaction through
/// [ScopedSettingsView.allSecretValues]. Booleans and integers are not
/// registered for redaction: redacting `true` or `1` would mangle every log
/// line, and neither is a credential on its own.
bool isSecretLikeSettingKey(String key) => secretLikeSettingKey.hasMatch(key);

mixin ScopedSettingsView {
  /// Package-wide non-secret values.
  Map<String, Object> get values;

  /// Package-wide secret values; session memory only (KTD9).
  Map<String, String> get secrets;

  /// Per-source overrides keyed by source ID.
  Map<String, SourceScopedSettings> get sources;

  /// The effective non-secret values for [sourceId]: package-wide values
  /// overridden by that source's scope.
  Map<String, Object> valuesFor(String sourceId) => <String, Object>{...values, ...?sources[sourceId]?.values};

  /// The effective secrets for [sourceId]: package-wide secrets overridden
  /// by that source's scope.
  Map<String, String> secretsFor(String sourceId) => <String, String>{...secrets, ...?sources[sourceId]?.secrets};

  /// Every secret value, package-wide and source-scoped, for redaction:
  /// the secrets, plus the string values (and string-set members) of
  /// secret-like value keys ([isSecretLikeSettingKey]).
  Iterable<String> get allSecretValues sync* {
    yield* secrets.values;
    yield* _secretLikeStrings(values);
    for (final SourceScopedSettings scope in sources.values) {
      yield* scope.secrets.values;
      yield* _secretLikeStrings(scope.values);
    }
  }

  static Iterable<String> _secretLikeStrings(Map<String, Object> values) sync* {
    for (final MapEntry<String, Object> e in values.entries) {
      if (!isSecretLikeSettingKey(e.key)) continue;
      switch (e.value) {
        case final String s:
          yield s;
        case final List<String> l:
          yield* l;
      }
    }
  }

  /// Whether any value is a string set or any source has scoped settings.
  /// Both need worker protocol 1.1; a 1.0 worker would reject them.
  bool get needsProtocol11 => sources.isNotEmpty || values.values.any((Object v) => v is List<String>);
}

/// Settings that apply to one source of a multi-source package (a Tachi
/// factory hosts many sources in one package).
///
/// Package-wide values in [SettingsSnapshot.values] apply to every source; a
/// source's scoped entry overrides the package-wide entry with the same key.
/// Values follow the same typing rules as [SettingsSnapshot.values].
@immutable
final class SourceScopedSettings {
  SourceScopedSettings({
    Map<String, Object> values = const <String, Object>{},
    Map<String, String> secrets = const <String, String>{},
  }) : values = SettingsSnapshot._normalizeValues(values),
       secrets = Map<String, String>.unmodifiable(secrets);

  /// Non-secret values: each a [String], [bool], [int] or string set.
  final Map<String, Object> values;

  /// Secret values; session memory only (KTD9).
  final Map<String, String> secrets;

  bool get isEmpty => values.isEmpty && secrets.isEmpty;
}

/// Settings chosen for a source session.
///
/// Non-secret values are typed: each is a [String], [bool], [int], or a
/// string set (`List<String>`), and crosses JSON as that JSON type (an `int`
/// must stay within JavaScript's exact integer range, ±(2^53 − 1)). A string
/// set backs APIs like `SharedPreferences.getStringSet`: order and
/// duplicates carry no meaning, so it is stored sorted and deduplicated and
/// equal sets always produce the same [revision]. Secret values (passwords,
/// tokens, cookies) are strings and session-only (KTD9): they never appear
/// in [toJson] or in [revision].
///
/// [values] and [secrets] apply to every source of the package. [sources]
/// overrides them for individual sources, keyed by source ID (the string
/// form from `package.load`), so one source of a multi-source package can be
/// configured without a key-naming convention.
@immutable
final class SettingsSnapshot with ScopedSettingsView {
  SettingsSnapshot({
    Map<String, Object> values = const <String, Object>{},
    Map<String, String> secrets = const <String, String>{},
    Map<String, SourceScopedSettings> sources = const <String, SourceScopedSettings>{},
    Set<String>? revisionAllowlist,
  }) : values = _normalizeValues(values),
       secrets = Map<String, String>.unmodifiable(secrets),
       sources = Map<String, SourceScopedSettings>.unmodifiable(<String, SourceScopedSettings>{
         for (final MapEntry<String, SourceScopedSettings> e in sources.entries)
           if (!e.value.isEmpty) e.key: e.value,
       }),
       revisionAllowlist = revisionAllowlist == null ? null : Set<String>.unmodifiable(revisionAllowlist);

  /// Decodes the typed values of a wire `settings` object. A JSON array must
  /// hold only strings and becomes a string set.
  static Map<String, Object> valuesFromJson(Map<String, Object?> json) => _normalizeValues(<String, Object>{
    for (final MapEntry<String, Object?> e in json.entries)
      e.key: switch (e.value) {
        null => throw FormatException('Setting "${e.key}" is null'),
        final Object v => v,
      },
  });

  static const int _maxSafeInt = 9007199254740991;

  static Map<String, Object> _normalizeValues(Map<String, Object> values) =>
      Map<String, Object>.unmodifiable(<String, Object>{
        for (final MapEntry<String, Object> e in values.entries) e.key: _normalizeValue(e.key, e.value),
      });

  static Object _normalizeValue(String key, Object v) {
    if (v is int && (v > _maxSafeInt || v < -_maxSafeInt)) {
      throw FormatException('Setting "$key" is outside the exact JSON integer range: $v');
    }
    if (v is List<Object?>) {
      if (v.any((Object? item) => item is! String)) {
        throw FormatException('Setting "$key" may only hold strings in a list');
      }
      return List<String>.unmodifiable(v.cast<String>().toSet().toList()..sort());
    }
    if (v is! String && v is! bool && v is! int) {
      throw FormatException('Setting "$key" must be a String, bool, int or List<String>, got ${v.runtimeType}');
    }
    return v;
  }

  /// Package-wide non-secret values: each a [String], [bool], [int] or a
  /// sorted, deduplicated `List<String>`.
  @override
  final Map<String, Object> values;

  /// Package-wide secret values; session memory only.
  @override
  final Map<String, String> secrets;

  /// Per-source overrides keyed by source ID. Empty scopes are dropped.
  @override
  final Map<String, SourceScopedSettings> sources;

  /// Non-secret keys that take part in [revision]; `null` means all of them.
  /// It applies to package-wide and source-scoped keys alike.
  final Set<String>? revisionAllowlist;

  /// Durable, secret-free revision: a digest over the allowlisted non-secret
  /// values plus the names (never the values) of the supplied secrets and of
  /// secret-like value keys ([isSecretLikeSettingKey]), for the package and
  /// every source scope. Re-entering secrets for the same keys keeps the
  /// revision. A value under a secret-like key never enters the digest: an
  /// unsalted hash of a low-entropy password could be brute-forced from a
  /// journal or report that records the revision.
  String get revision {
    // Each value keeps its JSON type, so `true` and `'true'` differ while a
    // string-only snapshot keeps the digest it had before values were typed.
    // `sources` is added only when present, so a snapshot without scopes
    // keeps the digest it had before scopes existed.
    final Map<String, Object?> canonical = _canonicalScope(values, secrets);
    if (sources.isNotEmpty) {
      final List<String> ids = sources.keys.toList()..sort();
      canonical['sources'] = <List<Object>>[
        for (final id in ids) <Object>[id, _canonicalScope(sources[id]!.values, sources[id]!.secrets)],
      ];
    }
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  Map<String, Object?> _canonicalScope(Map<String, Object> values, Map<String, String> secrets) {
    final List<String> keys =
        values.keys.where((String k) => !isSecretLikeSettingKey(k) && (revisionAllowlist?.contains(k) ?? true)).toList()
          ..sort();
    final List<String> secretKeys = _secretKeyNames(values, secrets);
    return <String, Object?>{
      'values': <List<Object>>[
        for (final k in keys) <Object>[k, values[k]!],
      ],
      'secretKeys': secretKeys,
    };
  }

  /// Names of [secrets] and of secret-like keys in [values], sorted.
  static List<String> _secretKeyNames(Map<String, Object> values, Map<String, String> secrets) =>
      <String>{...secrets.keys, ...values.keys.where(isSecretLikeSettingKey)}.toList()..sort();

  static Map<String, Object> _publicValues(Map<String, Object> values) => <String, Object>{
    for (final MapEntry<String, Object> e in values.entries)
      if (!isSecretLikeSettingKey(e.key)) e.key: e.value,
  };

  /// Secret-free serialised form: values under secret-like keys are listed
  /// by name with the secret keys.
  Map<String, Object?> toJson() => <String, Object?>{
    'values': _publicValues(values),
    'secretKeys': _secretKeyNames(values, secrets),
    if (sources.isNotEmpty)
      'sources': <String, Object?>{
        for (final MapEntry<String, SourceScopedSettings> e in sources.entries)
          e.key: <String, Object?>{
            'values': _publicValues(e.value.values),
            'secretKeys': _secretKeyNames(e.value.values, e.value.secrets),
          },
      },
    'revision': revision,
  };
}

/// The signing identities a repository's artifacts must carry (KTD5).
///
/// Built from the local trust store: the fingerprint the user approved when
/// the repository was added, or one pinned by a qualification manifest. A
/// fingerprint read beside the artifacts proves consistency, not provenance,
/// so it never belongs here unless it matches the stored one.
@immutable
final class ArtifactTrustAnchor {
  /// [signerFingerprints] are certificate SHA-256 fingerprints, as 64 hex
  /// digits; colons and upper case are accepted and normalised.
  ArtifactTrustAnchor({required Iterable<String> signerFingerprints})
    : signerFingerprints = Set<String>.unmodifiable(signerFingerprints.map(normalizeFingerprint));

  /// Lowercase, colon-free certificate SHA-256 fingerprints.
  final Set<String> signerFingerprints;

  static final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');

  /// Canonical form of a certificate SHA-256 fingerprint: 64 lowercase hex
  /// digits. Throws [FormatException] for anything else.
  static String normalizeFingerprint(String fingerprint) {
    final String canonical = fingerprint.replaceAll(':', '').toLowerCase();
    if (!_hex64.hasMatch(canonical)) {
      throw FormatException('Not a certificate SHA-256 fingerprint: "$fingerprint"');
    }
    return canonical;
  }
}

/// Ephemeral worker-side handle for a live object. Valid only within the
/// [generation] that issued it; never the only identity retained (KTD3).
@immutable
final class SessionHandle {
  const SessionHandle({required this.generation, required this.value});

  final int generation;
  final String value;
}

/// Durable reference to a manga as the source returned it (KTD3).
///
/// Bound to the source identity (including artifact digest) and settings
/// revision. [context] carries the source-returned fields subsequent calls
/// need (for Tachi the `SManga` fields; for Paperback its context). The
/// optional [handle] is ephemeral and excluded from [toJson].
@immutable
final class NativeMangaRef {
  const NativeMangaRef({
    required this.source,
    required this.mangaId,
    required this.settingsRevision,
    this.context = const <String, Object?>{},
    this.handle,
  });

  factory NativeMangaRef.fromJson(Map<String, Object?> json) => NativeMangaRef(
    source: SourceIdentity.fromJson(json['source']! as Map<String, Object?>),
    mangaId: json['mangaId']! as String,
    settingsRevision: json['settingsRevision']! as String,
    context: (json['context'] as Map<String, Object?>?) ?? const <String, Object?>{},
  );

  final SourceIdentity source;
  final String mangaId;
  final String settingsRevision;
  final Map<String, Object?> context;
  final SessionHandle? handle;

  /// A copy with a different (or no) ephemeral handle.
  NativeMangaRef withHandle(SessionHandle? handle) => NativeMangaRef(
    source: source,
    mangaId: mangaId,
    settingsRevision: settingsRevision,
    context: context,
    handle: handle,
  );

  /// Durable form; the ephemeral handle is omitted.
  Map<String, Object?> toJson() => <String, Object?>{
    'source': source.toJson(),
    'mangaId': mangaId,
    'settingsRevision': settingsRevision,
    'context': context,
  };
}
