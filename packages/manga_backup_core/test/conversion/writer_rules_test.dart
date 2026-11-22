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
}
