// ignore_for_file: avoid_print

// Builds the corresponding-source archive of the embedded iOS runtime
// (OpenJDK mobile, HotSpot Zero, GPLv2 without the Classpath exception,
// statically linked) for one release, from the inputs recorded in
// tools/tachi-source-runner/ios/manifest.env at that release's commit.
//
//   dart run scripts/build_gpl_source_archive.dart [--ref REF] [--tag TAG]
//       [--out DIR] [--cache DIR] [--libffi FILE]
//
//   --ref     the repository commit the release was built from (default HEAD)
//   --tag     the release tag naming the archive (default: --ref)
//   --out     output directory (default build/gpl-source)
//   --cache   download cache (default build/gpl-source/cache): a bare clone of
//             the pinned openjdk/mobile commit and the libffi tarball
//   --libffi  use this libffi tarball instead of downloading it
//
// The archive holds:
//   openjdk-mobile/   the tree of the pinned commit (fetched with object
//                     checking; git's commit hash authenticates the tree)
//   libffi/           the release tarball, byte for byte (SHA-256 checked
//                     against the manifest)
//   manga_backup_converter/
//                     the build manifest, patches 0001-0008, build and
//                     staging scripts, back-edge rewriter and iOS host
//                     (tools/tachi-source-runner/, including ios/), the
//                     native dispatcher and its build hook
//                     (packages/source_runtime_ios/), the runtime build
//                     receipt and this script, all at --ref
//   README.md, SOURCES.json, SHA256SUMS
//
// Checks before writing: the manifest's commit and libffi digest equal the
// committed runtime build receipt's, and every patch's SHA-256 equals the
// receipt's (the receipt records the inputs of the shipped runtime build).
//
// Files are read from git objects, never from a working tree, so line
// endings, ignored files and local edits cannot leak in. Entries are sorted,
// owned by 0:0, dated at the --ref commit's time, with modes 0644/0755; the
// gzip header carries no time and OS 255. The uncompressed tar is
// byte-reproducible; the .tar.gz is reproducible with the same Dart SDK
// (its zlib). Both digests are printed and written next to the archive.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:source_runtime_ios/source_archive.dart';

final String _root = p.normalize(
  p.join(p.dirname(Platform.script.toFilePath()), '..'),
);

const String _manifestPath = 'tools/tachi-source-runner/ios/manifest.env';
const String _patchDir = 'tools/tachi-source-runner/ios/patches';

/// The committed receipt of the runtime build the app ships.
const String _receiptPath =
    'docs/validation/source-runners/ios/u9-runtime-build-outputs.json';

/// Repository paths copied at --ref.
const List<String> _repoPaths = <String>[
  'LICENSE.md',
  'tools/tachi-source-runner',
  'packages/source_runtime_ios',
  _receiptPath,
  'scripts/build_gpl_source_archive.dart',
];

