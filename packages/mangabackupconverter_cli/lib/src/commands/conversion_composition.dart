import 'dart:typed_data';

import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/caching_plugin_loader.dart';
import 'package:mangabackupconverter_cli/src/commands/file_stores.dart';
import 'package:mangabackupconverter_cli/src/commands/plugin_cache.dart';
import 'package:mangabackupconverter_cli/src/formats/mangayomi/mangayomi_backup.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachi_to_tachimanga.dart';
import 'package:mangabackupconverter_cli/src/formats/tachimanga/tachimanga_backup.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_loader.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_paperback.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_tachi.dart';
import 'package:source_runtime/source_contracts.dart';

/// The CLI composition root (KTD15): the portable codecs and writers plus
/// the native-dependent Tachimanga (SQLite) and Mangayomi codecs and the
/// Tachimanga↔Tachi direct converter.
FormatRegistry cliFormatRegistry() => FormatRegistry.portable()
  ..registerCodec(
    const Tachimanga(),
    (Uint8List bytes, {String? name}) => TachimangaBackup.fromData(bytes),
  )
  ..registerCodec(
    const Mangayomi(),
    (Uint8List bytes, {String? name}) async => MangayomiBackup.fromData(bytes),
  )
  ..registerDirectConverter(legacyDirectConvert);

/// Whether the desktop Tachi worker can be located (no worker is started).
SourceFailure? probeTachiWorker(DesktopTachiRuntime tachi) => tachi.locate().failureOrNull;

/// The desktop source runtimes the CLI registers: Aidoku (in-process WASM),
/// Paperback (the CLI re-launched as its QuickJS worker) and Tachi (the
/// conversion's single JVM worker, Mihon destination). Each loader is wrapped
/// in the verified plugin byte cache.
RuntimeRegistry cliRuntimeRegistry({
  required PluginCache cache,
  required DesktopTachiRuntime tachi,
  required String cacheRoot,
  void Function(SettingsSnapshot settings)? onSettings,
  void Function(String line)? onLog,
  SourceFailure? Function()? paperbackProbe,
  SourceFailure? Function()? tachiProbe,
}) => RuntimeRegistry(<DestinationRuntime>[
  DestinationRuntime(
    ecosystem: 'aidoku',
    serves: (BackupFormat f) => f is Aidoku,
    createLoader: () => CachingPluginLoader(AidokuPluginLoader(onSettings: onSettings), cache: cache),
  ),
  DestinationRuntime(
    ecosystem: 'paperback',
    serves: (BackupFormat f) => f is Paperback,
    createLoader: () => CachingPluginLoader(
      PaperbackPluginLoader.desktop(cacheRoot: cacheRoot, onSettings: onSettings, onLog: onLog),
      cache: cache,
    ),
    probe: paperbackProbe ?? paperbackWorkerUnavailable,
  ),
  DestinationRuntime(
    ecosystem: tachiTrustEcosystem,
    serves: (BackupFormat f) => f is Tachiyomi,
    createLoader: () => CachingPluginLoader(
      TachiPluginLoader(runtime: tachi, onSettings: onSettings),
      cache: cache,
    ),
    probe: tachiProbe ?? () => probeTachiWorker(tachi),
  ),
]);

/// Publishes to a file through a temporary sibling and an atomic rename;
/// an existing destination is untouched unless the rename succeeds.
final class FileConversionOutput implements ConversionOutput {
  const FileConversionOutput(this.path);

  final String path;

  @override
  Future<void> publish(Uint8List bytes) => writeFileAtomically(path, bytes);
}
