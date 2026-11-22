// Third-party licence texts for every shipped library, shared by the desktop
// package (scripts/package_cli.dart) and the app notices
// (scripts/generate_notices.dart, Android and iOS).
//
// Sources, by kind:
//   - Rust crates: `cargo metadata --locked --filter-platform <triple>`; each
//     crate's published licence files, or, for a crate that publishes none,
//     the canonical text of each licence in its SPDX expression
//     (scripts/licenses/<id>.txt; MIT with the crate's authors as holders).
//   - Maven artifacts (Gradle lockfile coordinates): the licence and notice
//     files inside the artifact (JAR, or AAR and its classes.jar), else the
//     canonical text of the licence its POM (or parent POM) declares when that
//     text names no holder (Apache-2.0), else an override from
//     scripts/licenses/components.json (an upstream LICENSE with its real
//     copyright line, committed with its URL and SHA-256).
//   - Vendored components (native code not described by a package manager):
//     the licence files listed in components.json.
// Everything fails closed: a component with no text is an error.

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// One licence or notice file of a component.
class LicenseText {
  LicenseText(this.fileName, this.content, {this.source});

  /// The file's name where it came from (`LICENSE-MIT`, `META-INF/LICENSE`).
  final String fileName;
  final String content;

  /// The file on disk the text was read from verbatim, when there is one
  /// (copied byte for byte into the desktop package).
  final File? source;
}

/// One shipped third-party component and its licence texts.
class Component {
  Component({
    required this.id,
    required this.name,
    required this.version,
    required this.license,
    required this.texts,
    required this.origin,
  });

  /// Stable identity: `crate:<name>@<version>`, `maven:<group>:<artifact>:<version>`
  /// or `vendored:<key>`.
  final String id;
  final String name;
  final String version;

  /// The declared licence (an SPDX expression where one is known).
  final String license;
  final List<LicenseText> texts;

  /// Where the texts came from, for the generated listing.
  final String origin;
}

/// Licence and notice files a crate or artifact publishes (`LICENSE-MIT`,
/// `COPYING`, `NOTICE.txt`, ...).
final RegExp licenseFileName = RegExp(
  r'^(licen[cs]e|copying|notice|unlicense|copyright)([-._].*)?$',
  caseSensitive: false,
);

String _canonical(String root, String id) =>
    p.join(root, 'scripts', 'licenses', '$id.txt');