Future<void> main(List<String> args) async {
  String option(String name, String fallback) {
    final int i = args.indexOf('--$name');
    if (i < 0) return fallback;
    if (i + 1 >= args.length) _fail('--$name needs a value');
    return args[i + 1];
  }

  final String ref = option('ref', 'HEAD');
  final String tag = option('tag', ref);
  final String out = p.absolute(
    option('out', p.join(_root, 'build', 'gpl-source')),
  );
  final String cache = p.absolute(option('cache', p.join(out, 'cache')));
  final String? libffiOverride = args.contains('--libffi')
      ? option('libffi', '')
      : null;

  final String commit = (await _git(_root, <String>[
    'rev-parse',
    '--verify',
    '$ref^{commit}',
  ])).trim();
  final int sourceDate = int.parse(
    (await _git(_root, <String>['show', '-s', '--format=%ct', commit])).trim(),
  );
  final Map<String, String> manifest = _parseEnv(
    await _git(_root, <String>['show', '$commit:$_manifestPath']),
  );
  String pin(String key) =>
      manifest[key] ?? _fail('$_manifestPath at $commit has no $key');
  final String jdkRepo = pin('OPENJDK_MOBILE_REPO');
  final String jdkCommit = pin('OPENJDK_MOBILE_COMMIT');
  final String libffiVersionPin = pin('LIBFFI_VERSION');
  final String libffiUrl = pin('LIBFFI_URL');
  final String libffiSha = pin('LIBFFI_SHA256');

  print('== pins ($_manifestPath at ${commit.substring(0, 12)})');
  final receipt = jsonDecode(
    await _git(_root, <String>['show', '$commit:$_receiptPath']),
  ) as Map<String, Object?>;
  final problems = <String>[
    if (receipt['openjdk_mobile_commit'] != jdkCommit)
      'receipt commit ${receipt['openjdk_mobile_commit']} != manifest $jdkCommit',
    if ((receipt['libffi']! as Map<String, Object?>)['sha256'] != libffiSha)
      'receipt libffi digest != manifest',
    if ((receipt['libffi']! as Map<String, Object?>)['version'] !=
        libffiVersionPin)
      'receipt libffi version != manifest',
  ];
  final List<_Entry> repoEntries = await _treeEntries(
    _root,
    commit,
    _repoPaths,
  );
  final Map<String, String> receiptPatches =
      (receipt['patches']! as Map<String, Object?>).cast<String, String>();
  final patches = <String, String>{};
  for (final e in repoEntries) {
    if (p.posix.dirname(e.path) == _patchDir && e.path.endsWith('.patch')) {
      patches[p.posix.basename(e.path)] = '';
    }
  }
  final Map<String, Uint8List> patchBytes = await _readBlobs(
    _root,
    repoEntries.where(
      (_Entry e) =>
          patches.containsKey(p.posix.basename(e.path)) &&
          e.path.startsWith(_patchDir),
    ),
  );
  for (final MapEntry<String, Uint8List> b in patchBytes.entries) {
    patches[p.posix.basename(b.key)] = sha256.convert(b.value).toString();
  }
  if (patches.keys.toSet().difference(receiptPatches.keys.toSet()).isNotEmpty ||
      receiptPatches.keys.toSet().difference(patches.keys.toSet()).isNotEmpty) {
    problems.add(
      'patch set ${patches.keys.toList()..sort()} != receipt ${receiptPatches.keys.toList()..sort()}',
    );
  }
  for (final MapEntry<String, String> e in patches.entries) {
    if (receiptPatches[e.key] != null && receiptPatches[e.key] != e.value) {
      problems.add(
        '${e.key}: SHA-256 ${e.value} != receipt ${receiptPatches[e.key]}',
      );
    }
  }
  if (problems.isNotEmpty) {
    _fail(
      'pins do not match the runtime build receipt:\n  ${problems.join('\n  ')}',
    );
  }
  print(
    '   openjdk/mobile $jdkCommit, libffi $libffiVersionPin, ${patches.length} patches: match $_receiptPath',
  );

  print('== openjdk/mobile $jdkCommit');
  final String jdkGit = p.join(cache, 'openjdk-mobile.git');
  if (!Directory(jdkGit).existsSync()) {
    Directory(jdkGit).createSync(recursive: true);
    await _git(jdkGit, <String>['init', '-q', '--bare']);
  }
  final ProcessResult has = await Process.run('git', <String>[
    'cat-file',
    '-e',
    '$jdkCommit^{commit}',
  ], workingDirectory: jdkGit);
  if (has.exitCode != 0) {
    print('   fetching $jdkRepo (depth 1, object checks on)');
    await _git(jdkGit, <String>[
      '-c',
      'fetch.fsckObjects=true',
      'fetch',
      '-q',
      '--depth=1',
      jdkRepo,
      jdkCommit,
    ]);
  }
  final String resolved = (await _git(jdkGit, <String>[
    'rev-parse',
    '--verify',
    '$jdkCommit^{commit}',
  ])).trim();
  if (resolved != jdkCommit) {
    _fail('openjdk/mobile resolved to $resolved, not $jdkCommit');
  }
  final String jdkTree = (await _git(jdkGit, <String>[
    'rev-parse',
    '$jdkCommit^{tree}',
  ])).trim();
  final int jdkDate = int.parse(
    (await _git(jdkGit, <String>[
      'show',
      '-s',
      '--format=%ct',
      jdkCommit,
    ])).trim(),
  );
  final List<_Entry> jdkEntries = await _treeEntries(
    jdkGit,
    jdkCommit,
    const <String>[],
  );
  print('   tree $jdkTree, ${jdkEntries.length} entries');

  print('== libffi $libffiVersionPin');
  final libffi = libffiOverride != null
      ? File(libffiOverride)
      : File(p.join(cache, p.basename(Uri.parse(libffiUrl).path)));
  if (!libffi.existsSync() || _sha256File(libffi) != libffiSha) {
    if (libffiOverride != null) {
      _fail('${libffi.path}: SHA-256 is not $libffiSha');
    }
    print('   downloading $libffiUrl');
    libffi.parent.createSync(recursive: true);
    await _download(Uri.parse(libffiUrl), libffi);
  }
  if (_sha256File(libffi) != libffiSha) {
    _fail('libffi tarball SHA-256 is not $libffiSha');
  }
  print('   SHA-256 $libffiSha');

  final String name = sourceRuntimeArchiveName(tag);
  final String top = name.substring(0, name.length - '.tar.gz'.length);
  Directory(out).createSync(recursive: true);
  final archive = File(p.join(out, name));
  print('== writing ${archive.path}');

  final sources = <String, Object?>{
    'format': 1,
    'release': <String, Object?>{
      'tag': tag,
      'commit': commit,
      'repository': projectRepositoryUrl,
    },
    'openjdk_mobile': <String, Object?>{
      'repository': jdkRepo,
      'commit': jdkCommit,
      'tree': jdkTree,
      'commit_time': jdkDate,
      'path': 'openjdk-mobile/',
    },
    'libffi': <String, Object?>{
      'version': libffiVersionPin,
      'url': libffiUrl,
      'sha256': libffiSha,
      'path': 'libffi/${p.basename(libffi.path)}',
    },
    'patches': Map<String, String>.fromEntries(
      patches.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    ),
    'receipt': _receiptPath,
    'runtime_build_revision': manifest['RUNTIME_BUILD_REVISION'],
    'image_bake_revision': manifest['IMAGE_BAKE_REVISION'],
    'boot_jdk_feature': manifest['BOOT_JDK_FEATURE'],
  };

  final writer = _TarGzWriter(archive, mtime: sourceDate);
  final sums = <String>[];
  void addFile(String path, Uint8List data, {bool executable = false}) {
    writer.addFile('$top/$path', data, executable: executable);
    sums.add('${sha256.convert(data)}  $path');
  }

  addFile('README.md', utf8.encode(_readme(tag, commit, sources, top)));
  addFile(
    'SOURCES.json',
    utf8.encode('${const JsonEncoder.withIndent('  ').convert(sources)}\n'),
  );
  addFile('libffi/${p.basename(libffi.path)}', libffi.readAsBytesSync());
  final int jdkFiles = await _addTree(
    jdkGit,
    jdkEntries,
    'openjdk-mobile',
    writer,
    top,
    sums,
  );
  final int repoFiles = await _addTree(
    _root,
    repoEntries,
    projectRepositoryName,
    writer,
    top,
    sums,
  );
  final List<String> sorted = sums.toList()
    ..sort((String a, String b) => a.substring(66).compareTo(b.substring(66)));
  writer.addFile('$top/SHA256SUMS', utf8.encode('${sorted.join('\n')}\n'));
  final (String tarSha, int tarBytes) = await writer.close();
  final String gzSha = _sha256File(archive);
  File('${archive.path}.sha256').writeAsStringSync('$gzSha  $name\n');
  File(p.join(out, '$top.tar.sha256')).writeAsStringSync('$tarSha  $top.tar\n');
  print(
    '   ${jdkFiles + repoFiles + 3} files ($jdkFiles openjdk-mobile, $repoFiles repository, libffi, README, SOURCES)',
  );
  print('   tar     SHA-256 $tarSha ($tarBytes bytes, reproducible)');
  print('   tar.gz  SHA-256 $gzSha (${archive.lengthSync()} bytes)');
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(1);
}

