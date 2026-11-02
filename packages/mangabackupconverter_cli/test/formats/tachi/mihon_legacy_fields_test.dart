import 'package:checks/checks.dart';
import 'package:fixnum/fixnum.dart';
import 'package:mangabackupconverter_cli/src/formats/tachi/tachi_backup_chapter.dart';
import 'package:mangabackupconverter_cli/src/formats/tachi/tachi_backup_extension_repo.dart';
import 'package:mangabackupconverter_cli/src/formats/tachi/tachi_backup_manga.dart';
import 'package:mangabackupconverter_cli/src/proto/schema_mihon.proto/proto/schema_mihon.pb.dart' as mihon;
import 'package:protobuf/protobuf.dart';
import 'package:test/scaffolding.dart';

/// Encodes [message] with extra varint fields appended, as written by an older
/// Mihon version whose schema still had them, then decodes it with [decode].
T _withLegacyVarints<T extends GeneratedMessage>(
  T message,
  Map<int, int> legacyFields,
  T Function(List<int>) decode,
) {
  final unknown = UnknownFieldSet();
  legacyFields.forEach((int tag, int value) => unknown.mergeVarintField(tag, Int64(value)));
  final writer = CodedBufferWriter();
  unknown.writeToCodedBufferWriter(writer);
  return decode(<int>[...message.writeToBuffer(), ...writer.toBuffer()]);
}

void main() {
  group('Mihon fields removed from the schema', () {
    test('chapter lastModifiedAt/version are read from older backups', () {
      final mihon.BackupChapter chapter = _withLegacyVarints(
        mihon.BackupChapter(url: '/ch/1', name: 'Chapter 1'),
        <int, int>{11: 1700000000000, 12: 3},
        mihon.BackupChapter.fromBuffer,
      );

      final result = TachiBackupChapter.fromMihon(chapter);

      check(result.lastModifiedAt).equals(1700000000000);
      check(result.version).equals(3);
    });

    test('chapter lastModifiedAt/version are null in newer backups', () {
      final result = TachiBackupChapter.fromMihon(
        mihon.BackupChapter(url: '/ch/1', name: 'Chapter 1'),
      );

      check(result.lastModifiedAt).isNull();
      check(result.version).isNull();
    });

    test('manga lastModifiedAt/version are read from older backups', () {
      final mihon.BackupManga manga = _withLegacyVarints(
        mihon.BackupManga(source: Int64(1), url: '/m/1'),
        <int, int>{106: 1700000000000, 109: 7},
        mihon.BackupManga.fromBuffer,
      );

      final result = TachiBackupManga.fromMihon(manga);

      check(result.lastModifiedAt).equals(1700000000000);
      check(result.version).equals(7);
    });
  });

  test('extension store maps onto the extension repo model', () {
    final result = TachiBackupExtensionRepo.fromMihon(
      mihon.BackupExtensionStore(
        indexUrl: 'https://example.com/index.min.json',
        name: 'Example',
        badgeLabel: 'EX',
        contactWebsite: 'https://example.com',
        signingKey: 'abc123',
      ),
    );

    check(result.baseUrl).equals('https://example.com/index.min.json');
    check(result.name).equals('Example');
    check(result.shortName).equals('EX');
    check(result.website).equals('https://example.com');
    check(result.signingKeyFingerprint).equals('abc123');
  });
}