/// The crates of [manifest]'s tree linked for any of [triples], with their
/// licence texts. Crates under [ownCrates] (directory prefix -> licence file)
/// get that file (this repository's crates get its LICENSE.md).
Future<List<Component>> rustComponents({
  required String root,
  required String manifest,
  required List<String> triples,
  Map<String, String> ownCrates = const <String, String>{},
}) async {
  final packages = <String, Map<String, Object?>>{};
  for (final triple in triples) {
    final ProcessResult r = await Process.run('cargo', <String>[
      'metadata',
      '--locked',
      '--format-version',
      '1',
      '--filter-platform',
      triple,
      '--manifest-path',
      manifest,
    ]);
    if (r.exitCode != 0) {
      throw StateError(
        'cargo metadata failed for $manifest ($triple): ${r.stderr}',
      );
    }
    final meta = jsonDecode(r.stdout as String) as Map<String, Object?>;
    final linked = <String>{
      for (final Object? n
          in (meta['resolve']! as Map<String, Object?>)['nodes']!
              as List<Object?>)
        (n! as Map<String, Object?>)['id']! as String,
    };
    for (final Map<String, Object?> pkg
        in (meta['packages']! as List<Object?>).cast<Map<String, Object?>>()) {
      if (linked.contains(pkg['id'])) {
        packages['${pkg['name']} ${pkg['version']}'] = pkg;
      }
    }
  }
  final owned = <String, String>{
    p.join(root, 'packages'): p.join(root, 'LICENSE.md'),
    ...ownCrates,
  };
  final result = <Component>[];
  for (final String key in packages.keys.toList()..sort()) {
    final Map<String, Object?> pkg = packages[key]!;
    final name = pkg['name']! as String;
    final version = pkg['version']! as String;
    final declared = pkg['license'] as String?;
    final String crateDir = p.dirname(pkg['manifest_path']! as String);
    final published =
        <File>[
          for (final FileSystemEntity e in Directory(crateDir).listSync())
            if (e is File && licenseFileName.hasMatch(p.basename(e.path))) e,
        ]..sort(
          (File a, File b) => p.basename(a.path).compareTo(p.basename(b.path)),
        );
    final String? ownLicense = owned.entries
        .where(
          (MapEntry<String, String> e) =>
              p.equals(e.key, crateDir) || p.isWithin(e.key, crateDir),
        )
        .map((MapEntry<String, String> e) => e.value)
        .firstOrNull;
    final List<LicenseText> texts;
    final String how;
    if (ownLicense != null) {
      texts = <LicenseText>[
        LicenseText(
          p.basename(ownLicense),
          _readText(File(ownLicense)),
          source: File(ownLicense),
        ),
      ];
      how = ownLicense == p.join(root, 'LICENSE.md')
          ? "this repository's LICENSE.md"
          : 'its package licence';
    } else if (published.isNotEmpty) {
      texts = <LicenseText>[
        for (final f in published)
          LicenseText(p.basename(f.path), _readText(f), source: f),
      ];
      how = published.map((File f) => p.basename(f.path)).join(', ');
    } else {
      final List<String> ids = licencesToShip(root, declared, name, version);
      final String authors =
          (pkg['authors'] as List<Object?>? ?? const <Object?>[])
              .map((Object? a) => '$a'.replaceAll(RegExp(r'\s*<[^>]*>'), ''))
              .join(', ');
      texts = <LicenseText>[
        for (final id in ids)
          LicenseText(
            'LICENSE-$id',
            File(
              _canonical(root, id),
            ).readAsStringSync().replaceAll(
              '{{holders}}',
              authors.isEmpty ? 'the $name authors' : authors,
            ),
          ),
      ];
      how =
          'canonical ${ids.join(', ')} text (the crate publishes no licence file)';
    }
    result.add(
      Component(
        id: 'crate:$name@$version',
        name: name,
        version: version,
        license: declared ?? 'UNDECLARED',
        texts: texts,
        origin: how,
      ),
    );
  }
  return result;
}

/// The licences whose canonical texts ship for a crate that publishes no
/// licence file: every `AND` term of its SPDX expression, and for each term
/// that offers a choice (`OR`, or Cargo's older `/`) the first option with a
/// text in `scripts/licenses/` (the recipient may take any one). Fails when a
/// term has no option with a text.
List<String> licencesToShip(
  String root,
  String? declared,
  String name,
  String version,
) {
  final String expression = (declared ?? '').replaceAll(RegExp('[()]'), ' ');
  final terms = <String>[
    for (final String t in expression.split(RegExp(r'\s+AND\s+')))
      if (t.trim().isNotEmpty) t.trim(),
  ];
  if (terms.isEmpty) {
    throw StateError(
      '$name $version declares no licence and publishes no licence file',
    );
  }
  bool hasText(String id) => File(_canonical(root, id)).existsSync();
  return <String>[
    for (final String term in terms)
      <String>[
        for (final String option in term.split(RegExp(r'\s*(?:/|\bOR\b)\s*')))
          if (option.trim().isNotEmpty) option.trim(),
      ].firstWhere(
        hasText,
        orElse: () => throw StateError(
          '$name $version: no canonical text in scripts/licenses/ for any of "$term"',
        ),
      ),
  ];
}

/// What Gradle resolved for one configuration
/// (scripts/licenses/license-inputs.gradle): each external module's POM and
/// artifact files, and every POM read (parents included).
class GradleInputs {
  GradleInputs(this.modules, this.poms);

  factory GradleInputs.fromJson(Map<String, Object?> json) {
    final modules = json['modules']! as Map<String, Object?>;
    return GradleInputs(
      <String, (String?, List<String>)>{
        for (final MapEntry<String, Object?> e in modules.entries)
          e.key: (
            (e.value! as Map<String, Object?>)['pom'] as String?,
            ((e.value! as Map<String, Object?>)['files']! as List<Object?>)
                .cast<String>(),
          ),
      },
      (json['poms']! as Map<String, Object?>).cast<String, String>(),
    );
  }

  /// `group:artifact:version` -> (POM path, artifact files).
  final Map<String, (String?, List<String>)> modules;

