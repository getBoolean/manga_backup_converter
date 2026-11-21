import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

/// Capture format version written to and required from `capture.json`.
const int captureFormatVersion = 1;

/// File name of the capture manifest inside a capture directory.
const String captureManifestFileName = 'capture.json';

/// Directory (relative to the capture directory) holding response bodies.
const String captureBodiesDirName = 'bodies';

/// Lowercase hex SHA-256 of [bytes].
String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// Identity used to match a live request against a committed capture.
///
/// Matching is on method, canonical URL (query parameters sorted, fragment
/// dropped) and the SHA-256 of the request body. Request headers do not take
/// part: they are never stored, so cookies and authorization cannot leak into
/// committed fixtures.
///
/// Query parameters named in `volatile` (for example a source that sends the
/// current date) match on name only; their recorded value is [volatileValue].
@immutable
final class CaptureKey {
  CaptureKey({
    required String method,
    required Uri url,
    this.bodySha256,
    Set<String> volatile = const <String>{},
  }) : method = method.toUpperCase(),
       url = canonicalUrl(url, volatile: volatile);

  /// Builds a key from a request's parts.
  factory CaptureKey.forRequest(
    String method,
    Uri url,
    List<int>? body, {
    Set<String> volatile = const <String>{},
  }) => CaptureKey(
    method: method,
    url: url,
    bodySha256: body == null || body.isEmpty ? null : sha256Hex(body),
    volatile: volatile,
  );

  /// Value recorded in place of a volatile query parameter's value.
  static const String volatileValue = '*';

  final String method;
  final String url;
  final String? bodySha256;

  /// Canonical string form of [url] used for matching.
  static String canonicalUrl(Uri url, {Set<String> volatile = const <String>{}}) {
    final Uri noFragment = url.removeFragment();
    if (!noFragment.hasQuery) return noFragment.toString();
    final params =
        <MapEntry<String, String>>[
          for (final MapEntry<String, List<String>> e in noFragment.queryParametersAll.entries)
            for (final String v in e.value)
              MapEntry<String, String>(e.key, volatile.contains(e.key) ? volatileValue : v),
        ]..sort((MapEntry<String, String> a, MapEntry<String, String> b) {
          final int byKey = a.key.compareTo(b.key);
          return byKey != 0 ? byKey : a.value.compareTo(b.value);
        });
    final String query = params
        .map((MapEntry<String, String> e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return noFragment.replace(query: query).toString();
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureKey && other.method == method && other.url == url && other.bodySha256 == bodySha256;

  @override
  int get hashCode => Object.hash(method, url, bodySha256);

  @override
  String toString() => '$method $url${bodySha256 == null ? '' : ' body=$bodySha256'}';
}

/// Provenance of one committed artifact: where it came from, its digest, and
/// the licence or terms it is held under.
final class CaptureArtifact {
  const CaptureArtifact({required this.sourceUrl, required this.sha256, required this.size, required this.licence});

  factory CaptureArtifact.fromJson(Map<String, Object?> json) => CaptureArtifact(
    sourceUrl: json['sourceUrl']! as String,
    sha256: json['sha256']! as String,
    size: json['size']! as int,
    licence: json['licence']! as String,
  );

  final String sourceUrl;
  final String sha256;
  final int size;
  final String licence;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceUrl': sourceUrl,
    'sha256': sha256,
    'size': size,
    'licence': licence,
  };
}

/// How an allow-listed `Set-Cookie` value is written to a capture.
enum CapturedCookieValue {
  /// The value is recorded as the site sent it. Only for values that are not
  /// credentials (for example a consent flag).
  keep,

  /// The value is replaced by [CapturedCookie.redactedValue]; the cookie's
  /// presence and name still replay (for example a site-issued token such as
  /// Mangahub's `mhub_access`).
  redact;

  static CapturedCookieValue fromWire(Object? wire) => switch (wire) {
    'keep' => keep,
    'redact' => redact,
    _ => throw FormatException('Unknown cookie capture mode $wire (expected keep or redact)'),
  };
}

/// A sanitised `Set-Cookie` a capture records for an allow-listed cookie
/// name ([CaptureManifest.setCookieAllowList]).
///
/// Only the name, the (possibly redacted) value, `Path` and `Domain` are
/// kept. Expiry, `Max-Age` and every other attribute are dropped, so a
/// replay never depends on the recording date.
@immutable
final class CapturedCookie {
  const CapturedCookie({required this.name, required this.value, this.path, this.domain, this.redacted = false});

  factory CapturedCookie.fromJson(Map<String, Object?> json) => CapturedCookie(
    name: json['name']! as String,
    value: json['value']! as String,
    path: json['path'] as String?,
    domain: json['domain'] as String?,
    redacted: json['redacted'] as bool? ?? false,
  );

  /// Value recorded in place of a [CapturedCookieValue.redact] cookie.
  static const String redactedValue = 'redacted';

  final String name;
  final String value;
  final String? path;
  final String? domain;

  /// Whether [value] is [redactedValue] rather than what the site sent.
  final bool redacted;

  /// The `Set-Cookie` header value replay serves.
  String toHeader() => <String>[
    '$name=$value',
    if (path != null) 'Path=$path',
    if (domain != null) 'Domain=$domain',
  ].join('; ');

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'value': value,
    if (path != null) 'path': path,
    if (domain != null) 'domain': domain,
    if (redacted) 'redacted': true,
  };

  @override
  bool operator ==(Object other) =>
      other is CapturedCookie &&
      other.name == name &&
      other.value == value &&
      other.path == path &&
      other.domain == domain &&
      other.redacted == redacted;

  @override
  int get hashCode => Object.hash(name, value, path, domain, redacted);

  @override
  String toString() => 'CapturedCookie(${toHeader()}${redacted ? ', redacted' : ''})';
}

/// One cookie parsed from a live `Set-Cookie` header.
typedef ParsedSetCookie = ({String name, String value, String? path, String? domain});

/// Splits a `Set-Cookie` header value into cookies.
///
/// `package:http` joins repeated `Set-Cookie` headers with commas, and an
/// `Expires` date contains a comma too (`Expires=Wed, 21 Oct 2026 …`), so a
/// comma separates cookies only when a `name=` follows it. Attributes other
/// than `Path` and `Domain` are dropped; a part without `name=` is ignored.
List<ParsedSetCookie> parseSetCookieHeader(String header) => <ParsedSetCookie>[
  for (final String part in header.split(RegExp(r',(?=\s*[^;,=\s]+=)')))
    if (_parseOneCookie(part) case final ParsedSetCookie cookie) cookie,
];

ParsedSetCookie? _parseOneCookie(String text) {
  final List<String> parts = text.split(';');
  final int eq = parts.first.indexOf('=');
  if (eq <= 0) return null;
  final String name = parts.first.substring(0, eq).trim();
  if (name.isEmpty) return null;
  String? path;
  String? domain;
  for (final String attribute in parts.skip(1)) {
    final int i = attribute.indexOf('=');
    if (i < 0) continue;
    final String key = attribute.substring(0, i).trim().toLowerCase();
    final String value = attribute.substring(i + 1).trim();
    if (key == 'path') path = value;
    if (key == 'domain') domain = value;
  }
  return (name: name, value: parts.first.substring(eq + 1).trim(), path: path, domain: domain);
}

/// One recorded request/response exchange.
final class CaptureExchange {
  const CaptureExchange({
    required this.key,
    required this.status,
    required this.headers,
    required this.bodyFile,
    required this.artifact,
    this.setCookies = const <CapturedCookie>[],
  });

