import 'dart:typed_data';

import 'package:http/http.dart' as http;
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
import 'package:source_runtime/source_runtime.dart';

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
  // Direct conversion is advertised only to formats with a verified
  // serializer: Tachimanga and Mihon (not the other Tachi forks).
  ..registerDirectConverter(legacyDirectConvert, targets: const <BackupFormat>[Tachimanga(), Mihon()]);

/// Whether the desktop Tachi worker can be located (no worker is started).
SourceFailure? probeTachiWorker(DesktopTachiRuntime tachi) => tachi.locate().failureOrNull;

/// The desktop source runtimes the CLI registers: Aidoku (in-process WASM),
/// Paperback (the CLI re-launched as its QuickJS worker) and Tachi (the
/// conversion's single JVM worker, Mihon destination). Each loader is wrapped
/// in the verified plugin byte cache.
///
/// [browserPort] (the desktop WebView helper) serves the Paperback worker's
/// browser requests; the Tachi worker's are served by the same port through
/// [tachi] (its `browserPort`). [paperbackClient] and [paperbackLauncher]
/// replace the live network and the re-launched executable (tests).
RuntimeRegistry cliRuntimeRegistry({
  required PluginCache cache,
  required DesktopTachiRuntime tachi,
  required String cacheRoot,
  required Duration interactionTimeout,
  void Function(SettingsSnapshot settings)? onSettings,
  void Function(String line)? onLog,
  SourceFailure? Function()? paperbackProbe,
  SourceFailure? Function()? tachiProbe,
  BrowserPort? browserPort,
  Duration? browserReplacementTimeout,
  http.Client? paperbackClient,
  WorkerLauncher? paperbackLauncher,
  Redactor? redactor,
}) => RuntimeRegistry(<DestinationRuntime>[
  DestinationRuntime(
    ecosystem: 'aidoku',
    serves: (BackupFormat f) => f is Aidoku,
    createLoader: (RuntimeContext context) => CachingPluginLoader(
      AidokuPluginLoader(onSettings: onSettings, settingsFor: context.settingsFor),
      cache: cache,
    ),
  ),
  DestinationRuntime(
    ecosystem: 'paperback',
    serves: (BackupFormat f) => f is Paperback,
    createLoader: (RuntimeContext context) => CachingPluginLoader(
      desktopPaperbackLoader(
        cacheRoot: cacheRoot,
        onSettings: onSettings,
        onLog: onLog,
        settingsFor: context.settingsFor,
        browserPort: browserPort,
        browserReplacementTimeout: browserReplacementTimeout,
        interactionTimeout: interactionTimeout,
        client: paperbackClient,
        launcher: paperbackLauncher,
        redactor: redactor,
      ),
      cache: cache,
    ),
    probe: paperbackProbe ?? (paperbackLauncher == null ? paperbackWorkerUnavailable : () => null),
  ),
  DestinationRuntime(
    ecosystem: tachiTrustEcosystem,
    // Tachimanga uses Tachi source identities too (it has no writer yet).
    serves: (BackupFormat f) => f is Tachiyomi || f is Tachimanga,
    createLoader: (RuntimeContext context) => CachingPluginLoader(
      TachiPluginLoader(runtime: tachi, onSettings: onSettings, settingsFor: context.settingsFor),
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
