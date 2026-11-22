import 'dart:typed_data';

import 'package:manga_backup_core/src/common/convertable.dart';
import 'package:manga_backup_core/src/conversion/backup_format.dart';
import 'package:manga_backup_core/src/conversion/conversion_report.dart';
import 'package:manga_backup_core/src/conversion/conversion_strategy.dart';
import 'package:manga_backup_core/src/conversion/target_backup_builder.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup.dart';
import 'package:manga_backup_core/src/formats/tachi/tachi_backup.dart';
import 'package:manga_backup_core/src/writers/aidoku_backup_builder.dart';
import 'package:manga_backup_core/src/writers/paperback_backup_builder.dart';
import 'package:manga_backup_core/src/writers/tachi_backup_builder.dart';

/// Decodes an input backup. [name] is a display name (for example the file
/// name without extension) for formats that carry none.
typedef BackupDecoder = Future<ConvertableBackup> Function(Uint8List bytes, {String? name});

/// Converts directly between formats that need no source plugins (for
/// example the CLI's Tachimanga↔Tachi adapter, which is native-dependent and
/// therefore lives outside the core). The converter adds whatever the
/// conversion changes or drops to [report] (KTD8).
typedef DirectConverter = ConvertableBackup Function(
  ConvertableBackup source,
  BackupFormat target,
  ConversionReport report,
);

/// Codecs and writers per backup format (KTD15). `BackupFormat` models carry
/// identity only; this registry says how a format is read and written.
/// Composition roots start from [FormatRegistry.portable] and add their
/// native-dependent codecs (Tachimanga's SQLite, Mangayomi) and direct
/// converter.
final class FormatRegistry {
  FormatRegistry();

  /// The portable codecs (Aidoku, Paperback, every Tachi fork) and writers
  /// (Aidoku, Paperback, Mihon).
  factory FormatRegistry.portable() {
    final registry = FormatRegistry()
      ..registerCodec(const Aidoku(), (Uint8List bytes, {String? name}) async => AidokuBackup.fromData(bytes))
      ..registerCodec(
        const Paperback(),
        (Uint8List bytes, {String? name}) async => PaperbackBackup.fromData(bytes, name: name),
      )
      ..registerWriter(const AidokuBackupBuilder())
      ..registerWriter(const PaperbackBackupBuilder())
      ..registerWriter(const TachiBackupBuilder());
    for (final BackupFormat f in BackupFormat.values) {
      if (f is Tachiyomi) {
        registry.registerCodec(f, (Uint8List bytes, {String? name}) async => TachiBackup.fromData(bytes, format: f));
      }
    }
    return registry;
  }

  final Map<String, BackupDecoder> _codecs = <String, BackupDecoder>{};
  final Map<String, TargetBackupBuilder> _writers = <String, TargetBackupBuilder>{};
  DirectConverter? _direct;
  Set<String> _directTargets = const <String>{};

  void registerCodec(BackupFormat format, BackupDecoder decode) => _codecs[format.alias] = decode;

  void registerWriter(TargetBackupBuilder writer) => _writers[writer.format.alias] = writer;

  /// Registers the converter for [DirectConversion] pairs whose target is
  /// one of [targets] (only formats with a verified serializer; other Tachi
  /// forks are not advertised).
  void registerDirectConverter(DirectConverter convert, {required Iterable<BackupFormat> targets}) {
    _direct = convert;
    _directTargets = <String>{for (final BackupFormat t in targets) t.alias};
  }

  /// Whether a direct conversion may produce [target].
  bool directTarget(BackupFormat target) => _direct != null && _directTargets.contains(target.alias);

  BackupDecoder? codecFor(BackupFormat format) => _codecs[format.alias];

  TargetBackupBuilder? writerFor(BackupFormat format) => _writers[format.alias];

  DirectConverter? get directConverter => _direct;

  /// Formats with a registered writer (migration destinations).
  List<BackupFormat> get writableFormats =>
      BackupFormat.values.where((BackupFormat f) => _writers.containsKey(f.alias)).toList();

  /// Formats reachable as an output from some input: a writer, or a direct
  /// converter for a direct pair.
  List<BackupFormat> get outputFormats => BackupFormat.values
      .where(
        (BackupFormat t) =>
            _writers.containsKey(t.alias) ||
            (directTarget(t) &&
                BackupFormat.values.any((BackupFormat s) => determineStrategy(s, t) is DirectConversion)),
      )
      .toList();
}