Map<String, String> _parseEnv(String text) => <String, String>{
  for (final String line in const LineSplitter().convert(text))
    if (RegExp(r'^([A-Z0-9_]+)=(.*)$').firstMatch(line.trim())
        case final RegExpMatch m)
      m.group(1)!: m.group(2)!.replaceAll(RegExp(r'''^["']|["']$'''), ''),
};

Future<String> _git(String dir, List<String> args) async {
  final ProcessResult r = await Process.run(
    'git',
    <String>['-c', 'core.autocrlf=false', ...args],
    workingDirectory: dir,
    stdoutEncoding: utf8,
  );
  if (r.exitCode != 0) _fail('git ${args.join(' ')} (in $dir): ${r.stderr}');
  return r.stdout as String;
}

/// One tree entry: mode (100644, 100755, 120000), object id and path.
class _Entry {
  _Entry(this.mode, this.sha, this.path);
  final String mode;
  final String sha;
  final String path;
}

Future<List<_Entry>> _treeEntries(
  String dir,
  String commit,
  List<String> paths,
) async {
  final String listing = await _git(dir, <String>[
    'ls-tree',
    '-r',
    '-z',
    '--full-tree',
    commit,
    '--',
    ...paths,
  ]);
  final entries = <_Entry>[];
  for (final String record in listing.split('\x00')) {
    if (record.isEmpty) continue;
    final int tab = record.indexOf('\t');
    final List<String> meta = record.substring(0, tab).split(' ');
    final String path = record.substring(tab + 1);
    if (meta[1] == 'commit') {
      _fail('$path is a submodule; the archive cannot hold it');
    }
    entries.add(_Entry(meta[0], meta[2], path));
  }
  return entries..sort((_Entry a, _Entry b) => a.path.compareTo(b.path));
}

