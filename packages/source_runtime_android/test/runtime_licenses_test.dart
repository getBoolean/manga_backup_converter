// The Android licence page registers every library of the committed,
// generated notices asset with its full licence text.

import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:source_runtime_android/src/runtime_licenses.dart';
import 'package:test/scaffolding.dart';

class _FileBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    final String rel = key.replaceFirst('packages/source_runtime_android/', '');
    final file = File(
      Directory('packages/source_runtime_android').existsSync() ? 'packages/source_runtime_android/$rel' : rel,
    );
    return ByteData.sublistView(Uint8List.fromList(file.readAsBytesSync()));
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async =>
      utf8.decode((await load(key)).buffer.asUint8List());
}

void main() {
  setUp(LicenseRegistry.reset);

  test('registers each generated component with its full licence text', () async {
    registerSourceRuntimeLicenses(bundle: _FileBundle());
    final entries = <String, String>{
      for (final LicenseEntry e in await LicenseRegistry.licenses.toList())
        e.packages.single: e.paragraphs.map((LicenseParagraph p) => p.text).join('\n'),
    };
    // The libraries whose holders the earlier notices only referenced.
    check(entries['org.brotli:dec 0.1.2']).isNotNull().contains('the Brotli Authors');
    check(entries['uy.kohesive.injekt:injekt-core 1.16.1']).isNotNull().contains('Jayson Minard');
    check(entries['com.github.mihonapp:injekt 91edab2317']).isNotNull().contains('Jayson Minard');
    check(entries.keys.where((String k) => k.startsWith('Zstandard'))).isNotEmpty();
    check(entries['com.squareup.okhttp3:okhttp-android 5.4.0']).isNotNull().contains('Apache License');
    check(entries.keys.where((String k) => k.startsWith('html5ever '))).isNotEmpty();
  });
}