  /// `group:artifact:version` -> POM path, parents included.
  final Map<String, String> poms;

  /// The shipped coordinates: every module except platform BOMs (`*-bom`,
  /// no code) and [exclude]d `group:artifact`s (`group:*` for a group).
  List<String> coordinates({Set<String> exclude = const <String>{}}) =>
      <String>[
        for (final String c in modules.keys)
          if (c.split(':') case [final String g, final String a, _])
            if (!a.endsWith('-bom') &&
                !exclude.contains('$g:$a') &&
                !exclude.contains('$g:*'))
              c,
      ]..sort();
}

/// Runs scripts/licenses/license-inputs.gradle in the Gradle build at
/// [buildDir] for [task]'s project and [configuration].
Future<GradleInputs> resolveGradleInputs({
  required String root,
  required String buildDir,
  required String task,
  required String configuration,
  required String output,
}) async {
  final String wrapper = p.join(
    buildDir,
    Platform.isWindows ? 'gradlew.bat' : 'gradlew',
  );
  if (!File(wrapper).existsSync()) {
    throw StateError(
      '$wrapper not found (for android/, run flutter build apk first)',
    );
  }
  final ProcessResult r = await Process.run(
    wrapper,
    <String>[
      '-q',
      '--no-configuration-cache',
      '-I',
      p.join(root, 'scripts', 'licenses', 'license-inputs.gradle'),
      '-PlicenseConfiguration=$configuration',
      '-PlicenseOutput=$output',
      task,
    ],
    workingDirectory: buildDir,
    runInShell: Platform.isWindows,
  );
  if (r.exitCode != 0) {
    throw StateError('$wrapper $task failed:\n${r.stdout}\n${r.stderr}');
  }
  return GradleInputs.fromJson(
    jsonDecode(File(output).readAsStringSync()) as Map<String, Object?>,
  );
}

/// Declared licences of a POM (following `<parent>` while none is declared),
/// as (name, url) pairs.
List<(String, String)> _pomLicenses(GradleInputs inputs, String? pomPath) {
  if (pomPath == null) return const <(String, String)>[];
  final String xml = File(pomPath).readAsStringSync();
  String tag(String body, String name) =>
      RegExp(
        '<$name>\\s*([^<]*?)\\s*</$name>',
        dotAll: true,
      ).firstMatch(body)?.group(1) ??
      '';
  final declared = <(String, String)>[
    for (final RegExpMatch m in RegExp(
      '<license>(.*?)</license>',
      dotAll: true,
    ).allMatches(xml))
      (tag(m.group(1)!, 'name'), tag(m.group(1)!, 'url')),
  ];
  if (declared.isNotEmpty) return declared;
  final String? parent = RegExp(
    '<parent>(.*?)</parent>',
    dotAll: true,
  ).firstMatch(xml)?.group(1);
  if (parent == null) return const <(String, String)>[];
  return _pomLicenses(
    inputs,
    inputs
        .poms['${tag(parent, 'groupId')}:${tag(parent, 'artifactId')}:${tag(parent, 'version')}'],
  );
}

/// The SPDX id of a POM licence, or null when it is not recognised.
String? spdxOfPomLicense(String name, String url) {
  final String s = '$name $url'.toLowerCase();
  if (s.contains('apache') &&
      (s.contains('2.0') || s.contains('license-2.0'))) {
    return 'Apache-2.0';
  }
  if (RegExp(r'\bmit\b').hasMatch(s) || s.contains('licenses/mit')) {
    return 'MIT';
  }
  if (s.contains('bsd') &&
      (s.contains('3') || s.contains('new') || s.contains('revised'))) {
    return 'BSD-3-Clause';
  }
  return null;
}

/// Licences whose canonical text names no copyright holder, so it can stand
/// in for an artifact that ships no licence file.
const Set<String> holderFreeLicences = <String>{'Apache-2.0', 'MPL-2.0'};

