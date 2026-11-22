import 'package:manga_backup_core/src/conversion/source_manga_data.dart';

/// Stable identities for input records. The journal, chapter decisions, and
/// report all key on these, so they depend only on the input backup's
/// content and order, never on runtime state.

String _part(Object? value) => value == null ? '' : '$value';

/// Keys for every manga in [manga], in order. A key is built from the
/// source ID and the source's manga key (or the title when the backup has no
/// key); duplicates get an occurrence suffix (`#2`, `#3`, ...) in input order.
List<String> stableMangaKeys(List<SourceMangaData> manga) {
  final seen = <String, int>{};
  return <String>[
    for (final SourceMangaData m in manga)
      () {
        final base = '${_part(m.sourceId)}|${m.sourceMangaKey ?? 'title:${m.details.title}'}';
        final int n = seen[base] = (seen[base] ?? 0) + 1;
        return n == 1 ? base : '$base#$n';
      }(),
  ];
}

/// Stable key for a source chapter within its manga: its source key when the
/// backup has one, else its numbering, title, and position.
String stableChapterKey(SourceChapter chapter) {
  final prefix = chapter.sourceId == null ? '' : '${chapter.sourceId}:';
  final String? key = chapter.chapterKey;
  if (key != null && key.isNotEmpty) return '$prefix$key';
  return '${prefix}order:${chapter.sourceOrder}|ch:${_part(chapter.chapterNumber)}|vol:${_part(chapter.volumeNumber)}'
      '|t:${chapter.title}';
}
