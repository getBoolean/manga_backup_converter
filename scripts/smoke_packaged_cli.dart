// ignore_for_file: avoid_print
// Smoke test of a package built by scripts/package_cli.dart (U8).
//
//   dart run scripts/smoke_packaged_cli.dart [--package <dir>] [--receipt <file>]
//
// 1. Copies the package into a directory whose path contains spaces.
// 2. Checks every file against runtime/runtime-manifest.json, the licence
//    files, and that no test fixture shipped.
// 3. Runs with a scrubbed environment: PATH holds only the OS directories,
//    and JAVA_HOME, TACHI_JAVA_HOME, DART/FLUTTER and cargo variables are
//    removed; java, dart, gradle and cargo must not resolve on that PATH
//    (on macOS `/usr/bin/java` is the OS's launcher stub, always present; it
//    is recorded, and the runtime check shows the bundled JRE ran instead).
// 4. `--help`; the bundled JRE's version against the security floor.
// 5. `__runtime-check`: the JVM worker, the Paperback worker and the WebView
//    helper start offline and close; afterwards none of their processes run.
// 6. `__runtime-check --hold`, then the CLI is killed (a cancelled or
//    crashed conversion): its workers and helper must exit on their own.
//
// Exit code 0 when every check passes. With --receipt, writes a JSON receipt
// (no paths outside the package, no environment values).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

final String _root = p.normalize(
  p.join(p.dirname(Platform.script.toFilePath()), '..'),
);
String get _exe => Platform.isWindows ? '.exe' : '';

final List<Map<String, Object?>> _checks = <Map<String, Object?>>[];

void _record(String name, bool ok, [Object? detail]) {
  _checks.add(<String, Object?>{'check': name, 'ok': ok, 'detail': ?detail});
  print('${ok ? 'PASS' : 'FAIL'} $name${detail == null ? '' : ': $detail'}');
}

