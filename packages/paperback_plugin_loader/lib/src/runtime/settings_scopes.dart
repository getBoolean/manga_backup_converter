import 'package:source_runtime/source_runtime.dart';

/// Effective per-source settings of a protocol 1.1 [SettingsPayload], for
/// Paperback adapters (U6) that store a source's settings.
///
/// A string-set value arrives as a sorted, deduplicated `List<String>`; a
/// source's scope overrides the package-wide entry with the same key.
extension PaperbackSourceSettings on SettingsPayload {
  /// Package-wide values overlaid with [sourceId]'s scoped values.
  Map<String, Object> valuesFor(String sourceId) => <String, Object>{...values, ...?sources[sourceId]?.values};

  /// Package-wide secrets overlaid with [sourceId]'s scoped secrets.
  Map<String, String> secretsFor(String sourceId) => <String, String>{...secrets, ...?sources[sourceId]?.secrets};
}