Future<int> _addTree(
  String dir,
  List<_Entry> entries,
  String prefix,
  _TarGzWriter writer,
  String top,
  List<String> sums,
) async {
  var files = 0;
  await _streamBlobs(dir, entries, (_Entry e, Uint8List data) {
    final path = '$prefix/${e.path}';
    if (e.mode == '120000') {
      writer.addSymlink('$top/$path', utf8.decode(data));
    } else {
      writer.addFile('$top/$path', data, executable: e.mode == '100755');
      sums.add('${sha256.convert(data)}  $path');
      files++;
    }
  });
  return files;
}

Future<Map<String, Uint8List>> _readBlobs(
  String dir,
  Iterable<_Entry> entries,
) async {
  final result = <String, Uint8List>{};
  await _streamBlobs(
    dir,
    entries.toList(),
    (_Entry e, Uint8List data) => result[e.path] = data,
  );
  return result;
}

/// Reads each entry's blob through one `git cat-file --batch`, in order.
Future<void> _streamBlobs(
  String dir,
  List<_Entry> entries,
  void Function(_Entry, Uint8List) onBlob,
) async {
  if (entries.isEmpty) return;
  final Process proc = await Process.start('git', <String>[
    'cat-file',
    '--batch',
  ], workingDirectory: dir);
  final Future<void> feed = () async {
    for (final e in entries) {
      proc.stdin.write('${e.sha}\n');
    }
    await proc.stdin.close();
  }();
  final errors = StringBuffer();
  final Future<void> err = proc.stderr
      .transform(utf8.decoder)
      .forEach(errors.write);
  final reader = _ByteReader(proc.stdout);
  for (final e in entries) {
    final String header = utf8.decode(await reader.readUntil(0x0a));
    final List<String> parts = header.split(' ');
    if (parts.length != 3 || parts[0] != e.sha || parts[1] != 'blob') {
      _fail('cat-file: unexpected "$header" for ${e.path}');
    }
    final Uint8List data = await reader.read(int.parse(parts[2]));
    await reader.read(1); // trailing LF
    onBlob(e, data);
  }
  await reader.cancel();
  await feed;
  await err;
  if (await proc.exitCode != 0) _fail('git cat-file failed: $errors');
}