/// Licence and notice files inside a JAR or AAR (and an AAR's classes.jar).
List<LicenseText> _artifactLicenseFiles(List<int> bytes, {String prefix = ''}) {
  final Archive zip = ZipDecoder().decodeBytes(bytes);
  final result = <LicenseText>[];
  for (final ArchiveFile f in zip.files) {
    if (!f.isFile) continue;
    final String base = f.name.split('/').last;
    if (base.endsWith('.class')) continue;
    if (licenseFileName.hasMatch(base)) {
      result.add(
        LicenseText(
          '$prefix${f.name}',
          utf8.decode(f.content, allowMalformed: true),
        ),
      );
    } else if (prefix.isEmpty &&
        (f.name == 'classes.jar' ||
            (f.name.startsWith('libs/') && base.endsWith('.jar')))) {
      result.addAll(_artifactLicenseFiles(f.content, prefix: '${f.name}!/'));
    }
  }
  return result
    ..sort((LicenseText a, LicenseText b) => a.fileName.compareTo(b.fileName));
}

/// A Maven override from components.json: the licence and the committed
/// texts of an artifact whose POM declares no licence or that ships no
/// licence file for a licence naming its holders.
class MavenOverride {
  MavenOverride(this.license, this.texts, this.reason);
  final String license;
  final List<String> texts;
  final String reason;
}

/// The components for Maven [coordinates], from what Gradle resolved for
/// them ([inputs]).
List<Component> mavenComponents({
  required String root,
  required List<String> coordinates,
  required GradleInputs inputs,
  required Map<String, MavenOverride> overrides,
}) {
  final result = <Component>[];
  final missing = <String>[];
  for (final coords in coordinates) {
    final [String group, String artifact, String version] = coords.split(':');
    final (String? pomPath, List<String> files) =
        inputs.modules[coords] ?? (null, const <String>[]);
    final embedded = <LicenseText>[
      for (final String f in files)
        if (f.endsWith('.jar') || f.endsWith('.aar'))
          ..._artifactLicenseFiles(File(f).readAsBytesSync()),
    ];
    final MavenOverride? override =
        overrides[coords] ??
        overrides['$group:$artifact'] ??
        overrides['$group:*'];
    final List<(String, String)> pom = _pomLicenses(inputs, pomPath);
    final List<String?> spdx = pom
        .map(((String, String) l) => spdxOfPomLicense(l.$1, l.$2))
        .toList();
    final String license =
        override?.license ??
        (spdx.isEmpty ? 'UNDECLARED' : spdx.map((s) => s ?? '?').join(' OR '));
    final texts = <LicenseText>[...embedded];
    final String origin;
    if (override != null && override.texts.isNotEmpty) {
      texts.addAll(<LicenseText>[
        for (final t in override.texts)
          LicenseText(p.basename(t), File(p.join(root, t)).readAsStringSync()),
      ]);
      origin = embedded.isEmpty
          ? 'upstream licence (${override.reason})'
          : '${embedded.map((LicenseText t) => t.fileName).join(', ')} and upstream licence (${override.reason})';
    } else if (embedded.any(
      (LicenseText t) => t.fileName.toLowerCase().contains('licen'),
    )) {
      origin = embedded.map((LicenseText t) => t.fileName).join(', ');
    } else if (spdx.isNotEmpty &&
        spdx.every(
          (String? s) => s != null && holderFreeLicences.contains(s),
        )) {
      // Every declared licence's canonical text names no holder; one suffices
      // when the POM offers a choice.
      texts.add(
        LicenseText(
          'LICENSE-${spdx.first}',
          File(_canonical(root, spdx.first!)).readAsStringSync(),
        ),
      );
      origin = embedded.isEmpty
          ? 'canonical ${spdx.first} text (POM-declared; the artifact ships no licence file)'
          : '${embedded.map((LicenseText t) => t.fileName).join(', ')} and canonical ${spdx.first} text (POM-declared)';
    } else {
      missing.add(
        '$coords: ${pom.isEmpty ? 'no POM licence' : 'POM licence ${pom.map(((String, String) l) => l.$1).join(', ')}'}'
        ' and no licence file in the artifact; add an upstream LICENSE override to scripts/licenses/components.json',
      );
      continue;
    }
    result.add(
      Component(
        id: 'maven:$coords',
        name: '$group:$artifact',
        version: version,
        license: license,
        texts: texts,
        origin: origin,
      ),
    );
  }
  if (missing.isNotEmpty) {
    throw StateError(
      'Maven artifacts without licence text:\n  ${missing.join('\n  ')}',
    );
  }
  return result;
}

