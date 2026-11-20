// Characterization of behaviours U1 steps 3-6 changed (now asserting the new
// behaviour).

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:test/scaffolding.dart';

import '../fixtures/paperback_fixtures.dart' as fx;

void main() {
  test('Paperback library entry whose primary source does not resolve is reported as an extraction loss', () {
    final backup = PaperbackBackup.fromData(
      fx.buildPaperbackArchive(<String, Map<String, dynamic>>{
        '__MANGA_INFO_V4': <String, dynamic>{
          'info-A': fx.mangaInfoJson('info-A', titles: <String>['A']),
        },
        '__SOURCE_MANGA_V4': <String, dynamic>{'sm-A': fx.sourceMangaJson('sm-A', mangaInfoId: 'info-A')},
        '__LIBRARY_MANGA_V4': <String, dynamic>{
          'lib-1': fx.libraryMangaJson('lib-1', primarySourceId: 'sm-A'),
          'lib-dangling': fx.libraryMangaJson('lib-dangling', primarySourceId: 'sm-missing'),
        },
      }),
    );
    check(backup.libraryManga).isNotNull().length.equals(2);
    check(backup.sourceMangaDataEntries).length.equals(1);
    // Flipped by U1 step 5: no longer dropped silently.
    check(backup.extractionLosses.single.subject).contains('lib-dangling');
  });
}
