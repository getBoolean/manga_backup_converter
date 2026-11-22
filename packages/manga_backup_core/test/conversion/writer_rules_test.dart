import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import 'writer_fixtures.dart';

/// Rules every writer shares: one build template, one validator.
void main() {
  final writers = <(TargetBackupBuilder, SourceIdentity)>[
    (const AidokuBackupBuilder(), runtimeIdentity('aidoku', 'en.weebcentral')),
    (const PaperbackBackupBuilder(), runtimeIdentity('paperback', 'WeebCentral')),
    (const TachiBackupBuilder(), runtimeIdentity('tachi', '2131019126180322627')),
  ];

  MangaMatchConfirmation confirmation(SourceIdentity identity, List<NativeChapter> chapters) =>
      fetchedConfirmation(statefulManga(), identity, mangaId: 'm1', chapters: chapters);

  Future<(Uint8List, ConversionReport)> write(TargetBackupBuilder writer, MangaMatchConfirmation c) async {
    final report = ConversionReport();
    final ConvertableBackup backup = writer.build(<MangaConversionPlan>[planConversion(c)], report: report);
    return (await backup.toData(), report);
  }

  for (final (TargetBackupBuilder writer, SourceIdentity identity) in writers) {
    group('${writer.format}', () {
      test('a fetched chapter that was not written is a problem', () async {
        final (Uint8List bytes, _) = await write(writer, confirmation(identity, destinationChapters()));
        final MangaMatchConfirmation fetchedMore = confirmation(identity, <NativeChapter>[
          ...destinationChapters(),
          const NativeChapter(chapterId: '/chapters/5', sourceOrder: 5, chapterNumber: 5),
        ]);
        check(writer.validate(bytes, <MangaConversionPlan>[planConversion(fetchedMore)]))
            .any((Subject<String> it) => it.endsWith('4 of 5 destination chapters written'));
      });

      test('several scanlators are kept (joined) or reported, never silently merged', () async {
        final (_, ConversionReport report) = await write(writer, confirmation(identity, destinationChapters()));
        final bool joins = writer.unrepresentableFields.contains(UnrepresentableField.scanlatorGroups);
        check(report.notes.any((String n) => n.contains('list several scanlators'))).equals(joins);
      });

      test('bookmarks are written or reported unrepresentable', () async {
        final (_, ConversionReport report) = await write(writer, confirmation(identity, destinationChapters()));
        final bool bookmarks = writer.unrepresentableFields.contains(UnrepresentableField.chapterBookmark);
        check(report.where(RecordKind.field, RecordDisposition.unrepresentable).length).equals(bookmarks ? 1 : 0);
      });
    });
  }

  test('Paperback reports joined scanlators like Aidoku', () async {
    final (_, ConversionReport report) = await write(
      const PaperbackBackupBuilder(),
      confirmation(runtimeIdentity('paperback', 'WeebCentral'), destinationChapters()),
    );
    check(report.notes).any((Subject<String> it) => it.contains('Paperback backups store one scanlator field'));
  });

  test('a duplicate destination chapter ID is caught for Aidoku and Tachi', () async {
    for (final (TargetBackupBuilder writer, SourceIdentity identity) in <(TargetBackupBuilder, SourceIdentity)>[
      writers.first,
      writers.last,
    ]) {
      final MangaMatchConfirmation c = confirmation(identity, <NativeChapter>[
        ...destinationChapters(),
        const NativeChapter(chapterId: '/chapters/1', sourceOrder: 9, chapterNumber: 1, title: 'Chapter 1 (again)'),
      ]);
      final (Uint8List bytes, _) = await write(writer, c);
      check(
        because: '${writer.format}',
        writer.validate(bytes, <MangaConversionPlan>[planConversion(c)]),
      ).any((Subject<String> it) => it.contains('chapter /chapters/1 is written twice'));
    }
  });

  test('a Tachi manga skipped for a non-int64 source ID accounts every record and still validates', () async {
    const writer = TachiBackupBuilder();
    final MangaMatchConfirmation c = confirmation(runtimeIdentity('aidoku', 'en.weebcentral'), destinationChapters());
    final (Uint8List bytes, ConversionReport report) = await write(writer, c);
    final List<ReportEntry> unresolved = report.where(RecordKind.chapterState, RecordDisposition.unresolved).toList();
    check(unresolved).length.equals(3); // read, partly read and bookmarked chapters
    check(unresolved.every((ReportEntry e) => e.reason == 'manga not migrated')).isTrue();
    check(report.where(RecordKind.tracking, RecordDisposition.unresolved)).length.equals(1);
    check(report.where(RecordKind.chapterState, RecordDisposition.transferred)).isEmpty();
    check(writer.validate(bytes, <MangaConversionPlan>[planConversion(c)])).isEmpty();
  });

  // Two source manga (the same series from two sources) confirmed to one
  // destination manga: every writer writes the destination once, merged,
  // and the report names both source manga.
  group('two source manga confirmed to one destination', () {
    MangaMatchConfirmation twin(
      SourceIdentity identity, {
      required String sourceId,
      required String artist,
      required List<String> categories,
      required List<SourceChapter> chapters,
    }) => fetchedConfirmation(
      SourceMangaData(
        details: MangaSearchDetails(title: 'Onimai', artists: <String>[artist]),
        sourceId: sourceId,
        sourceMangaKey: 'onimai',
        categories: categories,
        chapters: chapters,
      ),
      identity,
      mangaId: 'm1',
      chapters: destinationChapters(),
      // No destination artist: each source would fall back to its own.
      artists: const <String>[],
    );

    for (final (TargetBackupBuilder writer, SourceIdentity identity) in writers) {
      test('${writer.format} writes the destination once, merged, with a note', () async {
        final plans = <MangaConversionPlan>[
          planConversion(
            twin(
              identity,
              sourceId: 'source-one',
              artist: 'Artist One',
              categories: const <String>['Reading'],
              chapters: <SourceChapter>[SourceChapter(title: 'One', chapterNumber: 1, isRead: true)],
            ),
          ),
          planConversion(
            twin(
              identity,
              sourceId: 'source-two',
              artist: 'Artist Two',
              categories: const <String>['Reading', 'Favourites'],
              chapters: <SourceChapter>[
                SourceChapter(title: 'One', chapterNumber: 1, lastPageRead: 3),
                SourceChapter(title: 'Two', chapterNumber: 2, lastPageRead: 5, totalPages: 20),
              ],
            ),
          ),
        ];
        final report = ConversionReport();
        final Uint8List bytes = await writer.build(plans, report: report).toData();

        check(writer.validate(bytes, plans)).isEmpty();
        check(report.notes).any(
          (Subject<String> it) => it
            ..contains('"Onimai" (source-one) and "Onimai" (source-two)')
            ..contains('written once'),
        );
        // Each source manga is still accounted on its own.
        check(report.where(RecordKind.manga, RecordDisposition.transferred)).length.equals(2);
        check(report.where(RecordKind.chapterState, RecordDisposition.transferred)).length.equals(3);

        final SourceMangaData written = (await FormatRegistry.portable().codecFor(writer.format)!(bytes))
            .sourceMangaDataEntries
            .single;
        check(written.categories.toSet()).deepEquals(<String>{'Reading', 'Favourites'});
        // Read back as the planner does: history folded into its chapters.
        final List<SourceChapter> state = mergeHistoryIntoChapters(
          written,
        ).$1.where((SourceChapter c) => c.hasReadingState).toList();
        // Chapter 1 folds "read" from one source and page 3 from the other.
        final SourceChapter one = state.firstWhere((SourceChapter c) => c.chapterNumber == 1);
        check(one.isRead).isTrue();
        check(state.any((SourceChapter c) => c.chapterNumber == 2)).isTrue();
      });
    }
  });
}
