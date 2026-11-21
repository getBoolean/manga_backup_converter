import 'package:meta/meta.dart';

/// One reason a qualification receipt may not be published.
@immutable
final class EvidenceViolation {
  const EvidenceViolation(this.path, this.rule, this.detail);

  /// JSON path of the offending value, for example `$.checks[2].detail`.
  final String path;

  /// Which rule rejected it: `secret-field`, `secret-value`,
  /// `credential-url`, `private-text`, `raw-diagnostic`, `settings-key` or
  /// `seeded-marker`.
  final String rule;
  final String detail;

  @override
  String toString() => '$path: $rule ($detail)';
}

/// The evidence-publication check (plan, *Evidence Identity*): rejects a
/// receipt before it is retained in the repository when it holds
///
/// - a field named like a secret (password, token, cookie, authorization,
///   secret, API key, session ID), at any depth;
/// - a value shaped like one (a JWT, a `Bearer`/`Basic` credential, a
///   `Cookie:`/`Set-Cookie:` header, a known session or clearance cookie);
/// - a URL carrying credentials (user info, or a query parameter named like
///   a token, key, password, signature or session);
/// - a query or title outside the fixed public query list ([publicQueries]):
///   live qualification uses only those, and unresolved entries are counts
///   or fixture IDs, never private titles or raw searches;
/// - a raw worker diagnostic (a `stdout`/`stderr`/`log`/`trace` field, or a
///   stack trace in any value): those stay private until checked and
///   redacted;
/// - a `settings` key outside [allowedSettingKeys] (receipt settings use an
///   allowlist of known non-secret keys);
/// - one of [seededMarkers] anywhere (strings planted in test inputs to prove
///   a secret or private title never reaches a receipt).
///
/// SHA-256 digests, fixture IDs and public URLs pass. Secrets are never
/// hashed into a receipt, so a digest is never treated as a secret.
final class EvidenceCheck {
  const EvidenceCheck({
    this.publicQueries = defaultPublicQueries,
    this.allowedSettingKeys = defaultAllowedSettingKeys,
    this.seededMarkers = defaultSeededMarkers,
  });

  /// The fixed public query list of the live qualification runs.
  static const List<String> defaultPublicQueries = <String>['Onimai', 'Oshimai'];

  /// Known non-secret settings keys a receipt may record.
  static const Set<String> defaultAllowedSettingKeys = <String>{
    'language',
    'languages',
    'contentRating',
    'maxRating',
    'artifactKind',
    'apiFamily',
  };

  /// Markers seeded into test inputs; any occurrence fails.
  static const List<String> defaultSeededMarkers = <String>['MBC-SEEDED-SECRET', 'MBC-PRIVATE-TITLE'];

  final List<String> publicQueries;
  final Set<String> allowedSettingKeys;
  final List<String> seededMarkers;

  static final RegExp _secretField = RegExp(
    '^(password|passwd|pass|pwd|secret|secrets|token|tokens|access_?token|refresh_?token|id_?token|auth|'
    'authorization|proxy-authorization|cookie|cookies|set-cookie|api_?key|apikey|client_?secret|session_?id|'
    r'sessionid|bearer|credential|credentials|private_?key)$',
    caseSensitive: false,
  );

  static final RegExp _diagnosticField = RegExp(
    r'^(stdout|stderr|log|logs|trace|traces|stack|stack_?trace|diagnostic|diagnostics|transcript|raw)$',
    caseSensitive: false,
  );

  static final RegExp _textField = RegExp(
    r'^(query|queries|search|searches|searchterm|title|titles|manga_?title|series)$',
    caseSensitive: false,
  );

  static final List<(RegExp, String)> _secretValues = <(RegExp, String)>[
    (RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}'), 'JWT'),
    (RegExp(r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false), 'authorization credential'),
    (RegExp(r'\b(set-)?cookie\s*:', caseSensitive: false), 'cookie header'),
    (
      RegExp(
        r'\b(cf_clearance|__cf_bm|PHPSESSID|JSESSIONID|ASP\.NET_SessionId|sessionid|connect\.sid|mhub_access)\s*=\s*[^;\s]{4,}',
        caseSensitive: false,
      ),
      'session cookie',
    ),
    (RegExp(r'\b(password|passwd|token|secret|api_?key)\s*[=:]\s*\S{3,}', caseSensitive: false), 'inline secret'),
  ];

