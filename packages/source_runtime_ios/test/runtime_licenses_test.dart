// The iOS licence page: the GPL source pointer names the release's source
// archive (published by the release workflow under the same name), the pins
// it quotes equal the build manifest, and every staged legal file and
// generated notice is registered.

import 'dart:convert';
import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart' show TestWidgetsFlutterBinding, setUp, test;
import 'package:source_runtime_ios/source_archive.dart';
import 'package:source_runtime_ios/src/runtime_licenses.dart';

class _Bundle extends CachingAssetBundle {
  _Bundle(this.files);
  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final String? text = files[key];
    if (text == null) throw FlutterError('missing $key');
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(text)));
  }
}

/// [path] relative to this package, whether tests run from it or the root.
File _file(String path) => File(
  Directory('packages/source_runtime_ios').existsSync() ? 'packages/source_runtime_ios/$path' : path,
);

Map<String, String> _manifest() => <String, String>{
  for (final String line in _file('../../tools/tachi-source-runner/ios/manifest.env').readAsLinesSync())
    if (RegExp(r'^([A-Z0-9_]+)=(.*)$').firstMatch(line) case final RegExpMatch m) m.group(1)!: m.group(2)!,
};

const String _notices =
    '{"format": 1, "components": [{"id": "vendored:libffi", "name": "libffi 3.8.1", "license": "MIT", '
    '"texts": ["k"]}], "texts": {"k": "libffi - Copyright (c) 1996-2026 Anthony Green"}}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(LicenseRegistry.reset);

  test('the quoted pins equal the build manifest', () {
    final Map<String, String> manifest = _manifest();
    check(manifest['OPENJDK_MOBILE_COMMIT']).equals(openJdkMobileCommit);
    check(manifest['LIBFFI_VERSION']).equals(libffiVersion);
  });

  test('a release build points at the source archive published with its tag', () {
    check(
      sourceRuntimeArchiveUrl('v1.2.3').toString(),
    ).equals(
      'https://github.com/getBoolean/manga_backup_converter/releases/download/v1.2.3/'
      'manga_backup_converter-v1.2.3-ios-runtime-source.tar.gz',
    );
    final String notice = sourceRuntimeSourceNotice(tag: 'v1.2.3', commit: 'abc');
    check(notice).contains(sourceRuntimeArchiveUrl('v1.2.3').toString());
    check(notice).contains(openJdkMobileCommit);
    check(notice.toLowerCase()).not((Subject<String> s) => s.contains('written offer'));
  });

  test('an untagged build says so and points at no archive', () {
    final String notice = sourceRuntimeSourceNotice(commit: 'abc123');
    check(notice).contains('not a tagged release');
    check(notice).contains('at commit abc123');
    check(notice).not((Subject<String> s) => s.contains('/releases/download/'));
  });

  test('registers the source notice, every staged legal file and each generated notice', () async {
    registerSourceRuntimeLicenses(
      bundle: _Bundle(<String, String>{
        'packages/source_runtime_ios/runtime/layout.txt':
            'stamp\tx\nhome\thome__legal__LICENSE\tlegal/LICENSE\n'
            'home\thome__legal__java.base__zlib.md\tlegal/java.base/zlib.md\nhome\thome__lib__modules\tlib/modules\n',
        'packages/source_runtime_ios/runtime/home__legal__LICENSE': 'GNU General Public License',
        'packages/source_runtime_ios/runtime/home__legal__java.base__zlib.md': 'zlib notice',
        iosThirdPartyNoticesAsset: _notices,
      }),
    );
    final List<LicenseEntry> entries = await LicenseRegistry.licenses.toList();
    final texts = <String>[
      for (final LicenseEntry e in entries) e.paragraphs.map((LicenseParagraph p) => p.text).join('\n'),
    ];
    check(entries.map((LicenseEntry e) => e.packages.single)).deepEquals(<String>[
      'OpenJDK (source runtime)',
      'OpenJDK (source runtime)',
      'OpenJDK (source runtime)',
      'libffi 3.8.1',
    ]);
    check(texts[1]).equals('GNU General Public License');
    check(texts[2]).equals('zlib notice');
    check(texts[3]).contains('Anthony Green');
  });

  test('without a staged runtime only the source notice and the generated notices register', () async {
    registerSourceRuntimeLicenses(bundle: _Bundle(<String, String>{iosThirdPartyNoticesAsset: _notices}));
    check(
      (await LicenseRegistry.licenses.toList()).map((LicenseEntry e) => e.packages.single),
    ).deepEquals(<String>['OpenJDK (source runtime)', 'libffi 3.8.1']);
  });

  test('the committed notices asset parses and names libffi and SwiftSoup', () {
    final String asset = _file('notices/third_party_notices.json').readAsStringSync();
    final json = jsonDecode(asset) as Map<String, Object?>;
    final Iterable<String> ids = (json['components']! as List<Object?>).map(
      (Object? c) => (c! as Map<String, Object?>)['id']! as String,
    );
    check(ids).contains('vendored:libffi');
    check(ids).contains('vendored:swiftsoup');
  });
}
