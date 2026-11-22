import 'dart:convert';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import '../support/test_refs.dart';

void main() {
  final d1 = PluginChapter(chapterId: 'd1', chapterNumber: 1);
  final d2 = PluginChapter(chapterId: 'd2', chapterNumber: 2);
  final s1 = SourceChapter(title: 's1', chapterKey: 's1', chapterNumber: 1, isRead: true);
  final s1b = SourceChapter(title: 's1b', chapterKey: 's1b', chapterNumber: 1, isRead: true);
  final s9 = SourceChapter(title: 's9', chapterKey: 's9', chapterNumber: 9, isRead: true);

  group('applyChapterDecisions', () {
    test('resolving one collision member leaves the other matched only when uniqueness holds', () {
      final ChapterReconciliation base = reconcileChapters(
        sourceChapters: <SourceChapter>[s1, s1b],
        destinationChapters: <PluginChapter>[d1, d2],
      );
      check(base.unresolved.single).isA<ChapterCollision>();

      final ChapterReconciliation moved = applyChapterDecisions(
        base,
        <ChapterDecision>[
          ChapterDecision(sourceChapterKey: stableChapterKey(s1b), destinationChapterId: 'd2'),
        ],
        <PluginChapter>[d1, d2],
      );
      check(moved.matches.map((ChapterMatch m) => '${m.source.chapterKey}->${m.destination.chapterId}').toSet())
          .deepEquals(<String>{'s1->d1', 's1b->d2'});
      check(moved.unresolved).isEmpty();
    });

    test('an exclusion removes state; an unknown destination leaves the chapter unresolved', () {
      final ChapterReconciliation base = reconcileChapters(
        sourceChapters: <SourceChapter>[s9],
        destinationChapters: <PluginChapter>[d1],
      );
      final ChapterReconciliation unknown = applyChapterDecisions(
        base,
        <ChapterDecision>[
          ChapterDecision(sourceChapterKey: stableChapterKey(s9), destinationChapterId: 'missing'),
        ],
        <PluginChapter>[d1],
      );
      check(unknown.unresolved.single).isA<UnmatchedChapter>();

      final ChapterReconciliation excluded = applyChapterDecisions(
        base,
        <ChapterDecision>[
          ChapterDecision.exclude(stableChapterKey(s9)),
        ],
        <PluginChapter>[d1],
      );
      check(excluded.excluded.single.chapterKey).equals('s9');
      check(excluded.unresolved).isEmpty();
    });
  });

  group('stable keys', () {
    test('duplicate manga keys get occurrence suffixes in input order', () {
      final List<String> keys = stableMangaKeys(<SourceMangaData>[
        SourceMangaData(
          details: MangaSearchDetails(title: 'A'),
          sourceId: 's',
        ),
        SourceMangaData(
          details: MangaSearchDetails(title: 'A'),
          sourceId: 's',
        ),
        SourceMangaData(
          details: MangaSearchDetails(title: 'B'),
          sourceId: 's',
          sourceMangaKey: 'k',
        ),
      ]);
      check(keys).deepEquals(<String>['s|title:A', 's|title:A#2', 's|k']);
    });
  });

  group('ConversionJournal', () {
    test('round-trips without session handles or secret values', () {
      const secret = 'p@ssw0rd';
      final settings = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en'},
        secrets: const <String, String>{'password': secret},
      );
      final NativeMangaRef ref = NativeMangaRef(
        source: testIdentity('src'),
        mangaId: '-9223372036854775808',
        settingsRevision: settings.revision,
      ).withHandle(const SessionHandle(generation: 3, value: 'live-object-7'));
      final journal = ConversionJournal(
        inputIdentity: 'in',
        sourceFormat: 'mihon',
        targetFormat: 'aidoku',
        sources: const <JournaledSource>[JournaledSource(extensionId: 'e', cacheKey: 'e-v1')],
        sessions: <JournaledSession>[
          JournaledSession(identity: testIdentity('src'), settingsRevision: settings.revision),
        ],
        confirmations: <String, JournaledConfirmation>{
          'k': JournaledConfirmation(
            decision: MangaDecisionKind.matched,
            ref: ref,
            title: 'T',
            snapshot: FetchedManga(
              MangaSnapshot(
                ref: ref,
                metadata: const MangaMetadata(title: 'T'),
                chapters: const <NativeChapter>[NativeChapter(chapterId: 'c', sourceOrder: 0)],
              ),
            ),
          ),
        },
        chapterDecisions: <String, List<ChapterDecision>>{
          'k': <ChapterDecision>[const ChapterDecision.exclude('s')],
        },
      );
      final String text = jsonEncode(journal.toJson());
      check(text).not((it) => it.contains(secret));
      check(text).not((it) => it.contains('live-object-7'));

      final back = ConversionJournal.fromJson(jsonDecode(text) as Map<String, Object?>);
      final JournaledConfirmation c = back.confirmations['k']!;
      check(c.ref!.mangaId).equals('-9223372036854775808');
      check(c.ref!.settingsRevision).equals(settings.revision);
      check(c.snapshot!.chapters.single.chapterId).equals('c');
      check(back.chapterDecisions['k']!.single.isExclusion).isTrue();
      check(back.sessions.single.identity).equals(testIdentity('src'));

      // Re-entering the secret for the same key keeps the revision.
      final reentered = SettingsSnapshot(
        values: const <String, Object>{'lang': 'en'},
        secrets: const <String, String>{'password': 'different'},
      );
      check(reentered.revision).equals(settings.revision);
    });
  });
}