  factory CaptureExchange.fromJson(Map<String, Object?> json, {Set<String> volatile = const <String>{}}) {
    final request = json['request']! as Map<String, Object?>;
    final response = json['response']! as Map<String, Object?>;
    return CaptureExchange(
      key: CaptureKey(
        method: request['method']! as String,
        url: Uri.parse(request['url']! as String),
        bodySha256: request['bodySha256'] as String?,
        volatile: volatile,
      ),
      status: response['status']! as int,
      headers: (response['headers']! as Map<String, Object?>).cast<String, String>(),
      bodyFile: response['body']! as String,
      artifact: CaptureArtifact.fromJson(json['artifact']! as Map<String, Object?>),
      setCookies: <CapturedCookie>[
        for (final Object? c in response['setCookies'] as List<Object?>? ?? const <Object?>[])
          CapturedCookie.fromJson(c! as Map<String, Object?>),
      ],
    );
  }

  final CaptureKey key;
  final int status;

  /// Response headers, lowercase names: only the recorded allow-list
  /// (`recordedResponseHeaders`), never cookie or auth headers.
  final Map<String, String> headers;

  /// Sanitised `Set-Cookie`s for allow-listed names, in the order the site
  /// sent them. Empty unless the manifest's
  /// [CaptureManifest.setCookieAllowList] named a cookie the response set.
  final List<CapturedCookie> setCookies;

  /// [headers] plus a `set-cookie` header built from [setCookies], joined
  /// with `, ` the way `package:http` joins repeated headers.
  Map<String, String> get replayHeaders => setCookies.isEmpty
      ? headers
      : <String, String>{
          ...headers,
          'set-cookie': setCookies.map((CapturedCookie c) => c.toHeader()).join(', '),
        };

  /// Body path relative to the capture directory (`bodies/<sha256>.bin`).
  final String bodyFile;
  final CaptureArtifact artifact;

  Map<String, Object?> toJson() => <String, Object?>{
    'request': <String, Object?>{'method': key.method, 'url': key.url, 'bodySha256': key.bodySha256},
    'response': <String, Object?>{
      'status': status,
      'headers': headers,
      'body': bodyFile,
      if (setCookies.isNotEmpty) 'setCookies': <Object?>[for (final CapturedCookie c in setCookies) c.toJson()],
    },
    'artifact': artifact.toJson(),
  };
}

/// Parsed `capture.json` for `fixtures/source_captures/<ecosystem>/<source>/`.
final class CaptureManifest {
  const CaptureManifest({
    required this.ecosystem,
    required this.source,
    required this.recordedAt,
    required this.exchanges,
    this.notes = '',
    this.volatileQueryParameters = const <String>{},
    this.setCookieAllowList = const <String, CapturedCookieValue>{},
  });