class _ByteReader {
  _ByteReader(Stream<List<int>> stream)
    : _it = StreamIterator<List<int>>(stream);
  final StreamIterator<List<int>> _it;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;

  /// Releases the stream (an open subscription keeps the process alive).
  Future<void> cancel() => _it.cancel();

  Future<bool> _fill() async {
    if (!await _it.moveNext()) return false;
    final rest = Uint8List(_buf.length - _pos + _it.current.length)
      ..setRange(0, _buf.length - _pos, _buf, _pos)
      ..setRange(
        _buf.length - _pos,
        _buf.length - _pos + _it.current.length,
        _it.current,
      );
    _buf = rest;
    _pos = 0;
    return true;
  }

  Future<Uint8List> readUntil(int byte) async {
    int from = _pos;
    while (true) {
      final int i = _buf.indexOf(byte, from);
      if (i >= 0) {
        final out = Uint8List.sublistView(_buf, _pos, i);
        _pos = i + 1;
        return Uint8List.fromList(out);
      }
      from = _buf.length - _pos;
      if (!await _fill()) _fail('git cat-file: unexpected end of output');
    }
  }

  Future<Uint8List> read(int n) async {
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      if (_pos == _buf.length && !await _fill()) {
        _fail('git cat-file: unexpected end of output');
      }
      final int take = (n - filled).clamp(0, _buf.length - _pos);
      out.setRange(filled, filled + take, _buf, _pos);
      filled += take;
      _pos += take;
    }
    return out;
  }
}

String _sha256File(File f) => sha256.convert(f.readAsBytesSync()).toString();

Future<void> _download(Uri url, File to) async {
  final client = HttpClient();
  try {
    final HttpClientResponse r = await (await client.getUrl(url)).close();
    if (r.statusCode != 200) _fail('GET $url: HTTP ${r.statusCode}');
    final part = File('${to.path}.part');
    await r.pipe(part.openWrite());
    part.renameSync(to.path);
  } finally {
    client.close();
  }
}

/// A deterministic ustar/pax writer streaming into gzip.
class _TarGzWriter {
  _TarGzWriter(this.file, {required this.mtime}) {
    _raf = file.openSync(mode: FileMode.write);
    _gzip = ZLibEncoder(
      gzip: true,
    ).startChunkedConversion(_RafSink(_raf));
    _hash = sha256.startChunkedConversion(_digest);
  }

  final File file;
  final int mtime;
  late final RandomAccessFile _raf;
  late final ByteConversionSink _gzip;
  final _DigestSink _digest = _DigestSink();
  late final ByteConversionSink _hash;
  int _bytes = 0;

  void _emit(List<int> data) {
    _gzip.add(data);
    _hash.add(data);
    _bytes += data.length;
  }

  void _pad(int size) {
    final int rem = size % 512;
    if (rem != 0) _emit(Uint8List(512 - rem));
  }

  void addFile(String path, List<int> data, {bool executable = false}) {
    _header(path, size: data.length, mode: executable ? 493 : 420, type: 0x30);
    _emit(data);
    _pad(data.length);
  }

  void addSymlink(String path, String target) =>
      _header(path, size: 0, mode: 511, type: 0x32, link: target);