/// The parsed scripts/licenses/components.json.
class NoticesConfig {
  NoticesConfig(this.root, this.json);

  factory NoticesConfig.load(String root) => NoticesConfig(
    root,
    jsonDecode(
      File(p.join(root, 'scripts', 'licenses', 'components.json'))
          .readAsStringSync(),
    ) as Map<String, Object?>,
  );

  final String root;
  final Map<String, Object?> json;

  Map<String, Object?> _map(String key) =>
      (json[key] ?? const <String, Object?>{}) as Map<String, Object?>;

  Map<String, Object?> target(String name) =>
      _map('targets')[name] as Map<String, Object?>? ??
      (throw StateError('No target "$name" in components.json'));

  Map<String, MavenOverride> get mavenOverrides => <String, MavenOverride>{
    for (final MapEntry<String, Object?> e in _map('maven').entries)
      e.key: () {
        final o = e.value! as Map<String, Object?>;
        return MavenOverride(
          o['license']! as String,
          (o['texts'] as List<Object?>? ?? const <Object?>[]).cast<String>(),
          o['reason']! as String,
        );
      }(),
  };

  /// Fails when a committed upstream text differs from its recorded SHA-256.
  void verifyUpstreamTexts() {
    for (final MapEntry<String, Object?> e in _map('upstream').entries) {
      final file = File(p.join(root, e.key));
      final want = (e.value! as Map<String, Object?>)['sha256']! as String;
      final got = sha256.convert(file.readAsBytesSync()).toString();
      if (got != want) {
        throw StateError(
          '${e.key}: SHA-256 $got != recorded $want (components.json "upstream")',
        );
      }
    }
  }

  List<Component> vendored(List<String> keys) => <Component>[
    for (final key in keys)
      () {
        final Map<String, Object?> o =
            _map('vendored')[key] as Map<String, Object?>? ??
            (throw StateError('No vendored component "$key"'));
        final List<String> files = (o['texts']! as List<Object?>)
            .cast<String>();
        return Component(
          id: 'vendored:$key',
          name: o['name']! as String,
          version: o['version'] as String? ?? '',
          license: o['license']! as String,
          texts: <LicenseText>[
            for (final f in files)
              LicenseText(
                p.basename(f),
                File(p.join(root, f)).readAsStringSync(),
              ),
          ],
          origin: o['origin']! as String,
        );
      }(),
  ];
}

/// The notices asset: components, each naming its texts by content hash
/// (identical texts are stored once).
String encodeNotices(String target, List<Component> components) {
  final texts = <String, String>{};
  final entries = <Map<String, Object?>>[];
  for (final c in components) {
    if (c.texts.isEmpty ||
        c.texts.every((LicenseText t) => t.content.trim().isEmpty)) {
      throw StateError('${c.id} has no licence text');
    }
    final keys = <String>[];
    for (final LicenseText t in c.texts) {
      final String content = t.content.replaceAll('\r\n', '\n');
      final String key = sha256
          .convert(utf8.encode(content))
          .toString()
          .substring(0, 16);
      texts[key] = content;
      if (!keys.contains(key)) keys.add(key);
    }
    entries.add(<String, Object?>{
      'id': c.id,
      'name': c.version.isEmpty ? c.name : '${c.name} ${c.version}',
      'license': c.license,
      'origin': c.origin,
      'files': <String>[for (final LicenseText t in c.texts) t.fileName],
      'texts': keys,
    });
  }
  entries.sort(
    (Map<String, Object?> a, Map<String, Object?> b) =>
        (a['id']! as String).compareTo(b['id']! as String),
  );
  final List<String> textKeys = texts.keys.toList()..sort();
  return '${const JsonEncoder.withIndent(' ').convert(<String, Object?>{
    'format': 1,
    'target': target,
    'generatedBy': 'scripts/generate_notices.dart $target (do not edit)',
    'components': entries,
    'texts': <String, String>{for (final k in textKeys) k: texts[k]!},
  })}\n';
}

/// A published licence file as text; a file that is not valid UTF-8 (an old
/// Latin-1 notice) keeps its readable parts instead of failing the build.
String _readText(File f) =>
    utf8.decode(f.readAsBytesSync(), allowMalformed: true);
