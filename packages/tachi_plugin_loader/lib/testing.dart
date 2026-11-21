/// Test support for Tachi loading: committed captures served through
/// [TachiFetch], and the development worker located for tests. Never import
/// this from production code.
///
/// Every byte comes from `fixtures/source_captures/tachi/`; any URL without a
/// committed response throws, so no test can reach a server.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';

/// The keiyoushi repository as the committed captures record it.
final Uri keiyoushiRepository = Uri.parse('https://raw.githubusercontent.com/keiyoushi/extensions/repo');

/// keiyoushi's published signing certificate SHA-256 (the qualification pin
/// recorded in every capture's `artifact.json`/`desktop-artifacts.json`).
const String keiyoushiFingerprint = '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2';

/// The committed Tachi capture directories.
const List<String> tachiCaptureSources = <String>['all.mangadex', 'en.weebcentral', 'all.mangafire'];

/// The repository root: the first ancestor of [from] holding
/// `fixtures/source_captures/tachi`.
Directory repositoryRoot([Directory? from]) {
  Directory dir = (from ?? Directory.current).absolute;
  while (true) {
    if (Directory(p.join(dir.path, 'fixtures', 'source_captures', 'tachi')).existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) throw StateError('Repository root not found from ${Directory.current.path}');
    dir = parent;
  }
}

/// One committed capture: artifacts, index entry and recorded site responses.
final class TachiCapture {
  TachiCapture(this.directory);

  final Directory directory;

  String get source => p.basename(directory.path);

  Map<String, Object?> get _artifacts =>
      jsonDecode(File(p.join(directory.path, 'desktop-artifacts.json')).readAsStringSync()) as Map<String, Object?>;

  /// The repository index entry exactly as captured.
  Map<String, Object?> get indexEntry =>
      jsonDecode(File(p.join(directory.path, 'index-entry.json')).readAsStringSync()) as Map<String, Object?>;

  String get packageId => indexEntry['packageName']! as String;

  Map<String, Object?> _artifact(TachiArtifactKind kind) => <Map<String, Object?>>[
    for (final Object? a in _artifacts['artifacts']! as List<Object?>) a! as Map<String, Object?>,
  ].firstWhere((Map<String, Object?> a) => a['kind'] == kind.name);

  /// The published URL of the artifact of [kind].
  Uri urlOf(TachiArtifactKind kind) => Uri.parse(_artifact(kind)['sourceUrl']! as String);

  /// The committed bytes of the artifact of [kind].
  Uint8List bytesOf(TachiArtifactKind kind) =>
      File(p.join(directory.path, _artifact(kind)['path']! as String)).readAsBytesSync();

  /// The recorded SHA-256 of the artifact of [kind].
  String sha256Of(TachiArtifactKind kind) => _artifact(kind)['sha256']! as String;
}

/// The committed captures under [root].
List<TachiCapture> tachiCaptures([Directory? root]) => <TachiCapture>[
  for (final String s in tachiCaptureSources)
    TachiCapture(Directory(p.join((root ?? repositoryRoot()).path, 'fixtures', 'source_captures', 'tachi', s))),
];

/// A repository served from fixtures: a synthetic `repo.json` and an
/// `index.json` assembled verbatim from captured index entries.
final class FixtureRepository {
  FixtureRepository({
    required this.baseUrl,
    required this.captures,
    this.fingerprint = keiyoushiFingerprint,
    this.name = 'Keiyoushi',
    this.entryOverrides = const <String, Map<String, Object?>>{},
  });

  final Uri baseUrl;
  final List<TachiCapture> captures;

  /// Published `signingKeyFingerprint`.
  String fingerprint;
  final String name;

  /// Fields replaced in a package's index entry, by package ID.
  final Map<String, Map<String, Object?>> entryOverrides;

  /// `repo.json`. Synthetic: no `repo.json` is committed; its shape
  /// (`{"meta": {name, shortName, website, signingKeyFingerprint}}`) follows
  /// the plan's description of keiyoushi's file.
  Map<String, Object?> get repoJson => <String, Object?>{
    'meta': <String, Object?>{
      'name': name,
      'shortName': name.toLowerCase(),
      'website': 'https://keiyoushi.github.io',
      'signingKeyFingerprint': fingerprint,
    },
  };

  /// `index.json`: the captured entries, in capture order.
  List<Object?> get indexJson => <Object?>[
    for (final TachiCapture c in captures) <String, Object?>{...c.indexEntry, ...?entryOverrides[c.packageId]},
  ];