  factory CaptureManifest.fromJson(Map<String, Object?> json) {
    final Object? format = json['format'];
    if (format != captureFormatVersion) {
      throw FormatException('Unsupported capture format $format (expected $captureFormatVersion)');
    }
    final volatile = <String>{
      for (final Object? v in json['volatileQueryParameters'] as List<Object?>? ?? const <Object?>[]) v! as String,
    };
    return CaptureManifest(
      ecosystem: json['ecosystem']! as String,
      source: json['source']! as String,
      recordedAt: DateTime.parse(json['recordedAt']! as String),
      notes: json['notes'] as String? ?? '',
      volatileQueryParameters: volatile,
      setCookieAllowList: <String, CapturedCookieValue>{
        for (final MapEntry<String, Object?> e
            in (json['setCookieAllowList'] as Map<String, Object?>? ?? const <String, Object?>{}).entries)
          e.key: CapturedCookieValue.fromWire(e.value),
      },
      exchanges: <CaptureExchange>[
        for (final Object? e in json['exchanges']! as List<Object?>)
          CaptureExchange.fromJson(e! as Map<String, Object?>, volatile: volatile),
      ],
    );
  }

  final String ecosystem;
  final String source;
  final DateTime recordedAt;
  final String notes;
  final List<CaptureExchange> exchanges;

  /// Query parameters matched by name only (see [CaptureKey]).
  final Set<String> volatileQueryParameters;

  /// Cookie names whose `Set-Cookie` the recording kept, and how each value
  /// was written. Empty by default: no cookie is recorded unless a scenario
  /// names it explicitly.
  final Map<String, CapturedCookieValue> setCookieAllowList;

  /// Key for a live request under this manifest's matching rules.
  CaptureKey keyFor(String method, Uri url, List<int>? body) =>
      CaptureKey.forRequest(method, url, body, volatile: volatileQueryParameters);

  Map<String, Object?> toJson() => <String, Object?>{
    'format': captureFormatVersion,
    'ecosystem': ecosystem,
    'source': source,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
    'recordedBy': 'tool/capture_source_fixtures.dart',
    'notes': notes,
    'volatileQueryParameters': volatileQueryParameters.toList()..sort(),
    if (setCookieAllowList.isNotEmpty)
      'setCookieAllowList': <String, String>{
        for (final String name in setCookieAllowList.keys.toList()..sort()) name: setCookieAllowList[name]!.name,
      },
    'exchanges': <Object?>[for (final CaptureExchange e in exchanges) e.toJson()],
  };

  String encode() => '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';
}

/// A verified response served from a capture.
final class CapturedResponse {
  const CapturedResponse({
    required this.status,
    required this.headers,
    required this.body,
    this.setCookies = const <CapturedCookie>[],
  });

  final int status;

  /// Recorded headers, including a `set-cookie` built from [setCookies]
  /// (see [CaptureExchange.replayHeaders]).
  final Map<String, String> headers;
  final Uint8List body;

  /// The sanitised cookies the response set, one entry per cookie.
  final List<CapturedCookie> setCookies;
}

/// Thrown, and recorded, when a request has no committed capture.
final class CaptureMissException implements Exception {
  const CaptureMissException(this.key);

  final CaptureKey key;

  @override
  String toString() => 'CaptureMissException: no committed capture for $key';
}

/// Committed captures loaded into memory, with every body digest verified.
///
/// Replay serves only these; any other request is a [CaptureMissException].
final class CaptureSet {
  CaptureSet(this.manifest, Map<CaptureKey, CapturedResponse> responses) : _responses = responses;

  /// Builds a set from a manifest and the body bytes keyed by `bodyFile`,
  /// verifying each body against its recorded SHA-256 and size.
  factory CaptureSet.fromParts(CaptureManifest manifest, Map<String, Uint8List> bodies) {
    final responses = <CaptureKey, CapturedResponse>{};
    for (final CaptureExchange e in manifest.exchanges) {
      final Uint8List? body = bodies[e.bodyFile];
      if (body == null) throw FormatException('Capture body missing: ${e.bodyFile}');
      final String digest = sha256Hex(body);
      if (digest != e.artifact.sha256 || body.length != e.artifact.size) {
        throw FormatException('Capture body ${e.bodyFile} does not match its recorded SHA-256 ($digest)');
      }
      responses[e.key] = CapturedResponse(
        status: e.status,
        headers: e.replayHeaders,
        body: body,
        setCookies: e.setCookies,
      );
    }
    return CaptureSet(manifest, responses);
  }

  final CaptureManifest manifest;
  final Map<CaptureKey, CapturedResponse> _responses;

  /// Returns the captured response for [key], or throws [CaptureMissException].
  CapturedResponse lookup(CaptureKey key) => _responses[key] ?? (throw CaptureMissException(key));

  /// Whether [key] has a capture.
  bool contains(CaptureKey key) => _responses.containsKey(key);
}
