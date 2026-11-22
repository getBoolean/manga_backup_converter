import 'dart:typed_data';

import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:meta/meta.dart';
import 'package:source_runtime/source_contracts.dart';

/// Plugin bytes kept between conversions (the CLI's on-disk cache). Only
/// bytes that loaded are put; cached bytes that no longer load are removed.
abstract interface class PluginByteCache {
  Uint8List? get(ExtensionEntry entry);
  void put(ExtensionEntry entry, Uint8List bytes);
  void remove(ExtensionEntry entry);
}

/// A [PluginLoader] over one ecosystem's `SourceProvider` (KTD15): it owns
/// the load loop, the byte cache, settings and owner adoption; each
/// ecosystem supplies how it lists ([fetchExtensionLists]), [download]s and
/// [open]s an entry of type [E].
///
/// For each extension the loop reads the [cache] first, otherwise downloads;
/// loads the bytes ([loadPluginFromBytes]); caches downloaded bytes only
/// after they loaded, and drops cached bytes that no longer load (they are
/// not downloaded again in the same run). Failures are typed, reported
/// through `onFailure`, and never stop the remaining extensions.
abstract class ProviderPluginLoader<E extends ExtensionEntry> extends PluginLoader {
  ProviderPluginLoader({this.settingsFor = noExtensionSettings, this.onSettings, this.cache});

  /// The user's settings for each extension.
  final ExtensionSettingsProvider settingsFor;

  /// Receives each settings snapshot a source is opened with, so the host
  /// can register its secrets with the log redactor (KTD9).
  final void Function(SettingsSnapshot settings)? onSettings;

  /// Verified plugin bytes from earlier conversions; `null` downloads every
  /// time.
  final PluginByteCache? cache;

  /// Downloads [entry]'s artifact bytes.
  @protected
  Future<SourceOutcome<Uint8List>> download(E entry);

  /// Opens [bytes] with [settings] and returns the package's sources; each
  /// is adopted into [owner] as soon as it opens (see [adoptPackage]).
  @protected
  Future<SourceOutcome<List<PluginSource>>> open(
    E entry,
    Uint8List bytes,
    SettingsSnapshot settings,
    ConversionOwner? owner,
  );

  /// The settings [entry] runs with: the user's, unless the ecosystem adds
  /// its own defaults.
  @protected
  SettingsSnapshot settingsOf(E entry) => settingsFor(entry);

  /// Why [entry] cannot be handled by this loader.
  @protected
  SourceFailure notMine(ExtensionEntry entry) => UnsupportedApiFailure('${entry.id} is not a $E');

  @override
  @nonVirtual
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  }) async {
    final plugins = <PluginSource>[];
    for (final (int i, ExtensionEntry entry) in extensions.indexed) {
      void fail(SourceFailure failure) {
        onFailure?.call(PluginLoadFailure(extensionId: entry.id, failure: failure));
        onProgress?.call(i + 1, extensions.length, 'Warning: failed to load ${entry.name}: ${failure.message}');
      }

      try {
        final Uint8List? cached = cache?.get(entry);
        onProgress?.call(i + 1, extensions.length, 'Loading plugin: ${entry.name}${cached != null ? ' (cached)' : ''}');
        final SourceOutcome<Uint8List> bytes = cached != null
            ? SourceSuccess<Uint8List>(cached)
            : await downloadPluginBytes(entry);
        switch (await bytes.andThen((Uint8List b) => loadPluginFromBytes(entry, b, owner: owner))) {
          case SourceSuccess<List<PluginSource>>(:final List<PluginSource> value):
            if (cached == null) cache?.put(entry, bytes.valueOrNull!);
            plugins.addAll(value);
          case SourceFailed<List<PluginSource>>(:final SourceFailure failure):
            if (cached != null) cache?.remove(entry);
            fail(failure);
        }
      } on Exception catch (e) {
        fail(SourceErrorFailure('$e'));
      }
    }
    return plugins;
  }

  /// Downloads [entry]'s artifact bytes, or the typed failure.
  @nonVirtual
  Future<SourceOutcome<Uint8List>> downloadPluginBytes(ExtensionEntry entry) async =>
      entry is E ? download(entry) : SourceFailed<Uint8List>(notMine(entry));

  /// Loads the package [entry] names from raw [bytes] and returns every
  /// source it hosts (KTD5 loader contract): a Tachi factory package yields
  /// one source per enumerated source ID, an Aidoku or Paperback package a
  /// singleton list. A failed load is a typed failure, never stub sources.
  @nonVirtual
  Future<SourceOutcome<List<PluginSource>>> loadPluginFromBytes(
    ExtensionEntry entry,
    Uint8List bytes, {
    ConversionOwner? owner,
  }) async {
    if (entry is! E) return SourceFailed<List<PluginSource>>(notMine(entry));
    final SettingsSnapshot settings = settingsOf(entry);
    onSettings?.call(settings);
    return open(entry, bytes, settings, owner);
  }

  /// Adopts an opened [package] into [owner] ([close] closes it and anything
  /// it holds, once), then the [plugins] made from its sessions, each as soon
  /// as it exists. A package that exposes no source is closed and fails.
  @protected
  static Future<SourceOutcome<List<PluginSource>>> adoptPackage(
    SourcePackage package,
    ConversionOwner? owner, {
    required Future<void> Function() close,
    required List<PluginSource> Function(List<SourceSession> sessions) plugins,
  }) async {
    await owner?.adopt(close);
    if (package.sessions.isEmpty) {
      await close();
      return const SourceFailed<List<PluginSource>>(ArtifactIncompatibleFailure('Package exposes no source'));
    }
    final List<PluginSource> opened = plugins(package.sessions);
    for (final plugin in opened) {
      await owner?.adopt(plugin.dispose);
    }
    return SourceSuccess<List<PluginSource>>(opened);
  }
}