Future<void> main(List<String> args) async {
  String? option(String name) {
    final int i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final arch = Platform.version.contains('arm64') ? 'arm64' : 'x64';
  final source = Directory(
    option('--package') ??
        p.join(_root, 'build', 'package', '${Platform.operatingSystem}-$arch'),
  );
  final Directory temp = await Directory.systemTemp.createTemp('mbc smoke ');
  final pkg = Directory(p.join(temp.path, 'Manga Backup Converter'));
  try {
    await _copyTree(source, pkg);
    _record('copied into a path with spaces', pkg.path.contains(' '));

    // Manifest, licences, fixtures.
    final manifest = jsonDecode(
      File(p.join(pkg.path, 'runtime', 'runtime-manifest.json'))
          .readAsStringSync(),
    ) as Map<String, Object?>;
    final Map<String, String> files =
        (manifest['files']! as Map<String, Object?>).cast<String, String>();
    final mismatched = <String>[
      for (final MapEntry<String, String> f in files.entries)
        if (!File(p.join(pkg.path, f.key)).existsSync() ||
            crypto.sha256
                    .convert(File(p.join(pkg.path, f.key)).readAsBytesSync())
                    .toString() !=
                f.value)
          f.key,
    ];
    final unlisted = <String>[
      for (final File f in pkg.listSync(recursive: true).whereType<File>())
        if (p.relative(f.path, from: pkg.path).replaceAll(r'\', '/')
            case final String rel
            when rel != 'runtime/runtime-manifest.json' &&
                !files.containsKey(rel))
          rel,
    ];
    _record(
      'manifest hashes match the packaged files',
      mismatched.isEmpty && unlisted.isEmpty,
      <String, Object?>{
        'files': files.length,
        if (mismatched.isNotEmpty) 'mismatched': mismatched,
        if (unlisted.isNotEmpty) 'unlisted': unlisted,
      },
    );
    final licenseFiles = <String>[
      for (final File f in Directory(
        p.join(pkg.path, 'licenses'),
      ).listSync().whereType<File>())
        p.basename(f.path),
    ]..sort();
    final bool jreLegal = Directory(p.join(pkg.path, 'runtime', 'jre', 'legal'))
        .existsSync();
    _record(
      'licence and notice files present',
      licenseFiles.contains('NOTICE.md') &&
          licenseFiles.contains('LICENSE.md') &&
          jreLegal,
      <String, Object?>{'licenses': licenseFiles, 'jreLegal': jreLegal},
    );
    final List<String> fixtures = files.keys
        .where(
          (String f) =>
              f.contains('fixtures/') ||
              f.endsWith('.aix') ||
              p.basename(f).startsWith('tachiyomi-'),
        )
        .toList();
    _record(
      'no test fixtures or source artifacts shipped',
      fixtures.isEmpty,
      fixtures.isEmpty ? null : fixtures,
    );

    if (Platform.isMacOS) {
      final unsigned = <String>[];
      final quarantined = <String>[];
      var machO = 0;
      for (final File f in pkg.listSync(recursive: true).whereType<File>()) {
        final String rel = p.relative(f.path, from: pkg.path);
        final ProcessResult x = await Process.run('xattr', <String>[
          '-p',
          'com.apple.quarantine',
          f.path,
        ]);
        if (x.exitCode == 0) quarantined.add(rel);
        final ProcessResult kind = await Process.run('file', <String>[
          '-b',
          f.path,
        ]);
        if (!(kind.stdout as String).startsWith('Mach-O')) continue;
        machO++;
        final ProcessResult verify = await Process.run('codesign', <String>[
          '-v',
          f.path,
        ]);
        if (verify.exitCode != 0) unsigned.add(rel);
      }
      _record(
        'every Mach-O file has a valid signature and nothing is quarantined',
        machO > 0 && unsigned.isEmpty && quarantined.isEmpty,
        <String, Object?>{
          'machO': machO,
          if (unsigned.isNotEmpty) 'invalid': unsigned,
          if (quarantined.isNotEmpty) 'quarantined': quarantined,
        },
      );
    }

    // Scrubbed environment.
    final Map<String, String> env = _scrubbedEnvironment();
    final found = <String>[];
    final osStubs = <String>[];
    for (final tool in <String>[
      'java',
      'dart',
      'flutter',
      'gradle',
      'cargo',
      'rustc',
      'node',
    ]) {
      final ProcessResult r = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        <String>[tool],
        environment: env,
        includeParentEnvironment: false,
        runInShell: Platform.isWindows,
      );
      if (r.exitCode != 0) continue;
      final String at = (r.stdout as String).trim();
      if (Platform.isMacOS && tool == 'java' && at == '/usr/bin/java') {
        osStubs.add(at);
      } else {
        found.add(tool);
      }
    }
    _record(
      'no system java/dart/gradle/rust/node on the scrubbed PATH',
      found.isEmpty,
      <String, Object?>{
        if (found.isNotEmpty) 'found': found,
        if (osStubs.isNotEmpty) 'osLauncherStubs': osStubs,
      },
    );

    final String cli = p.join(pkg.path, 'bin', 'mangabackupconverter_cli$_exe');
    final ProcessResult help = await Process.run(
      cli,
      <String>['--help'],
      environment: env,
      includeParentEnvironment: false,
    );
    _record('--help runs', help.exitCode == 0, 'exit ${help.exitCode}');

    final ProcessResult java = await Process.run(
      p.join(pkg.path, 'runtime', 'jre', 'bin', 'java$_exe'),
      <String>['-version'],
      environment: env,
      includeParentEnvironment: false,
    );
    final String javaLine = (java.stderr as String).split('\n').first.trim();
    final floor =
        (manifest['jre']! as Map<String, Object?>)['securityFloor']! as String;
    _record(
      'bundled JRE at or above the security floor $floor',
      _atLeast(javaLine, floor),
      javaLine,
    );

    // Start and close everything.
    final ({int code, Map<String, Object?>? report, String stderr}) check =
        await _runtimeCheck(cli, env, hold: false);
    final Map<String, Object?>? report = check.report;
    _record(
      'runtime check starts the JVM worker, Paperback worker and WebView helper',
      check.code == 0 && report?['ok'] == true,
      <String, Object?>{
        'exit': check.code,
        'tachi': _strip(report?['tachi'], pkg.path),
        'paperback': _strip(report?['paperback'], pkg.path),
        'helper': _strip(report?['helper'], pkg.path),
        if (check.code != 0) 'stderr': _tail(check.stderr),
      },
    );
    final List<int> pids = _pids(report);
    final List<int> leftAfterClose = await _waitGone(
      pids,
      const Duration(seconds: 30),
    );
    _record(
      'closing leaves no owned worker or helper process',
      pids.length == 3 && leftAfterClose.isEmpty,
      <String, Object?>{
        'owned': pids.length,
        'left': leftAfterClose,
      },
    );

    // Kill the CLI mid-session.
    final ({
      List<int> pids,
      List<int> left,
      List<int> webview,
      List<int> webviewLeft,
    })
    killed = await _killMidSession(cli, env);
    _record(
      'killing the CLI leaves no owned worker or helper process',
      killed.pids.length == 3 &&
          killed.left.isEmpty &&
          (!Platform.isMacOS || killed.webviewLeft.isEmpty),
      <String, Object?>{
        'owned': killed.pids.length,
        'left': killed.left,
        if (Platform.isWindows)
          'webview2ChildrenStillTerminating': killed.webviewLeft.length,
        if (Platform.isMacOS) ...<String, Object?>{
          'webkitProcessesStarted': killed.webview.length,
          'webkitProcessesLeft': killed.webviewLeft.length,
        },
      },
    );
  } finally {
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      // A WebView2 process may still release the data directory.
    }
  }

  final bool ok = _checks.every((Map<String, Object?> c) => c['ok'] == true);
  final String? receipt = option('--receipt');
  if (receipt != null) {
    final manifest = jsonDecode(
      File(p.join(source.path, 'runtime', 'runtime-manifest.json'))
          .readAsStringSync(),
    ) as Map<String, Object?>;
    File(receipt).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'kind': 'desktop-package-smoke',
        'evidence': 'local packaged build',
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
        'os': Platform.operatingSystem,
        'osVersion': Platform.operatingSystemVersion,
        'arch': manifest['arch'],
        'hostCommit': manifest['hostCommit'],
        'hostDirty': manifest['hostDirty'],
        'jre': manifest['jre'],
        'ok': ok,
        'checks': _checks,
      })}\n',
    );
  }
  exitCode = ok ? 0 : 1;
}