  void _header(
    String path, {
    required int size,
    required int mode,
    required int type,
    String link = '',
  }) {
    final List<int> name = utf8.encode(path);
    final List<int> linkBytes = utf8.encode(link);
    var prefix = <int>[];
    var short = name;
    final pax = <String, String>{};
    if (name.length > 100) {
      final int split = _ustarSplit(path);
      if (split > 0) {
        prefix = utf8.encode(path.substring(0, split));
        short = utf8.encode(path.substring(split + 1));
      } else {
        pax['path'] = path;
        short = utf8.encode(path.substring(path.lastIndexOf('/') + 1));
        if (short.length > 100) short = short.sublist(0, 100);
      }
    }
    if (linkBytes.length > 100) pax['linkpath'] = link;
    if (pax.isNotEmpty) {
      final body = BytesBuilder();
      for (final MapEntry<String, String> e in pax.entries) {
        final rec = ' ${e.key}=${e.value}\n';
        int len = utf8.encode(rec).length;
        len += '$len'.length;
        if ('$len'.length != '${len - '$len'.length}'.length) len++;
        body.add(utf8.encode('$len$rec'));
      }
      final Uint8List paxData = body.takeBytes();
      _emit(
        _block(
          utf8.encode('PaxHeader'),
          const <int>[],
          size: paxData.length,
          mode: 420,
          type: 0x78,
          link: const <int>[],
        ),
      );
      _emit(paxData);
      _pad(paxData.length);
    }
    _emit(
      _block(
        short,
        prefix,
        size: size,
        mode: mode,
        type: type,
        link: linkBytes.length > 100 ? const <int>[] : linkBytes,
      ),
    );
  }

  /// The index of a '/' that splits [path] into a ustar prefix (<= 155
  /// bytes) and name (<= 100 bytes), or -1.
  static int _ustarSplit(String path) {
    for (int i = path.indexOf('/'); i >= 0; i = path.indexOf('/', i + 1)) {
      if (utf8.encode(path.substring(0, i)).length <= 155 &&
          utf8.encode(path.substring(i + 1)).length <= 100) {
        return i;
      }
    }
    return -1;
  }

  Uint8List _block(
    List<int> name,
    List<int> prefix, {
    required int size,
    required int mode,
    required int type,
    required List<int> link,
  }) {
    final b = Uint8List(512);
    void put(int offset, List<int> bytes) =>
        b.setRange(offset, offset + bytes.length, bytes);
    void octal(int offset, int width, int value) => put(
      offset,
      ascii.encode('${value.toRadixString(8).padLeft(width - 1, '0')}\x00'),
    );
    put(0, name);
    octal(100, 8, mode);
    octal(108, 8, 0);
    octal(116, 8, 0);
    octal(124, 12, size);
    octal(136, 12, mtime);
    b.fillRange(148, 156, 0x20);
    b[156] = type;
    put(157, link);
    put(257, ascii.encode('ustar\x00'));
    put(263, ascii.encode('00'));
    put(345, prefix);
    final int sum = b.fold(0, (int a, int c) => a + c);
    put(148, ascii.encode('${sum.toRadixString(8).padLeft(6, '0')}\x00 '));
    return b;
  }

