import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:checks/checks.dart';
import 'package:fixnum/fixnum.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:manga_backup_core/src/formats/tachi/proto/schema_mihon.proto/proto/schema_mihon.pb.dart' as mihon;
import 'package:test/scaffolding.dart';

import 'writer_fixtures.dart';

/// A real keiyoushi source ID: above 2^53, so any double round trip breaks it.
const String _weebCentralId = '2131019126180322627';

typedef _Built = ({TachiBackup backup, ConversionReport report, List<MangaConversionPlan> plans});

void main() {
  const builder = TachiBackupBuilder();

  _Built build(
    List<MangaMatchConfirmation> confirmations, {
    String sourceFormatAlias = 'aidoku',
  }) {
    final plans = <MangaConversionPlan>[for (final c in confirmations) planConversion(c)];
    final report = ConversionReport();
    final backup = builder.build(plans, report: report, sourceFormatAlias: sourceFormatAlias) as TachiBackup;
    return (backup: backup, report: report, plans: plans);
  }

  mihon.Backup decode(Uint8List bytes) => mihon.Backup.fromBuffer(const GZipDecoder().decodeBytes(bytes));

  MangaMatchConfirmation weebCentral({SourceMangaData? manga}) => fetchedConfirmation(
    manga ?? statefulManga(),
    runtimeIdentity('tachi', _weebCentralId, packageId: 'eu.kanade.tachiyomi.extension.en.weebcentral'),
    mangaId: '/series/01J76XYF0TGKQ7XJ4XVPV1C0BP/ONIMAI-Im-Now-Your-Sister',
    chapters: destinationChapters(prefix: '/chapters/01J'),
    sourceName: 'Weeb Central',
  );

  test(
    'AE1: the exact int64 source ID and the native manga/chapter URLs are written, never handles or web URLs',
    () async {
      final _Built built = build(<MangaMatchConfirmation>[weebCentral()]);
      final Uint8List bytes = await built.backup.toData();
      final mihon.Backup proto = decode(bytes);

      final mihon.BackupManga m = proto.backupManga.single;
      check(m.source).equals(Int64.parseInt(_weebCentralId));
      check(m.source.toString()).equals(_weebCentralId);
      check(m.url).equals('/series/01J76XYF0TGKQ7XJ4XVPV1C0BP/ONIMAI-Im-Now-Your-Sister');
      check(m.favorite).isTrue();
      check(m.chapters.map((mihon.BackupChapter c) => c.url).toSet())
          .deepEquals(<String>{'/chapters/01J1', '/chapters/01J2', '/chapters/01J3', '/chapters/01J4'});
      for (final mihon.BackupChapter c in m.chapters) {
        check(c.url).not((Subject<String> it) => it.startsWith('https://'));
        check(c.url).not((Subject<String> it) => it.contains('handle'));
        // The source's own unsplit scanlator string.
        check(c.scanlator).equals('Group A & Group B');
      }
      check(proto.backupSources.single.sourceId.toString()).equals(_weebCentralId);
      check(proto.backupSources.single.name).equals('Weeb Central');
      check(builder.validate(bytes, built.plans)).isEmpty();
      // Fork identity is explicit, and the core reader round-trips it.
      check(built.backup.format).equals(const Mihon());
      check(TachiBackup.fromData(bytes).backupManga.single.source.toString()).equals(_weebCentralId);
    },
  );

  test('read, partial progress, bookmarks, history dates and categories transfer to Mihon fields', () async {
    final _Built built = build(<MangaMatchConfirmation>[weebCentral()]);
    final mihon.Backup proto = decode(await built.backup.toData());
    final mihon.BackupManga m = proto.backupManga.single;
    mihon.BackupChapter ch(int n) => m.chapters.firstWhere((mihon.BackupChapter c) => c.url == '/chapters/01J$n');
    check(ch(1).read).isTrue();
    check(ch(2).read).isFalse();
    check(ch(2).lastPageRead.toInt()).equals(5);
    check(ch(3).bookmark).isTrue();
    check(ch(4).read).isFalse();
    check(m.history.map((mihon.BackupHistory h) => h.url).toSet())
        .deepEquals(<String>{'/chapters/01J1', '/chapters/01J2'});
    check(
      m.history.firstWhere((mihon.BackupHistory h) => h.url == '/chapters/01J2').lastRead.toInt(),
    ).equals(DateTime.utc(2024, 3, 4).millisecondsSinceEpoch);
    check(m.dateAdded.toInt()).equals(DateTime.utc(2024, 1, 2).millisecondsSinceEpoch);
    check(proto.backupCategories.map((mihon.BackupCategory c) => (c.name, c.order.toInt())).toList())
        .deepEquals(<(String, int)>[('Reading', 0), ('Favourites', 1)]);
    check(m.categories.map((Int64 c) => c.toInt()).toList()).deepEquals(<int>[0, 1]);

    final ConversionReport r = built.report;
    check(r.count(RecordKind.chapterState, RecordDisposition.transferred)).equals(3);
    // Tachi represents bookmarks: no unrepresentable field.
    check(r.count(RecordKind.field)).equals(0);
    // Tracking from another app has no verified tracker mapping.
    check(r.where(RecordKind.tracking, RecordDisposition.unrepresentable)).length.equals(1);
  });

  test('a non-int64 destination source ID is unresolved, never hashed into a Tachi ID', () async {
    final MangaMatchConfirmation c = fetchedConfirmation(
      statefulManga(),
      runtimeIdentity('aidoku', 'en.weebcentral'),
      mangaId: 'x',
      chapters: destinationChapters(),
    );
    final _Built built = build(<MangaMatchConfirmation>[c]);
    check(built.backup.backupManga).isEmpty();
    check(built.report.where(RecordKind.manga, RecordDisposition.unresolved).single.reason)
        .isNotNull()
        .contains('not a Tachi int64 source ID');
  });

  test('validation flags chapters the runtime did not return and history without a chapter', () async {
    final _Built built = build(<MangaMatchConfirmation>[weebCentral()]);
    final TachiBackup b = built.backup;
    final TachiBackupManga m = b.backupManga.single;
    final broken = TachiBackup(
      backupSources: b.backupSources,
      backupCategories: b.backupCategories,
      backupManga: <TachiBackupManga>[
        m.copyWith(
          chapters: <TachiBackupChapter>[
            ...m.chapters,
            const TachiBackupChapter(
              url: '/chapters/guessed',
              name: 'Guessed',
              scanlator: '',
              read: true,
              bookmark: false,
              lastPageRead: 0,
              dateFetch: 0,
              dateUpload: 0,
              chapterNumber: 9,
              sourceOrder: 9,
            ),
          ],
          history: <TachiBackupHistory>[
            ...m.history,
            const TachiBackupHistory(url: '/chapters/none', lastRead: 1, readDuration: 0),
          ],
        ),
      ],
    );
    final List<String> problems = builder.validate(await broken.toData(), built.plans);
    check(problems).any((Subject<String> it) => it.contains('/chapters/guessed was not returned'));
    check(problems).any((Subject<String> it) => it.contains('history /chapters/none has no chapter'));
  });

  test('Mihon → Mihon keeps tracking (same tracker registry)', () async {
    final _Built built = build(<MangaMatchConfirmation>[weebCentral()], sourceFormatAlias: 'mihon');
    final mihon.Backup proto = decode(await built.backup.toData());
    check(proto.backupManga.single.tracking.single.mediaId.toInt()).equals(99);
    check(built.report.where(RecordKind.tracking, RecordDisposition.transferred)).length.equals(1);
  });
}
