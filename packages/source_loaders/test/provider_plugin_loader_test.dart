import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_loaders/source_loaders.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

final class _MemoryCache implements PluginByteCache {
  final Map<String, Uint8List> bytes = <String, Uint8List>{};

  @override
  Uint8List? get(ExtensionEntry entry) => bytes[entry.cacheKey];

  @override
  void put(ExtensionEntry entry, Uint8List value) => bytes[entry.cacheKey] = value;

  @override
  void remove(ExtensionEntry entry) => bytes.remove(entry.cacheKey);
}

/// Records each download and open; [download] and [open] answer from the
/// queued outcomes.
final class _Loader extends ProviderPluginLoader<StubExtensionEntry> {
  _Loader({super.cache, super.onSettings});

  final List<String> calls = <String>[];
  SourceOutcome<Uint8List> downloaded = SourceSuccess<Uint8List>(Uint8List.fromList(<int>[1]));
  SourceOutcome<List<PluginSource>> opened = const SourceSuccess<List<PluginSource>>(<PluginSource>[]);

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async => const <ExtensionEntry>[];

  @override
  Future<SourceOutcome<Uint8List>> download(StubExtensionEntry entry) async {
    calls.add('download ${entry.id}');
    return downloaded;
  }

  @override
  Future<SourceOutcome<List<PluginSource>>> open(
    StubExtensionEntry entry,
    Uint8List bytes,
    SettingsSnapshot settings,
    ConversionOwner? owner,
  ) async {
    calls.add('open ${entry.id} $bytes');
    return opened;
  }
}

const _entry = StubExtensionEntry(id: 'ext', name: 'Ext');

void main() {
  test('downloaded bytes are cached only after they load; a cache hit is not downloaded', () async {
    final cache = _MemoryCache();
    final loader = _Loader(cache: cache);
    final progress = <String>[];
    await loader.loadPlugins(<ExtensionEntry>[_entry], onProgress: (_, _, String m) => progress.add(m));
    check(cache.bytes[_entry.cacheKey]).isNotNull().deepEquals(<int>[1]);

    await loader.loadPlugins(<ExtensionEntry>[_entry], onProgress: (_, _, String m) => progress.add(m));
    check(loader.calls).deepEquals(<String>['download ext', 'open ext [1]', 'open ext [1]']);
    check(progress).deepEquals(<String>['Loading plugin: Ext', 'Loading plugin: Ext (cached)']);
  });

  test('a failed download is reported once and never retried or cached', () async {
    final cache = _MemoryCache();
    final loader = _Loader(cache: cache)
      ..downloaded = const SourceFailed<Uint8List>(TimeoutFailure('slow bundle host'));
    final failures = <PluginLoadFailure>[];
    check(await loader.loadPlugins(<ExtensionEntry>[_entry], onFailure: failures.add)).isEmpty();
    check(loader.calls).deepEquals(<String>['download ext']);
    check(failures.single.failure).isA<TimeoutFailure>();
    check(cache.bytes).isEmpty();
  });

  test('cached bytes that no longer load are dropped without downloading again in the run', () async {
    final cache = _MemoryCache()..bytes[_entry.cacheKey] = Uint8List.fromList(<int>[9]);
    final loader = _Loader(cache: cache)
      ..opened = const SourceFailed<List<PluginSource>>(ArtifactIncompatibleFailure('digest changed'));
    final failures = <PluginLoadFailure>[];
    await loader.loadPlugins(<ExtensionEntry>[_entry], onFailure: failures.add);
    check(loader.calls).deepEquals(<String>['open ext [9]']);
    check(failures.single.failure).isA<ArtifactIncompatibleFailure>();
    check(cache.bytes).isEmpty();
  });

  test('settings are reported for every load, and an entry of another ecosystem is a typed failure', () async {
    final seen = <SettingsSnapshot>[];
    final loader = _Loader(onSettings: seen.add);
    check(await loader.loadPluginFromBytes(_entry, Uint8List(0))).isA<SourceSuccess<List<PluginSource>>>();
    check(seen).length.equals(1);
    const other = AidokuExtensionEntry(id: 'a', name: 'A', version: 1, iconUrl: '', downloadUrl: '');
    check((await loader.loadPluginFromBytes(other, Uint8List(0))).failureOrNull).isA<UnsupportedApiFailure>();
    check((await loader.downloadPluginBytes(other)).failureOrNull).isA<UnsupportedApiFailure>();
    check(loader.calls).deepEquals(<String>['open ext []']);
  });
}
