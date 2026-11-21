// Strips client-identifying data from recorded Paperback captures, then
// re-digests each changed body and rewrites `capture.json`.
//
//     dart run tool/sanitize_captures.dart <capture dir>...
//
// `tool/capture_paperback_sources.dart` runs it after every recording. Rules:
// - MangaDex's POWBlock challenge page embeds a token (`<pre id=c>`) that
//   carries the requesting client's network address: replaced.
// - Cloudflare challenge snippets carry per-request ray IDs (`r:'…'`,
//   `ray=…`): zeroed.
// - Any remaining dotted IPv4 address in a body fails the run, so a new kind
//   of leak is caught before it is committed.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:source_runtime/source_runtime.dart';

void main(List<String> args) {
  for (final path in args) {
    final int changed = sanitizeCaptureDir(Directory(path));
    stdout.writeln('$path: $changed body(ies) sanitized');
  }
}

final List<(RegExp, String)> _rules = <(RegExp, String)>[
  (RegExp('(<pre id=c style=display:none>)[^<]*(</pre>)'), r'$1REDACTED-CLIENT-TOKEN$2'),
  (RegExp(r"(__CF\$cv\$params=\{r:')[0-9a-f]+(')"), r'$10000000000000000$2'),
  (RegExp(r'(\bray=)[0-9a-f]{16}\b'), r'$10000000000000000'),
];

final RegExp _ipv4 = RegExp(r'(?<![\d.])(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?![\d.])');

/// Sanitizes every body of the capture in [dir]; returns how many changed.
int sanitizeCaptureDir(Directory dir) {
  final manifestFile = File('${dir.path}/$captureManifestFileName');
  final manifest = CaptureManifest.fromJson(jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>);
  var changed = 0;
  final exchanges = <CaptureExchange>[];
  for (final CaptureExchange e in manifest.exchanges) {
    final bodyFile = File('${dir.path}/${e.bodyFile}');
    final Uint8List bytes = bodyFile.readAsBytesSync();
    final String text = utf8.decode(bytes, allowMalformed: true);
    var cleaned = text;
    for (final (RegExp pattern, String replacement) in _rules) {
      cleaned = cleaned.replaceAllMapped(
        pattern,
        (Match m) =>
            replacement.replaceAllMapped(RegExp(r'\$(\d)'), (Match r) => m.group(int.parse(r.group(1)!)) ?? ''),
      );
    }
    // JSON API bodies carry version strings like 1.2.3.4 rarely; only HTML
    // and text bodies are expected to hold addresses.
    final bool isText =
        (e.headers['content-type'] ?? '').contains('html') || (e.headers['content-type'] ?? '').contains('text');
    if (isText && _ipv4.hasMatch(cleaned)) {
      throw StateError(
        '${e.bodyFile} (${e.key.url}) still contains an IPv4 address: ${_ipv4.firstMatch(cleaned)!.group(0)}',
      );
    }
    if (cleaned == text) {
      exchanges.add(e);
      continue;
    }
    changed++;
    final Uint8List out = utf8.encode(cleaned);
    final String digest = sha256Hex(out);
    final newBody = '$captureBodiesDirName/$digest.bin';
    File('${dir.path}/$newBody').writeAsBytesSync(out);
    if (newBody != e.bodyFile && !manifest.exchanges.any((CaptureExchange o) => o != e && o.bodyFile == e.bodyFile)) {
      bodyFile.deleteSync();
    }
    exchanges.add(
      CaptureExchange(
        key: e.key,
        status: e.status,
        headers: e.headers,
        bodyFile: newBody,
        artifact: CaptureArtifact(
          sourceUrl: e.artifact.sourceUrl,
          sha256: digest,
          size: out.length,
          licence: e.artifact.licence,
        ),
      ),
    );
  }
  manifestFile.writeAsStringSync(
    CaptureManifest(
      ecosystem: manifest.ecosystem,
      source: manifest.source,
      recordedAt: manifest.recordedAt,
      notes: manifest.notes.contains('sanitized')
          ? manifest.notes
          : '${manifest.notes}; sanitized by tool/sanitize_captures.dart',
      volatileQueryParameters: manifest.volatileQueryParameters,
      exchanges: exchanges,
    ).encode(),
  );
  return changed;
}
