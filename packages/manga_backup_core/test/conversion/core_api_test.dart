// Uses only the public barrel plus injected fakes: no CLI presentation and no
// concrete source runtime.
import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import '../fixtures/paperback_fixtures.dart' as fx;
import '../support/fakes.dart';

void main() {
  test('the core API converts a Paperback fixture to Aidoku with injected source, selection and output', () async {
    final source = FakePluginSource(
      'dest',
      manga: <FakeManga>[
        FakeManga(
          'remote-a',
          'Library Title A',
          chapters: <NativeChapter>[
            const NativeChapter(chapterId: 'x1', sourceOrder: 0, chapterNumber: 1, title: 'One'),
            const NativeChapter(chapterId: 'x2', sourceOrder: 1, chapterNumber: 2, title: 'Two'),
          ],
        ),
      ],
    );
    final journal = InMemoryJournalStore();
    final ConversionDraft draft =
        await MigrationPipeline(
          repoUrls: const <String>['https://repo.invalid'],
          session: ConversionSession(
            selection: CallbackSelectionPort(
              onSelectExtensions: (List<ExtensionEntry> e) async => e,
              onConfirmMatches: confirmExactTitle,
            ),
            journalStore: journal,
          ),
        ).execute(
          MigrationRoute(
            writer: const AidokuBackupBuilder(),
            loader: FakePluginLoader(sources: <PluginSource>[source]),
          ),
          sourceBackup: PaperbackBackup.fromData(fx.libraryLinkageArchive()),
          sourceFormat: const Paperback(),
          targetFormat: const Aidoku(),
          inputIdentity: 'fixture',
        );

    final backup = draft.backup as AidokuBackup;
    check(backup.manga!.single.id).equals('remote-a');
    final history = <String, AidokuBackupHistory>{
      for (final AidokuBackupHistory h in backup.history!) h.chapterId: h,
    };
    check(history['x1']!.completed).isTrue();
    check(history['x2']!.completed).isFalse();
    check(history['x2']!.progress).equals(7);
    check(draft.report.isPartial).isFalse();
    // The output adapter decides when to drop the journal (after publishing).
    check(journal.json).isNotNull();
    final List<int> bytes = await backup.toData();
    check(bytes).isNotEmpty();
  });
}
