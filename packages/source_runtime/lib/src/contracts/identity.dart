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

/// Settings chosen for a source session.
///
/// Non-secret values are typed: each is a [String], [bool] or [int], and
/// crosses JSON as that JSON type (an `int` must stay within JavaScript's
/// exact integer range, ±(2^53 − 1)). Secret values (passwords, tokens,
/// cookies) are strings and session-only (KTD9): they never appear in
/// [toJson] or in [revision].
@immutable
final class SettingsSnapshot {
  SettingsSnapshot({
    Map<String, Object> values = const <String, Object>{},
    Map<String, String> secrets = const <String, String>{},
    Set<String>? revisionAllowlist,
  }) : values = Map<String, Object>.unmodifiable(_checkValues(values)),
       secrets = Map<String, String>.unmodifiable(secrets),
       revisionAllowlist = revisionAllowlist == null ? null : Set<String>.unmodifiable(revisionAllowlist);

  /// Decodes the typed values of a wire `settings` object.
  static Map<String, Object> valuesFromJson(Map<String, Object?> json) => _checkValues(<String, Object>{
    for (final MapEntry<String, Object?> e in json.entries)
      e.key: e.value ?? (throw FormatException('Setting "${e.key}" is null')),
  });

  static const int _maxSafeInt = 9007199254740991;

  static Map<String, Object> _checkValues(Map<String, Object> values) {
    for (final MapEntry<String, Object> e in values.entries) {
      final Object v = e.value;
      if (v is int && (v > _maxSafeInt || v < -_maxSafeInt)) {
        throw FormatException('Setting "${e.key}" is outside the exact JSON integer range: $v');
      }
      if (v is! String && v is! bool && v is! int) {
        throw FormatException('Setting "${e.key}" must be a String, bool or int, got ${v.runtimeType}');
      }
    }
    return values;
  }

  /// Non-secret setting values: each a [String], [bool] or [int].
  final Map<String, Object> values;

  /// Secret setting values; session memory only.
  final Map<String, String> secrets;

  /// Non-secret keys that take part in [revision]; `null` means all of them.
  final Set<String>? revisionAllowlist;

  /// Durable, secret-free revision: a digest over the allowlisted non-secret
  /// values plus the names (never the values) of the supplied secrets.
  /// Re-entering secrets for the same keys keeps the revision.
  String get revision {
    final List<String> keys = values.keys.where((String k) => revisionAllowlist?.contains(k) ?? true).toList()..sort();
    final List<String> secretKeys = secrets.keys.toList()..sort();
    // Each value keeps its JSON type, so `true` and `'true'` differ while a
    // string-only snapshot keeps the digest it had before values were typed.
    final String canonical = jsonEncode(<String, Object?>{
      'values': <List<Object>>[
        for (final k in keys) <Object>[k, values[k]!],
      ],
      'secretKeys': secretKeys,
    });
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  /// Secret-free serialised form.
  Map<String, Object?> toJson() => <String, Object?>{
    'values': values,
    'secretKeys': secrets.keys.toList()..sort(),
    'revision': revision,
  };
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