  static final List<(RegExp, String)> _diagnosticValues = <(RegExp, String)>[
    (RegExp(r'\n\s+at [\w$.<>]+\('), 'JVM stack trace'),
    (RegExp('Exception in thread '), 'JVM stack trace'),
    (RegExp(r'#\d+\s+\S+ \((package|file|dart):'), 'Dart stack trace'),
    (RegExp(r'^\[(jvm|paperback|desktop_webview|browser)\] ', multiLine: true), 'worker log line'),
  ];

  static final RegExp _url = RegExp(r'''[a-z][a-z0-9+.-]*://[^\s"'<>]+''', caseSensitive: false);

  static final RegExp _credentialParam = RegExp(
    '^(token|access_?token|refresh_?token|key|api_?key|apikey|password|passwd|pass|pwd|secret|sig|signature|'
    r'session|sessionid|sid|auth|code|jwt|x-amz-signature|x-amz-credential)$',
    caseSensitive: false,
  );

  /// Every violation in [receipt] (decoded JSON).
  List<EvidenceViolation> check(Object? receipt) {
    final out = <EvidenceViolation>[];
    _walk(receipt, r'$', null, out);
    return out;
  }

  void _walk(Object? value, String path, String? key, List<EvidenceViolation> out) {
    switch (value) {
      case final Map<String, Object?> map:
        for (final MapEntry<String, Object?> e in map.entries) {
          final child = '$path.${e.key}';
          if (_secretField.hasMatch(e.key) && !_isEmpty(e.value)) {
            out.add(EvidenceViolation(child, 'secret-field', 'field "${e.key}" names a secret'));
            continue;
          }
          if (_diagnosticField.hasMatch(e.key) && !_isEmpty(e.value)) {
            out.add(EvidenceViolation(child, 'raw-diagnostic', 'field "${e.key}" holds raw worker output'));
            continue;
          }
          if (e.key == 'settings' && e.value is Map<String, Object?>) {
            for (final String k in (e.value! as Map<String, Object?>).keys) {
              if (!allowedSettingKeys.contains(k)) {
                out.add(EvidenceViolation('$child.$k', 'settings-key', 'settings key "$k" is not allowlisted'));
              }
            }
          }
          _walk(e.value, child, e.key, out);
        }
      case final List<Object?> list:
        for (final (int i, Object? v) in list.indexed) {
          _walk(v, '$path[$i]', key, out);
        }
      case final String s:
        _checkString(s, path, key, out);
    }
  }

  static bool _isEmpty(Object? v) =>
      v == null || (v is String && v.isEmpty) || (v is List && v.isEmpty) || (v is Map && v.isEmpty);

  void _checkString(String s, String path, String? key, List<EvidenceViolation> out) {
    for (final String marker in seededMarkers) {
      if (s.contains(marker)) out.add(EvidenceViolation(path, 'seeded-marker', 'contains seeded marker $marker'));
    }
    for (final (RegExp re, String what) in _secretValues) {
      if (re.hasMatch(s)) out.add(EvidenceViolation(path, 'secret-value', what));
    }
    for (final (RegExp re, String what) in _diagnosticValues) {
      if (re.hasMatch(s)) out.add(EvidenceViolation(path, 'raw-diagnostic', what));
    }
    for (final RegExpMatch m in _url.allMatches(s)) {
      final Uri? uri = Uri.tryParse(m.group(0)!);
      if (uri == null) continue;
      if (uri.userInfo.isNotEmpty) {
        out.add(EvidenceViolation(path, 'credential-url', 'URL with user info'));
      }
      final List<String> bad = uri.queryParametersAll.keys.where(_credentialParam.hasMatch).toList();
      if (bad.isNotEmpty) {
        out.add(EvidenceViolation(path, 'credential-url', 'URL query parameter(s) ${bad.join(', ')}'));
      }
    }
    if (key != null && _textField.hasMatch(key) && s.trim().isNotEmpty) {
      final String lower = s.toLowerCase();
      if (!publicQueries.any((String q) => lower.contains(q.toLowerCase()))) {
        out.add(EvidenceViolation(path, 'private-text', '"$key" is not from the public query list'));
      }
    }
  }
}
