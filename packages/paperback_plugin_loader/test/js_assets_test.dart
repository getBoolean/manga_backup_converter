// The AOT worker runs the host JavaScript compiled into
// lib/src/host/js_assets.g.dart; it must be exactly the committed assets.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:crypto/crypto.dart';
import 'package:paperback_plugin_loader/src/host/js_assets.g.dart';
import 'package:test/scaffolding.dart';

import 'support/paperback_scenarios.dart';

void main() {
  test('embedded host JavaScript matches assets/ (run tool/embed_js_assets.dart after editing)', () {
    final dir = '${repoRootDir().path}/packages/paperback_plugin_loader/assets';
    final embedded = <String, String>{
      'prelude.js': preludeJs,
      'api08.js': api08Js,
      'api09.js': api09Js,
      'ops.js': opsJs,
      'paperback_host_lib.js': hostLibJs,
    };
    check(embeddedAssetSha256.keys.toSet()).deepEquals(embedded.keys.toSet());
    for (final MapEntry<String, String> e in embedded.entries) {
      final String onDisk = File('$dir/${e.key}').readAsStringSync().replaceAll('\r\n', '\n');
      check(e.value, because: e.key).equals(onDisk);
      check(sha256.convert(utf8.encode(e.value)).toString(), because: e.key).equals(embeddedAssetSha256[e.key]!);
    }
  });

  test('the pinned host library is the recorded esbuild output of cheerio 1.0.0-rc.12', () {
    final lock = jsonDecode(
      File('${repoRootDir().path}/packages/paperback_plugin_loader/tool/host_lib/package-lock.json').readAsStringSync(),
    ) as Map<String, Object?>;
    final packages = lock['packages']! as Map<String, Object?>;
    check((packages['node_modules/cheerio']! as Map<String, Object?>)['version']).equals('1.0.0-rc.12');
    check(hostLibJs).contains('__pbLib');
  });
}
