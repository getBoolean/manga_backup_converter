import 'package:checks/checks.dart';
import 'package:manga_backup_core/src/conversion/plugin_source.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';
import 'package:manga_backup_core/src/reconciliation/chapter_reconciler.dart';
import 'package:test/scaffolding.dart';

Map<String, String> _matchedIds(ChapterReconciliation r) => <String, String>{
  for (final ChapterMatch m in r.matches) m.source.title: m.destination.chapterId,
};

void main() {
  group('known-value normalization', () {
    test('chapter numbers: -1 and non-finite are unknown, 0 is a real chapter', () {
      check(knownChapterNumber(-1)).isNull();
      check(knownChapterNumber(double.nan)).isNull();
      check(knownChapterNumber(null)).isNull();
      check(knownChapterNumber(0)).equals(0);
      check(knownChapterNumber(12.5)).equals(12.5);
    });

    test('volumes: 0 and negative are unknown', () {
      check(knownVolumeNumber(0)).isNull();
      check(knownVolumeNumber(-1)).isNull();
      check(knownVolumeNumber(2)).equals(2);
    });

    test('languages compare by primary subtag', () {
      check(knownLanguage('en-US')).equals('en');
      check(knownLanguage('pt_BR')).equals('pt');
      check(knownLanguage('')).isNull();
      check(knownLanguage('unknown')).isNull();
    });

    test('a value that is not a language code (a flag emoji) is unknown, not a conflicting language', () {
      check(knownLanguage('🇬🇧')).isNull();
      check(knownLanguage('English')).isNull();
    });

    test('scanlator groups are split', () {
      check(scanlatorGroups('Alpha & Beta, Gamma')).deepEquals(<String>{'alpha', 'beta', 'gamma'});
      check(scanlatorGroups(null)).isEmpty();
    });
  });

  group('reconcileChapters', () {
    test('a flag-emoji destination language does not reject an en source chapter', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[SourceChapter(title: 'Step 1', chapterNumber: 1, language: 'en', isRead: true)],
        destinationChapters: <PluginChapter>[PluginChapter(chapterId: 'd1', chapterNumber: 1, language: '🇬🇧')],
      );
      check(_matchedIds(r)).deepEquals(<String, String>{'Step 1': 'd1'});
    });

    test('a destination without chapter numbers is matched only by a unique exact title', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[
          SourceChapter(title: 'Step 1', chapterNumber: 1, isRead: true),
          SourceChapter(title: 'Extra', chapterNumber: 2, isRead: true),
          SourceChapter(title: 'Step 9', chapterNumber: 9, isRead: true),
        ],
        destinationChapters: <PluginChapter>[
          PluginChapter(chapterId: 'd1', title: 'Step 1'),
          PluginChapter(chapterId: 'e1', title: 'Extra'),
          PluginChapter(chapterId: 'e2', title: 'Extra'),
        ],
      );
      check(_matchedIds(r)).deepEquals(<String, String>{'Step 1': 'd1'});
      check(r.unresolved.whereType<AmbiguousChapter>().single.source.title).equals('Extra');
      check(r.unresolved.whereType<UnmatchedChapter>().single.source.title).equals('Step 9');
    });

    test('unique number match transfers', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[SourceChapter(title: 's1', chapterNumber: 1, isRead: true)],
        destinationChapters: <PluginChapter>[
          PluginChapter(chapterId: 'd1', chapterNumber: 1),
          PluginChapter(chapterId: 'd2', chapterNumber: 2),
        ],
      );
      check(_matchedIds(r)).deepEquals(<String, String>{'s1': 'd1'});
      check(r.unresolved).isEmpty();
    });

    test('chapter 0 is a real match key', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[SourceChapter(title: 'Prologue', chapterNumber: 0, isRead: true)],
        destinationChapters: <PluginChapter>[PluginChapter(chapterId: 'd0', title: 'Intro', chapterNumber: 0)],
      );
      check(_matchedIds(r)).deepEquals(<String, String>{'Prologue': 'd0'});
    });

    test('unknown numbers never match each other; exact title still identifies', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[
          SourceChapter(title: 'Oneshot', chapterNumber: -1, isRead: true),
          SourceChapter(title: 'Extra', chapterNumber: -1, isRead: true),
          SourceChapter(title: '', chapterNumber: -1, isRead: true),
        ],
        destinationChapters: <PluginChapter>[
          PluginChapter(chapterId: 'd-oneshot', title: 'oneshot', chapterNumber: -1),
          PluginChapter(chapterId: 'd-other', title: 'Side Story', chapterNumber: -1),
          PluginChapter(chapterId: 'd-untitled', chapterNumber: -1),
        ],
      );
      check(_matchedIds(r)).deepEquals(<String, String>{'Oneshot': 'd-oneshot'});
      check(r.unresolved.whereType<UnmatchedChapter>()).length.equals(2);
    });

    test('conflicting known volume rejects; unknown volume does not', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[
          SourceChapter(title: 'v2c1', chapterNumber: 1, volumeNumber: 2, isRead: true),
          SourceChapter(title: 'v0c3', chapterNumber: 3, volumeNumber: 0, isRead: true),
        ],
        destinationChapters: <PluginChapter>[
          PluginChapter(chapterId: 'd-v1c1', chapterNumber: 1, volumeNumber: 1),
          PluginChapter(chapterId: 'd-v1c3', chapterNumber: 3, volumeNumber: 1),
        ],
      );
      check(_matchedIds(r)).deepEquals(<String, String>{'v0c3': 'd-v1c3'});
      check(r.unresolved.single).isA<UnmatchedChapter>();
    });

    test('title narrows duplicate numbers', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[SourceChapter(title: 'The Return', chapterNumber: 10, isRead: true)],
        destinationChapters: <PluginChapter>[
          PluginChapter(chapterId: 'd-10a', title: 'the  return', chapterNumber: 10),
          PluginChapter(chapterId: 'd-10b', title: 'Announcement', chapterNumber: 10),
        ],
      );
      check(_matchedIds(r)).deepEquals(<String, String>{'The Return': 'd-10a'});
    });

    test('multiple scanlators: overlapping group narrows, no overlap stays ambiguous', () {
      final destinations = <PluginChapter>[
        PluginChapter(chapterId: 'd-a', chapterNumber: 4, scanlator: 'Alpha'),
        PluginChapter(chapterId: 'd-b', chapterNumber: 4, scanlator: 'Beta'),
      ];
      final ChapterReconciliation joint = reconcileChapters(
        sourceChapters: <SourceChapter>[SourceChapter(title: 'c4', chapterNumber: 4, scanlator: 'Beta & Gamma')],
        destinationChapters: destinations,
      );
      check(_matchedIds(joint)).deepEquals(<String, String>{'c4': 'd-b'});

      final ChapterReconciliation unknownGroup = reconcileChapters(
        sourceChapters: <SourceChapter>[SourceChapter(title: 'c4', chapterNumber: 4, scanlator: 'Delta')],
        destinationChapters: destinations,
      );
      check(unknownGroup.matches).isEmpty();
      check(
        unknownGroup.unresolved.single,
      ).isA<AmbiguousChapter>().has((AmbiguousChapter a) => a.candidates.length, 'n').equals(2);
    });

    test('title and scanlator pointing at different chapters is ambiguous', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[
          SourceChapter(title: 'The Return', chapterNumber: 10, scanlator: 'Alpha', isRead: true),
        ],
        destinationChapters: <PluginChapter>[
          PluginChapter(chapterId: 'd-title', title: 'The Return', chapterNumber: 10, scanlator: 'Beta'),
          PluginChapter(chapterId: 'd-group', title: 'Chapter 10', chapterNumber: 10, scanlator: 'Alpha'),
        ],
      );
      check(r.matches).isEmpty();
      check(r.unresolved.single).isA<AmbiguousChapter>();
    });

    test('title and scanlator agreeing on one chapter matches it', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[
          SourceChapter(title: 'The Return', chapterNumber: 10, scanlator: 'Alpha', isRead: true),
        ],
        destinationChapters: <PluginChapter>[
          PluginChapter(chapterId: 'd-both', title: 'The Return', chapterNumber: 10, scanlator: 'Alpha'),
          PluginChapter(chapterId: 'd-group', title: 'Chapter 10', chapterNumber: 10, scanlator: 'Alpha'),
          PluginChapter(chapterId: 'd-other', title: 'Chapter 10', chapterNumber: 10, scanlator: 'Beta'),
        ],
      );
      check(_matchedIds(r)).deepEquals(<String, String>{'The Return': 'd-both'});
    });

    test('global collision: two sources selecting one destination both stay unresolved', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[
          SourceChapter(title: 'c7 alpha', chapterNumber: 7, scanlator: 'Alpha', isRead: true),
          SourceChapter(title: 'c7 beta', chapterNumber: 7, scanlator: 'Beta', lastPageRead: 2),
          SourceChapter(title: 'c8', chapterNumber: 8, isRead: true),
        ],
        destinationChapters: <PluginChapter>[
          PluginChapter(chapterId: 'd7', chapterNumber: 7),
          PluginChapter(chapterId: 'd8', chapterNumber: 8),
        ],
      );
      check(_matchedIds(r)).deepEquals(<String, String>{'c8': 'd8'});
      final ChapterCollision collision = r.unresolved.whereType<ChapterCollision>().single;
      check(collision.destination.chapterId).equals('d7');
      check(collision.sources.map((SourceChapter s) => s.title).toList()).deepEquals(<String>['c7 alpha', 'c7 beta']);
    });

    test('exact chapter IDs match only within a verified same source identity', () {
      final sources = <SourceChapter>[
        SourceChapter(title: 'renamed', chapterKey: '/chapter/abc', chapterNumber: -1, isRead: true),
      ];
      final destinations = <PluginChapter>[
        PluginChapter(chapterId: '/chapter/abc', title: 'Chapter 1', chapterNumber: 1),
      ];

      check(
        _matchedIds(
          reconcileChapters(sourceChapters: sources, destinationChapters: destinations, sameSourceIdentity: true),
        ),
      ).deepEquals(<String, String>{'renamed': '/chapter/abc'});
      // Equal ID strings across different sources are not evidence.
      check(reconcileChapters(sourceChapters: sources, destinationChapters: destinations).matches).isEmpty();
    });

    test('no destination snapshot leaves every chapter unmatched', () {
      final ChapterReconciliation r = reconcileChapters(
        sourceChapters: <SourceChapter>[SourceChapter(title: 'c1', chapterNumber: 1, isRead: true)],
        destinationChapters: const <PluginChapter>[],
      );
      check(r.matches).isEmpty();
      check(r.unresolved.single).isA<UnmatchedChapter>();
    });
  });
}