  /// A stale `index.min.json` stub (synthetic): an old-format list naming a
  /// package that is not in the live index, so a parser that read it would
  /// list the wrong packages.
  List<Object?> get staleIndexMin => <Object?>[
    <String, Object?>{
      'name': 'Tachiyomi: Stale',
      'pkg': 'eu.kanade.tachiyomi.extension.en.stale',
      'apk': 'tachiyomi-en.stale-v1.4.1.apk',
      'lang': 'en',
      'code': 1,
      'version': '1.4.1',
      'nsfw': 0,
    },
  ];
}

/// Serves [repositories] and their artifacts; counts every request. Any
/// other URL throws (no server is ever contacted).
final class FixtureFetch {
  FixtureFetch(this.repositories, {Map<Uri, Uint8List>? overrides})
    : overrides = overrides ?? <Uri, Uint8List>{};

  final List<FixtureRepository> repositories;

  /// Bytes served instead of the committed ones (tampering, replaced URLs).
  final Map<Uri, Uint8List> overrides;

  /// Every requested URL, in order.
  final List<Uri> requests = <Uri>[];

  int countOf(Uri url) => requests.where((Uri u) => u == url).length;

  Future<Uint8List> call(Uri url) async {
    requests.add(url);
    if (overrides[url] case final Uint8List bytes) return bytes;
    for (final FixtureRepository repo in repositories) {
      final base = repo.baseUrl.toString();
      Uint8List json(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));
      if (url.toString() == '$base/repo.json') return json(repo.repoJson);
      if (url.toString() == '$base/index.json') return json(repo.indexJson);
      if (url.toString() == '$base/index.min.json') return json(repo.staleIndexMin);
      for (final TachiCapture c in repo.captures) {
        for (final TachiArtifactKind kind in TachiArtifactKind.values) {
          if (c.urlOf(kind) == url) return c.bytesOf(kind);
        }
      }
    }
    throw StateError('No fixture for $url (tests never contact a server)');
  }
}

/// The Java executable for worker tests: `TACHI_JAVA_HOME`, the documented
/// Corretto install, then `JAVA_HOME` (which may name a JDK below the
/// worker's floor, so it comes last).
String? testJavaHome() {
  final exe = Platform.isWindows ? 'java.exe' : 'java';
  for (final home in <String?>[
    Platform.environment['TACHI_JAVA_HOME'],
    if (Platform.isWindows) r'C:\Program Files\Amazon Corretto\jdk21.0.13_1',
    Platform.environment['JAVA_HOME'],
  ]) {
    if (home != null && File(p.join(home, 'bin', exe)).existsSync()) return home;
  }
  return null;
}

/// Handshake deadline used by tests (KTD25 lets tests choose explicit
/// values; production configuration must supply its own).
const Duration testHandshakeDeadline = Duration(minutes: 1);

/// The development worker for tests, or a skip reason.
({TachiWorkerLocation? location, String? skip}) testWorkerLocation() {
  final String? home = testJavaHome();
  if (home == null) return (location: null, skip: 'No Java 21 (set TACHI_JAVA_HOME or JAVA_HOME)');
  final SourceOutcome<TachiWorkerLocation> resolved = TachiWorkerLocation.resolve(
    javaHome: home,
    handshakeDeadline: testHandshakeDeadline,
    searchFrom: repositoryRoot(),
  );
  return switch (resolved) {
    SourceSuccess<TachiWorkerLocation>(:final TachiWorkerLocation value) => (location: value, skip: null),
    SourceFailed<TachiWorkerLocation>(:final SourceFailure failure) => (
      location: null,
      skip: '${failure.message} (run ./gradlew installDist in tools/tachi-source-runner)',
    ),
  };
}

/// Counts worker launches, to prove a conversion starts exactly one JVM.
final class CountingLauncher {
  int launches = 0;

  Future<WorkerProcess> call(WorkerSpec spec) {
    launches++;
    return launchWorkerProcess(spec);
  }
}

/// A conversion scope whose JVM worker replays every committed capture.
ConversionRuntimeScope replayScope(
  TachiWorkerLocation location, {
  required Directory state,
  WorkerLauncher? launcher,
  void Function(String line)? onLog,
}) => ConversionRuntimeScope(
  workers: <WorkerKind, WorkerSpec>{
    WorkerKind.jvm: location.spec(
      stateDirectory: state.path,
      browser: false,
      replay: <String>[for (final TachiCapture c in tachiCaptures()) c.directory.path],
    ),
  },
  limits: location.limits,
  launcher: launcher,
  onLog: onLog,
);