  /// Ends the archive; returns the uncompressed tar's SHA-256 and size.
  Future<(String, int)> close() async {
    _emit(Uint8List(1024));
    _gzip.close();
    _hash.close();
    // gzip header byte 9 is the compressing OS; make it "unknown" so the
    // archive does not depend on the platform it was built on.
    _raf
      ..setPositionSync(9)
      ..writeByteSync(255)
      ..closeSync();
    return (_digest.value.toString(), _bytes);
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _RafSink implements Sink<List<int>> {
  _RafSink(this._raf);
  final RandomAccessFile _raf;
  @override
  void add(List<int> data) => _raf.writeFromSync(data);
  @override
  void close() {}
}

String _readme(
  String tag,
  String commit,
  Map<String, Object?> sources,
  String top,
) {
  final jdk = sources['openjdk_mobile']! as Map<String, Object?>;
  final ffi = sources['libffi']! as Map<String, Object?>;
  final String patches = (sources['patches']! as Map<String, String>).keys.join(
    '\n- ',
  );
  return '''
# Corresponding source: iOS source runtime, $tag

This archive is the complete corresponding source of the Java runtime
embedded in the iOS build of Manga Backup Converter $tag
($projectRepositoryUrl, commit $commit). The runtime is the OpenJDK mobile
port (HotSpot with the Zero interpreter, and the JDK class library), built
for iOS and statically linked into the app's `source_runtime_ios`
framework together with libffi and the project's native dispatcher.

HotSpot is licensed under the GNU General Public License, version 2; the
class library under GPLv2 with the Classpath exception (see
`openjdk-mobile/LICENSE`, `ASSEMBLY_EXCEPTION` and
`ADDITIONAL_LICENSE_INFO`). libffi is under the MIT licence (in its
tarball). The project's own files are under its MIT licence
(`$projectRepositoryName/LICENSE.md`); patches to OpenJDK files are under
the licence of the file they change.

## Contents

| Path | What | Pin |
| --- | --- | --- |
| `openjdk-mobile/` | the openjdk/mobile tree, unmodified | commit `${jdk['commit']}` (tree `${jdk['tree']}`) from ${jdk['repository']} |
| `${ffi['path']}` | libffi ${ffi['version']} release tarball, unmodified | SHA-256 `${ffi['sha256']}` |
| `$projectRepositoryName/tools/tachi-source-runner/ios/` | build manifest (`manifest.env`), patches, build and staging scripts (`scripts/`), back-edge rewriter and iOS host (`host/`), U16 gate sources, privacy manifest | repository commit `$commit` |
| `$projectRepositoryName/tools/tachi-source-runner/` | the shared Tachi worker whose JARs the runtime runs, and its Gradle build | same commit |
| `$projectRepositoryName/packages/source_runtime_ios/` | native dispatcher (`src/`), the build hook that links the runtime into the framework (`hook/build.dart`), and the Dart package | same commit |
| `$projectRepositoryName/${sources['receipt']}` | the receipt of the runtime build (pins, patch and artifact digests) | same commit |
| `SOURCES.json` | the pins above, machine-readable | |
| `SHA256SUMS` | SHA-256 of every other file in this archive | |

Patches, applied in order to `openjdk-mobile/`:

- $patches

The rest of the app's source is in the repository at the same commit.

## Verifying

- `sha256sum -c SHA256SUMS` (or `shasum -a 256 -c SHA256SUMS`) from this
  directory checks every file.
- The OpenJDK tree equals `git archive ${jdk['commit']}` of ${jdk['repository']}.
- The patch digests equal the runtime build receipt's (`patches` there).

## Rebuilding (macOS, Apple silicon)

Prerequisites are listed in
`$projectRepositoryName/tools/tachi-source-runner/ios/README.md` (Xcode
with the iPhoneOS and iPhoneSimulator SDKs, `brew install autoconf make`,
a JDK ${sources['boot_jdk_feature']} as the boot JDK). Without network access to the upstream
repositories:

```bash
cd $top
ios=$projectRepositoryName/tools/tachi-source-runner/ios
mkdir -p "\$ios/build/downloads"
cp ${ffi['path']} "\$ios/build/downloads/"
OPENJDK_MOBILE_SOURCE="\$PWD/openjdk-mobile" SOURCE_DATE_EPOCH=${jdk['commit_time']} \\
  "\$ios/scripts/build_runtime.sh"
```

`OPENJDK_MOBILE_SOURCE` makes the `fetch` stage copy this tree instead of
cloning the pin; `SOURCE_DATE_EPOCH` replaces the pin's commit time that
the online build reads from git. The outputs land in `\$ios/build/out/`
(`libsourcejvm.a` and the runtime image per SDK, and `outputs.json`, which
can be compared with the receipt). `stage_runtime.sh` then stages them into
`packages/source_runtime_ios/runtime/`, and `flutter build ios` links them
into the `source_runtime_ios` framework through its build hook. This
offline path has not yet been exercised on a Mac; the online path
(`build_runtime.sh` without the two variables) is the one the shipped
runtime was built with.

This archive was produced by
`$projectRepositoryName/scripts/build_gpl_source_archive.dart --ref $commit --tag $tag`.
''';
}
