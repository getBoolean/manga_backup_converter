/// The third-party notices asset that `scripts/generate_notices.dart`
/// writes for each app build (Android, iOS): every shipped library with its
/// full licence texts, identical texts stored once. The platform packages
/// register each component on the app's licence page.
library;

import 'dart:convert';

/// One shipped library and the full text of its licence and notice files.
final class ThirdPartyNotice {
  const ThirdPartyNotice({required this.id, required this.name, required this.license, required this.texts});

  /// Stable identity: `maven:<group>:<artifact>:<version>`,
  /// `crate:<name>@<version>` or `vendored:<key>`.
  final String id;

  /// Display name, with the version when there is one.
  final String name;

  /// The declared licence, an SPDX expression where one is known.
  final String license;

  /// The full licence and notice texts, in order.
  final List<String> texts;

  /// [texts] joined for display.
  String get text => texts.join('\n\n');
}

/// Parses the notices asset. Throws [FormatException] when the format is not
/// version 1, or a component names a text the asset does not hold or has no
/// text at all.
List<ThirdPartyNotice> parseThirdPartyNotices(String source) {
  final Object? decoded = jsonDecode(source);
  if (decoded is! Map<String, Object?> || decoded['format'] != 1) {
    throw const FormatException('not a version 1 third-party notices asset');
  }
  final Map<String, Object?> texts = (decoded['texts'] as Map<String, Object?>?) ?? const <String, Object?>{};
  return <ThirdPartyNotice>[
    for (final Object? entry in (decoded['components'] as List<Object?>?) ?? const <Object?>[])
      switch (entry) {
        {'id': final String id, 'name': final String name, 'texts': final List<Object?> keys} when keys.isNotEmpty =>
          ThirdPartyNotice(
            id: id,
            name: name,
            license: entry['license'] as String? ?? '',
            texts: <String>[
              for (final Object? key in keys)
                texts[key] as String? ?? (throw FormatException('$id names missing text $key')),
            ],
          ),
        _ => throw FormatException('component without a licence text: $entry'),
      },
  ];
}
