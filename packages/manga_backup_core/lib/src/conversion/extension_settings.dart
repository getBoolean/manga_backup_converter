import 'package:manga_backup_core/src/conversion/extension_entry.dart';
import 'package:source_runtime/source_contracts.dart';

/// The settings an extension runs with. Settings are always the user's:
/// hosts read them from the user (a settings file and flags in the CLI, an
/// injected provider in the app); the core never invents any.
typedef ExtensionSettingsProvider = SettingsSnapshot Function(ExtensionEntry entry);

/// No user settings: an empty snapshot for every extension.
SettingsSnapshot noExtensionSettings(ExtensionEntry entry) => SettingsSnapshot();

/// Whether [entry] hosts the runtime source [sourceId]: a Tachi package
/// lists its source IDs, a Paperback bundle has one catalog source ID, and an
/// Aidoku source's ID is its extension ID.
bool entryHostsSource(ExtensionEntry entry, String sourceId) => switch (entry) {
  TachiExtensionEntry(:final List<String> sourceIds) => sourceIds.contains(sourceId),
  PaperbackExtensionEntry(sourceId: final String id) => id == sourceId,
  _ => entry.id == sourceId,
};

/// User-supplied extension settings, keyed by extension ID ([ExtensionEntry.id]).
///
/// JSON shape (a settings file):
///
/// ```json
/// {
///   "extensions": {
///     "<extension id>": {
///       "values": {"key": "text" | true | 3 | ["a", "b"]},
///       "secrets": {"password": "…"},
///       "sources": {"<runtime source id>": {"values": {}, "secrets": {}}}
///     }
///   }
/// }
/// ```
///
/// Values are typed (string, bool, int, string set); secrets are strings and
/// stay in session memory only: [SettingsSnapshot] keeps them out of its JSON
/// and revision, so they never reach a journal or report.
final class UserExtensionSettings {
  UserExtensionSettings([Map<String, SettingsSnapshot> byExtension = const <String, SettingsSnapshot>{}])
    : _byExtension = Map<String, SettingsSnapshot>.of(byExtension);

  factory UserExtensionSettings.fromJson(Map<String, Object?> json) {
    final Object? extensions = json['extensions'];
    if (extensions is! Map<String, Object?>) {
      throw const FormatException('A settings file needs an "extensions" object keyed by extension ID');
    }
    return UserExtensionSettings(<String, SettingsSnapshot>{
      for (final MapEntry<String, Object?> e in extensions.entries) e.key: _snapshot(e.key, e.value),
    });
  }

  final Map<String, SettingsSnapshot> _byExtension;

  static SettingsSnapshot _snapshot(String id, Object? json) {
    if (json is! Map<String, Object?>) throw FormatException('Settings for "$id" must be an object');
    final Object? sources = json['sources'];
    if (sources != null && sources is! Map<String, Object?>) {
      throw FormatException('"sources" of "$id" must be an object keyed by source ID');
    }
    return SettingsSnapshot(
      values: _values(id, json['values']),
      secrets: _secrets(id, json['secrets']),
      sources: <String, SourceScopedSettings>{
        for (final MapEntry<String, Object?> s in (sources as Map<String, Object?>?)?.entries ?? const [])
          s.key: switch (s.value) {
            final Map<String, Object?> scope => SourceScopedSettings(
              values: _values('$id/${s.key}', scope['values']),
              secrets: _secrets('$id/${s.key}', scope['secrets']),
            ),
            _ => throw FormatException('Source settings "$id/${s.key}" must be an object'),
          },
      },
    );
  }

  static Map<String, Object> _values(String where, Object? json) => switch (json) {
    null => const <String, Object>{},
    final Map<String, Object?> map => SettingsSnapshot.valuesFromJson(map),
    _ => throw FormatException('"values" of "$where" must be an object'),
  };

  static Map<String, String> _secrets(String where, Object? json) => switch (json) {
    null => const <String, String>{},
    final Map<String, Object?> map => <String, String>{
      for (final MapEntry<String, Object?> e in map.entries)
        e.key: switch (e.value) {
          final String s => s,
          _ => throw FormatException('Secret "$where/${e.key}" must be a string'),
        },
    },
    _ => throw FormatException('"secrets" of "$where" must be an object'),
  };

  /// Parses a `--setting EXTENSION_ID=KEY=VALUE` value (non-secret; `true`,
  /// `false` and integers are typed, anything else is a string) and returns
  /// a copy with it applied over this one.
  UserExtensionSettings withFlag(String flag) {
    final int first = flag.indexOf('=');
    final int second = first < 0 ? -1 : flag.indexOf('=', first + 1);
    if (first <= 0 || second <= first + 1) {
      throw FormatException('Expected EXTENSION_ID=KEY=VALUE, got "$flag"');
    }
    final String id = flag.substring(0, first);
    final String key = flag.substring(first + 1, second);
    final String raw = flag.substring(second + 1);
    final Object value = switch (raw) {
      'true' => true,
      'false' => false,
      _ => int.tryParse(raw) ?? raw,
    };
    final SettingsSnapshot current = _byExtension[id] ?? SettingsSnapshot();
    return UserExtensionSettings(<String, SettingsSnapshot>{
      ..._byExtension,
      id: SettingsSnapshot(
        values: <String, Object>{...current.values, key: value},
        secrets: current.secrets,
        sources: current.sources,
      ),
    });
  }

  /// The extension IDs with settings (for warning about unknown IDs).
  Iterable<String> get extensionIds => _byExtension.keys;

  /// The user's settings for [entry], empty when there are none.
  SettingsSnapshot snapshotFor(ExtensionEntry entry) => _byExtension[entry.id] ?? SettingsSnapshot();

  ExtensionSettingsProvider get provider => snapshotFor;
}

/// [user] over an ecosystem's own [defaults] (for example an Aidoku
/// repository's base URL): the user's values win, secrets and source scopes
/// are the user's.
SettingsSnapshot withDefaults(SettingsSnapshot user, Map<String, Object> defaults) => defaults.isEmpty
    ? user
    : SettingsSnapshot(
        values: <String, Object>{...defaults, ...user.values},
        secrets: user.secrets,
        sources: user.sources,
        revisionAllowlist: user.revisionAllowlist,
      );
