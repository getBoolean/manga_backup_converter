import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/extension_settings.dart';
import 'package:manga_backup_core/src/conversion/plugin_loader.dart';
import 'package:source_runtime/source_contracts.dart';

/// What a conversion hands a runtime when it creates its loader: the
/// user's extension settings (the core never supplies any of its own).
final class RuntimeContext {
  const RuntimeContext({this.settingsFor = noExtensionSettings});

  final ExtensionSettingsProvider settingsFor;
}

/// The source ecosystems a destination runtime belongs to, declared once
/// for every host: the [id] used in `SourceIdentity.ecosystem` and the
/// formats whose destination identities it supplies. Hosts register a
/// backend for a row ([DestinationRuntime.of]), never their own row.
///
/// Tachimanga is not served: it has no writer, and the job checks the writer
/// before it asks for a runtime.
enum SourceEcosystem {
  aidoku('aidoku'),
  paperback('paperback'),
  tachi('tachi');

  const SourceEcosystem(this.id);

  final String id;

  bool serves(BackupFormat format) => switch (this) {
    aidoku => format is Aidoku,
    paperback => format is Paperback,
    tachi => format is Tachiyomi,
  };
}

/// One source runtime a host can run (Aidoku, Paperback, Tachi), as the
/// composition root registers it (KTD15).
///
/// [createLoader] builds the per-conversion loader (today the temporary
/// `PluginLoader` adapter over the backend-neutral `SourceProvider`).
/// [probe] reports, cheaply and without starting a worker, whether the host
/// can run it: `null` when available, otherwise the typed capability
/// failure. A missing runtime is never a fallback to another machine or an
/// empty source list.
final class DestinationRuntime {
  const DestinationRuntime({
    required this.ecosystem,
    required this.serves,
    required this.createLoader,
    this.probe = _available,
  });

  /// The host's backend for an [ecosystem] row.
  DestinationRuntime.of(
    SourceEcosystem ecosystem, {
    required PluginLoader Function(RuntimeContext context) createLoader,
    SourceFailure? Function() probe = _available,
  }) : this(ecosystem: ecosystem.id, serves: ecosystem.serves, createLoader: createLoader, probe: probe);

  /// Ecosystem name (`SourceIdentity.ecosystem`).
  final String ecosystem;

  /// Whether this runtime supplies the destination identities of a format.
  final bool Function(BackupFormat format) serves;
  final PluginLoader Function(RuntimeContext context) createLoader;
  final SourceFailure? Function() probe;

  static SourceFailure? _available() => null;
}

/// Source runtimes registered by a host, resolved per destination format
/// (KTD15). Injected into the conversion job; the core never constructs a
/// concrete loader.
final class RuntimeRegistry {
  RuntimeRegistry([Iterable<DestinationRuntime> runtimes = const <DestinationRuntime>[]]) {
    runtimes.forEach(register);
  }

  final List<DestinationRuntime> _runtimes = <DestinationRuntime>[];

  void register(DestinationRuntime runtime) => _runtimes.add(runtime);

  List<DestinationRuntime> get runtimes => List<DestinationRuntime>.unmodifiable(_runtimes);

  DestinationRuntime? runtimeFor(BackupFormat format) =>
      _runtimes.where((DestinationRuntime r) => r.serves(format)).firstOrNull;

  /// `null` when [format]'s runtime is registered and available on this
  /// host, otherwise the typed failure saying why not.
  SourceFailure? unavailable(BackupFormat format) {
    final DestinationRuntime? runtime = runtimeFor(format);
    if (runtime == null) {
      return CapabilityUnavailableFailure('runtime.${format.alias}', 'No source runtime is registered for $format');
    }
    return runtime.probe();
  }

  /// The loader for [format]'s runtime, or the typed failure.
  SourceOutcome<PluginLoader> loaderFor(BackupFormat format, [RuntimeContext context = const RuntimeContext()]) {
    final SourceFailure? missing = unavailable(format);
    if (missing != null) return SourceFailed<PluginLoader>(missing);
    return SourceSuccess<PluginLoader>(runtimeFor(format)!.createLoader(context));
  }
}
