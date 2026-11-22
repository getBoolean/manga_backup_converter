import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:test/scaffolding.dart';

import 'writer_fixtures.dart';

typedef _Built = ({PaperbackBackup backup, ConversionReport report, List<MangaConversionPlan> plans});

void main() {
  const builder = PaperbackBackupBuilder();

  _Built build(
    List<MangaMatchConfirmation> confirmations,
  ) {
    final plans = <MangaConversionPlan>[for (final c in confirmations) planConversion(c)];
    final report = ConversionReport();
    final backup = builder.build(plans, report: report, sourceFormatAlias: 'aidoku') as PaperbackBackup;
    return (backup: backup, report: report, plans: plans);
  }

  test('runtime-native IDs go in their own fields; generated backup-local IDs are distinct from them', () async {
    final MangaMatchConfirmation c = fetchedConfirmation(
      statefulManga(),
      runtimeIdentity('paperback', 'WeebCentral', packageId: 'https://repo.invalid/#WeebCentral'),
      mangaId: '01J76XYF0TGKQ7XJ4XVPV1C0BP',
      chapters: destinationChapters(prefix: 'ch-'),
    );
    final _Built built = build(<MangaMatchConfirmation>[c]);
    final reread = PaperbackBackup.fromData(await built.backup.toData());

    final PaperbackBackupSourceManga sm = reread.sourceManga!.single;
    // The bare runtime source ID, never the `repository#id` package ID.
    check(sm.sourceId).equals('WeebCentral');
    check(sm.mangaId).equals('01J76XYF0TGKQ7XJ4XVPV1C0BP');
    check(sm.id).not((Subject<String> it) => it.equals(sm.mangaId));
    check(sm.id).not((Subject<String> it) => it.contains('handle'));
    check(reread.chapters!.map((PaperbackBackupChapter ch) => ch.chapterId).toSet())
        .deepEquals(<String>{'ch-1', 'ch-2', 'ch-3', 'ch-4'});
    for (final PaperbackBackupChapter ch in reread.chapters!) {
      check(ch.id).not((Subject<String> it) => it.equals(ch.chapterId));
      check(ch.sourceManga.id).equals(sm.id);
    }
    // Deterministic: the same graph gets the same IDs.
    check(paperbackLocalId('source-manga', <String>['WeebCentral', '01J76XYF0TGKQ7XJ4XVPV1C0BP'])).equals(sm.id);
  });

  test('the reference graph resolves: library → source manga → manga info, chapters, progress markers', () async {
    final MangaMatchConfirmation c = fetchedConfirmation(
      statefulManga(),
      runtimeIdentity('paperback', 'WeebCentral'),
      mangaId: 'm1',
      chapters: destinationChapters(prefix: 'ch-'),
    );
    final _Built built = build(<MangaMatchConfirmation>[c]);
    final Uint8List bytes = await built.backup.toData();
    check(builder.validate(bytes, built.plans)).isEmpty();

    final reread = PaperbackBackup.fromData(bytes);
    final PaperbackBackupLibraryManga lib = reread.libraryManga!.single;
    final PaperbackBackupSourceManga sm = reread.sourceManga!.single;
    check(lib.primarySource.id).equals(sm.id);
    check(lib.primarySource.type).equals(PaperbackBackupItemType.sourceMangaV4);
    check(sm.mangaInfo.id).equals(reread.mangaInfo!.single.id);
    final Set<String> chapterIds = reread.chapters!.map((PaperbackBackupChapter ch) => ch.id).toSet();
    for (final PaperbackBackupChapterProgressMarker m in reread.chapterProgressMarker!) {
      check(chapterIds).contains(m.chapter.id);
      check(m.chapter.type).equals(PaperbackBackupItemType.chapterV4);
    }
    // The core's own reader follows the same links back to the library entry.
    final SourceMangaData back = reread.sourceMangaDataEntries.single;
    check(back.sourceId).equals('WeebCentral');
    check(back.sourceMangaKey).equals('m1');
    check(back.categories).deepEquals(<String>['Reading', 'Favourites']);
  });

  test('partial progress, completion, dates and categories transfer; bookmarks and tracking are reported', () async {
    final MangaMatchConfirmation c = fetchedConfirmation(
      statefulManga(),
      runtimeIdentity('paperback', 'WeebCentral'),
      mangaId: 'm1',
      chapters: destinationChapters(prefix: 'ch-'),
    );
    final _Built built = build(<MangaMatchConfirmation>[c]);
    final reread = PaperbackBackup.fromData(await built.backup.toData());
    final List<SourceChapter> state = reread.sourceMangaDataEntries.single.chapters
        .where((SourceChapter ch) => ch.hasReadingState)
        .toList();
    final SourceChapter one = state.firstWhere((SourceChapter ch) => ch.chapterKey == 'ch-1');
    final SourceChapter two = state.firstWhere((SourceChapter ch) => ch.chapterKey == 'ch-2');
    check(one.isRead).isTrue();
    check(one.dateRead).equals(DateTime.utc(2024, 3));
    // Partial progress stays partial, never completed (AE2).
    check(two.isRead).isFalse();
    check(two.lastPageRead).equals(5);
    check(two.totalPages).equals(20);
    check(state.length).equals(2);
    final PaperbackBackupLibraryManga lib = reread.libraryManga!.single;
    check(lib.dateBookmarked).equals(DateTime.utc(2024, 1, 2));
    check(lib.lastRead).equals(DateTime.utc(2024, 3, 4));

    final ConversionReport r = built.report;
    check(r.count(RecordKind.chapterState, RecordDisposition.transferred)).equals(3);
    check(r.where(RecordKind.field, RecordDisposition.unrepresentable).single.subject).contains('bookmark');
    check(r.where(RecordKind.tracking, RecordDisposition.unrepresentable)).length.equals(1);
    check(r.count(RecordKind.manga, RecordDisposition.transferred)).equals(1);
  });

  test('validation rejects a graph with a dangling reference or state on a non-fetched chapter', () async {
    final MangaMatchConfirmation c = fetchedConfirmation(
      statefulManga(),
      runtimeIdentity('paperback', 'WeebCentral'),
      mangaId: 'm1',
      chapters: destinationChapters(prefix: 'ch-'),
    );
    final _Built built = build(<MangaMatchConfirmation>[c]);
    final PaperbackBackup b = built.backup;
    final dangling = PaperbackBackup(
      mangaInfo: b.mangaInfo,
      sourceManga: b.sourceManga,
      chapters: b.chapters,
      libraryManga: b.libraryManga,
      chapterProgressMarker: <PaperbackBackupChapterProgressMarker>[
        PaperbackBackupChapterProgressMarker(
          totalPages: 0,
          completed: true,
          chapter: PaperbackBackupItemReference(type: PaperbackBackupItemType.chapterV4, id: 'missing'),
          lastPage: 0,
          time: DateTime.utc(2024),
          hidden: false,
        ),
      ],
    );
    check(builder.validate(await dangling.toData(), built.plans)).any((Subject<String> it) => it.contains('dangling'));

    // The same graph validated against a plan whose runtime returned other
    // chapters: every written chapter is flagged.
    final MangaMatchConfirmation other = fetchedConfirmation(
      statefulManga(),
      runtimeIdentity('paperback', 'WeebCentral'),
      mangaId: 'm1',
      chapters: destinationChapters(prefix: 'other-'),
    );
    check(builder.validate(await b.toData(), <MangaConversionPlan>[planConversion(other)]))
        .any((Subject<String> it) => it.contains('not returned by the destination runtime'));
    check(builder.validate(Uint8List.fromList(<int>[1, 2, 3]), built.plans)).any(
      (Subject<String> it) => it.contains('no __MANGA_INFO_V4 entry'),
    );
  });
}