/// Only the OS directories on PATH; no toolchain variables.
Map<String, String> _scrubbedEnvironment() {
  final Map<String, String> parent = Platform.environment;
  String? get(String name) {
    for (final MapEntry<String, String> e in parent.entries) {
      if (e.key.toUpperCase() == name.toUpperCase()) return e.value;
    }
    return null;
  }

  if (Platform.isWindows) {
    final String sysRoot = get('SystemRoot') ?? r'C:\Windows';
    return <String, String>{
      // OS variables every Windows session has (without them some system
      // components write to a literal "%SystemDrive%" directory); no
      // toolchain variable is kept.
      'SystemRoot': sysRoot,
      'windir': sysRoot,
      'SystemDrive': ?get('SystemDrive'),
      'ProgramData': ?get('ProgramData'),
      'ProgramFiles': ?get('ProgramFiles'),
      'ProgramFiles(x86)': ?get('ProgramFiles(x86)'),
      'PATHEXT': ?get('PATHEXT'),
      'OS': ?get('OS'),
      'PROCESSOR_ARCHITECTURE': ?get('PROCESSOR_ARCHITECTURE'),
      'NUMBER_OF_PROCESSORS': ?get('NUMBER_OF_PROCESSORS'),
      'PATH':
          '$sysRoot\\System32;$sysRoot;$sysRoot\\System32\\Wbem;$sysRoot\\System32\\WindowsPowerShell\\v1.0',
      'TEMP': ?get('TEMP'),
      'TMP': ?get('TMP'),
      'USERPROFILE': ?get('USERPROFILE'),
      'APPDATA': ?get('APPDATA'),
      'LOCALAPPDATA': ?get('LOCALAPPDATA'),
      'COMSPEC': ?get('COMSPEC'),
    };
  }
  return <String, String>{
    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
    'HOME': ?get('HOME'),
    'TMPDIR': ?get('TMPDIR'),
    'DISPLAY': ?get('DISPLAY'),
    'WAYLAND_DISPLAY': ?get('WAYLAND_DISPLAY'),
    'XDG_RUNTIME_DIR': ?get('XDG_RUNTIME_DIR'),
  };
}

Future<({int code, Map<String, Object?>? report, String stderr})> _runtimeCheck(
  String cli,
  Map<String, String> env, {
  required bool hold,
}) async {
  final Process process = await Process.start(
    cli,
    <String>[
      '__runtime-check',
      if (hold) '--hold',
    ],
    environment: env,
    includeParentEnvironment: false,
  );
  final stderrText = StringBuffer();
  final Future<void> err = process.stderr
      .transform(utf8.decoder)
      .forEach(stderrText.write);
  final List<String> lines = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .toList();
  await process.stdin.close();
  final int code = await process.exitCode.timeout(const Duration(minutes: 3));
  await err;
  Map<String, Object?>? report;
  for (final String line in lines.reversed) {
    if (line.startsWith('{')) {
      report = jsonDecode(line) as Map<String, Object?>;
      break;
    }
  }
  return (code: code, report: report, stderr: stderrText.toString());
}

Future<
  ({List<int> pids, List<int> left, List<int> webview, List<int> webviewLeft})
>
_killMidSession(
  String cli,
  Map<String, String> env,
) async {
  final Set<int> webkitBefore = Platform.isMacOS
      ? (await _webkitProcesses()).toSet()
      : <int>{};
  final Process process = await Process.start(
    cli,
    <String>[
      '__runtime-check',
      '--hold',
    ],
    environment: env,
    includeParentEnvironment: false,
  );
  unawaited(process.stderr.drain<void>());
  final String line = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .firstWhere((String l) => l.startsWith('{'))
      .timeout(const Duration(minutes: 3));
  final List<int> pids = _pids(jsonDecode(line) as Map<String, Object?>);
  final List<int> webview = Platform.isWindows
      ? await _webviewChildren(pids)
      : Platform.isMacOS
      ? <int>[
          for (final int pid in await _webkitProcesses())
            if (!webkitBefore.contains(pid)) pid,
        ]
      : const <int>[];
  process.kill(ProcessSignal.sigkill);
  await process.exitCode;
  final List<int> left = await _waitGone(pids, const Duration(seconds: 60));
  final List<int> webviewLeft = await _waitGone(
    webview,
    const Duration(seconds: 120),
  );
  return (pids: pids, left: left, webview: webview, webviewLeft: webviewLeft);
}

List<int> _pids(Map<String, Object?>? report) => <int>[
  for (final String key in <String>['tachi', 'paperback', 'helper'])
    if ((report?[key] as Map<String, Object?>?)?['pid'] case final int pid) pid,
];

/// msedgewebview2 processes whose parent is one of [pids] (the helper).
Future<List<int>> _webviewChildren(List<int> pids) async {
  final ProcessResult r = await Process.run('powershell', <String>[
    '-NoProfile',
    '-Command',
    'Get-CimInstance Win32_Process -Filter "Name=\'msedgewebview2.exe\'" | ForEach-Object { "\$(\$_.ProcessId) \$(\$_.ParentProcessId)" }',
  ]);
  return <int>[
    for (final String l in (r.stdout as String).split('\n'))
      if (l.trim().split(' ') case [final String pid, final String parent]
          when pids.contains(int.tryParse(parent)))
        int.parse(pid),
  ];
}

/// WebKit's XPC service processes (WebContent, Networking, GPU). launchd
/// owns them, not the helper, so the ones that appeared while the helper ran
/// are taken as its own (another WebKit app starting meanwhile would add
/// noise, never hide a leftover).
Future<List<int>> _webkitProcesses() async {
  final ProcessResult r = await Process.run('ps', <String>[
    '-axo',
    'pid=,command=',
  ]);
  return <int>[
    for (final String l in (r.stdout as String).split('\n'))
      if (RegExp(
            r'^\s*(\d+)\s+\S*/com\.apple\.WebKit\.(WebContent|Networking|GPU)\b',
          ).firstMatch(l)
          case final RegExpMatch m)
        int.parse(m.group(1)!),
  ];
}

Future<List<int>> _waitGone(List<int> pids, Duration bound) async {
  final DateTime deadline = DateTime.now().add(bound);
  while (true) {
    final alive = <int>[
      for (final int pid in pids)
        if (_alive(pid)) pid,
    ];
    if (alive.isEmpty || DateTime.now().isAfter(deadline)) return alive;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

bool _alive(int pid) {
  if (Platform.isWindows) {
    final ProcessResult r = Process.runSync('tasklist', <String>[
      '/FI',
      'PID eq $pid',
      '/NH',
    ]);
    return (r.stdout as String).contains(' $pid ');
  }
  return Process.runSync('kill', <String>['-0', '$pid']).exitCode == 0;
}

/// Whether `openjdk version "X"` in [line] is at least [floor].
bool _atLeast(String line, String floor) {
  final RegExpMatch? m = RegExp('version "([0-9.]+)').firstMatch(line);
  if (m == null) return false;
  final List<int> have = m.group(1)!.split('.').map(int.parse).toList();
  final List<int> want = floor.split('.').map(int.parse).toList();
  for (var i = 0; i < want.length; i++) {
    final int h = i < have.length ? have[i] : 0;
    if (h != want[i]) return h > want[i];
  }
  return true;
}

/// [value] with the package path (as given and as resolved: macOS reports
/// `/private/var/...` for `/var/...`) replaced by `<package>`.
Object? _strip(Object? value, String pkg) {
  if (value == null) return null;
  String json = jsonEncode(value);
  final String resolved = Directory(pkg).resolveSymbolicLinksSync();
  for (final path in <String>{resolved, pkg}) {
    json = json.replaceAll(jsonEncode(path).replaceAll('"', ''), '<package>');
  }
  return jsonDecode(json);
}

String _tail(String text) =>
    text.length > 2000 ? text.substring(text.length - 2000) : text;

Future<void> _copyTree(Directory from, Directory to) async {
  if (!from.existsSync()) {
    throw StateError(
      'No package at ${from.path}; run scripts/package_cli.dart first',
    );
  }
  for (final FileSystemEntity e in from.listSync(recursive: true)) {
    final String target = p.join(to.path, p.relative(e.path, from: from.path));
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File) {
      Directory(p.dirname(target)).createSync(recursive: true);
      e.copySync(target);
    }
  }
}
