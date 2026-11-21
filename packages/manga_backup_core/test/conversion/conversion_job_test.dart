import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import '../support/fakes.dart';
import 'writer_fixtures.dart';

/// Publishes into memory; [bytes] holds the destination's current content.
final class MemoryOutput implements ConversionOutput {
  MemoryOutput([this.bytes]);

  Uint8List? bytes;
  int publishes = 0;

  @override
  Future<void> publish(Uint8List data) async {
    publishes++;
    bytes = Uint8List.fromList(data);
  }
}

/// Destination identities per ecosystem, as each runtime would return them.
const Map<String, String> _destinationSourceIds = <String, String>{
  'aidoku': 'en.weebcentral',
  'paperback': 'WeebCentral',
  'tachi': '2131019126180322627',
};

String _ecosystemOf(BackupFormat f) => switch (f) {
  Aidoku() => 'aidoku',
  Paperback() => 'paperback',
  _ => 'tachi',
};

/// A destination runtime backed by one fake source that knows "Onimai".
DestinationRuntime _runtime(
  String ecosystem,
  List<String> calls, {
  List<NativeChapter>? chapters,
  SourceFailure? detailsFailure,
  SourceFailure? Function()? probe,
}) {
  final String sourceId = _destinationSourceIds[ecosystem]!;
  final bool tachi = ecosystem == 'tachi';
  return DestinationRuntime(
    ecosystem: ecosystem,
    serves: (BackupFormat f) => _ecosystemOf(f) == ecosystem,
    probe: probe ?? () => null,
    createLoader: () {
      calls.add(ecosystem);
      return FakePluginLoader(
        sources: <PluginSource>[
          FakePluginSource(
            sourceId,
            manga: <FakeManga>[
              FakeManga(
                tachi ? '/series/onimai' : 'onimai',
                'Onimai',
                failure: detailsFailure,
                chapters: chapters ?? destinationChapters(prefix: tachi ? '/chapters/' : 'ch-'),
              ),
            ],
          ),
        ],
      );
    },
  );
}

/// An input backup of [format] carrying read, partial and (Tachi) bookmark
/// state, written by the format's own writer from a fetched source manga.
Future<Uint8List> _input(BackupFormat format) async {
  final String ecosystem = _ecosystemOf(format);
  final TargetBackupBuilder writer = FormatRegistry.portable().writerFor(format)!;
  final MangaMatchConfirmation c = fetchedConfirmation(
    statefulManga(title: 'Onimai'),
    runtimeIdentity(ecosystem, ecosystem == 'tachi' ? '1234567890123456789' : 'origin.src'),
    mangaId: 'origin-manga',
    chapters: destinationChapters(prefix: 'origin-'),
    title: 'Onimai',
  );
  return writer.build(<MangaConversionPlan>[planConversion(c)]).toData();
}

ConversionJob _job(
  RuntimeRegistry runtimes, {
  bool acceptPartial = true,
  FormatRegistry? formats,
  SourceLanguagePolicy? languages,
  List<String>? searched,
}) => ConversionJob(
  formats: formats ?? FormatRegistry.portable(),
  runtimes: runtimes,
  languagePolicy: languages,
  selection: CallbackSelectionPort(
    onSelectExtensions: (List<ExtensionEntry> e) async => e,
    onConfirmMatches: (List<String> names, List<SourceMangaData> manga, onSearch, onFetch) {
      searched?.addAll(names);
      return confirmExactTitle(names, manga, onSearch, onFetch);
    },
    acceptPartial: acceptPartial,
  ),
);

ConversionRequest _request(Uint8List input, BackupFormat source, BackupFormat target) => ConversionRequest(
  input: input,
  sourceFormat: source,
  targetFormat: target,
  repoUrls: const <String>['https://repo.invalid'],
);

void main() {
  const directions = <(BackupFormat, BackupFormat)>[
    (Paperback(), Aidoku()),
    (Aidoku(), Paperback()),
    (Paperback(), Mihon()),
    (Mihon(), Paperback()),
    (Aidoku(), Mihon()),
    (Mihon(), Aidoku()),
  ];

  group('all six R5 directions', () {
    for (final (BackupFormat source, BackupFormat target) in directions) {
      test('$source → $target runs the $target runtime and publishes a valid, fully accounted backup', () async {
        final calls = <String>[];
        final runtimes = RuntimeRegistry(<DestinationRuntime>[
          for (final String e in _destinationSourceIds.keys) _runtime(e, calls),
        ]);
        final Uint8List input = await _input(source);
        final inputCopy = Uint8List.fromList(input);
        final output = MemoryOutput();

        final ConversionResult result = await _job(runtimes).run(_request(input, source, target), output);

        // Only the selected destination runtime ran.
        check(calls).deepEquals(<String>[_ecosystemOf(target)]);
        check(output.publishes).equals(1);
        check(input).deepEquals(inputCopy);
        final Uint8List published = output.bytes!;
        check(published).deepEquals(result.draft.bytes);
        // Structurally valid against the plans, and decodable by the codec.
        check(FormatRegistry.portable().writerFor(target)!.validate(published, result.draft.plans)).isEmpty();
        final ConvertableBackup reread = await FormatRegistry.portable().codecFor(target)!(published);
        final SourceMangaData out = reread.sourceMangaDataEntries.single;
        check(out.sourceMangaKey).equals(_ecosystemOf(target) == 'tachi' ? '/series/onimai' : 'onimai');

        // Complete accounting: every state-bearing input chapter ends in
        // exactly one disposition, and each manga is transferred.
        final ConversionReport report = result.report;
        // History is folded into its chapters first, as the planner does.
        final int stateful = mergeHistoryIntoChapters(result.input.sourceMangaDataEntries.single).$1
            .where((SourceChapter c) => c.hasReadingState)
            .length;
        check(report.count(RecordKind.chapterState)).equals(stateful);
        check(report.count(RecordKind.chapterState, RecordDisposition.transferred)).equals(stateful);
        check(report.count(RecordKind.manga, RecordDisposition.transferred)).equals(1);
        // Read and partial state survive in the destination (AE2).
        final List<SourceChapter> state = out.chapters.where((SourceChapter c) => c.hasReadingState).toList();
        check(state.where((SourceChapter c) => c.isRead)).isNotEmpty();
      });
    }
  });

  test('AE3: an ambiguous destination is not published without explicit acceptance', () async {
    final ambiguous = <NativeChapter>[
      const NativeChapter(chapterId: 'a', sourceOrder: 0, chapterNumber: 1, title: 'Chapter 1'),
      const NativeChapter(chapterId: 'b', sourceOrder: 1, chapterNumber: 1, title: 'Chapter 1'),
      const NativeChapter(chapterId: 'c', sourceOrder: 2, chapterNumber: 2, title: 'Chapter 2'),
      const NativeChapter(chapterId: 'd', sourceOrder: 3, chapterNumber: 3, title: 'Chapter 3'),
    ];
    final runtimes = RuntimeRegistry(<DestinationRuntime>[_runtime('aidoku', <String>[], chapters: ambiguous)]);
    final Uint8List input = await _input(const Mihon());
    final output = MemoryOutput(Uint8List.fromList(<int>[9, 9, 9]));

    final PartialConversionDeclined declined = await _caught<PartialConversionDeclined>(
      _job(runtimes, acceptPartial: false).run(_request(input, const Mihon(), const Aidoku()), output),
    );
    check(declined.report.where(RecordKind.chapterState, RecordDisposition.unresolved)).length.equals(1);
    check(output.publishes).equals(0);
    check(output.bytes!).deepEquals(<int>[9, 9, 9]);

    final ConversionResult accepted = await _job(runtimes).run(_request(input, const Mihon(), const Aidoku()), output);
    check(accepted.partialAccepted).isTrue();
    final backup = accepted.draft.backup as AidokuBackup;
    // Neither candidate for chapter 1 received the transferred history.
    final Set<String> withHistory = backup.history!.map((AidokuBackupHistory h) => h.chapterId).toSet();
    check(withHistory.intersection(<String>{'a', 'b'})).isEmpty();
  });

  test('AE5: invalid output publishes nothing; input and the existing destination stay unchanged', () async {
    final runtimes = RuntimeRegistry(<DestinationRuntime>[_runtime('aidoku', <String>[])]);
    final formats = FormatRegistry.portable()..registerWriter(const _InvalidWriter());
    final Uint8List input = await _input(const Paperback());
    final inputCopy = Uint8List.fromList(input);
    final existing = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final output = MemoryOutput(existing);

    final InvalidConversionOutput invalid = await _caught<InvalidConversionOutput>(
      _job(runtimes, formats: formats).run(_request(input, const Paperback(), const Aidoku()), output),
    );
    check(invalid.problems).contains('history points at a non-fetched chapter');
    check(output.publishes).equals(0);
    check(output.bytes!).deepEquals(<int>[1, 2, 3, 4]);
    check(input).deepEquals(inputCopy);
  });

  test('a runtime failure publishes nothing', () async {
    final runtimes = RuntimeRegistry(<DestinationRuntime>[
      DestinationRuntime(
        ecosystem: 'aidoku',
        serves: (BackupFormat f) => f is Aidoku,
        createLoader: () => FakePluginLoader(load: (_) async => throw const MigrationException('worker died')),
      ),
    ]);
    final output = MemoryOutput();
    await check(
      _job(runtimes).run(_request(await _input(const Mihon()), const Mihon(), const Aidoku()), output),
    ).throws<MigrationException>();
    check(output.publishes).equals(0);
  });

  test('an Aidoku destination detail failure stays unresolved; publication needs acceptance', () async {
    final runtimes = RuntimeRegistry(<DestinationRuntime>[
      _runtime('aidoku', <String>[], detailsFailure: const SourceErrorFailure('HTTP 500')),
    ]);
    final Uint8List input = await _input(const Mihon());
    final output = MemoryOutput();
    await check(
      _job(runtimes, acceptPartial: false).run(_request(input, const Mihon(), const Aidoku()), output),
    ).throws<PartialConversionDeclined>();
    check(output.publishes).equals(0);

    final ConversionResult r = await _job(runtimes).run(_request(input, const Mihon(), const Aidoku()), output);
    final ReportEntry manga = r.report.where(RecordKind.manga, RecordDisposition.unresolved).single;
    check(manga.reason).isNotNull().contains('HTTP 500');
    check(r.report.failures.single.stage).equals(FailureStage.details);
    // No empty-chapter success: the manga is not in the published backup.
    check((r.draft.backup as AidokuBackup).manga).isNotNull().isEmpty();
  });

  test('a destination is enabled only when its writer and runtime are available', () async {
    final runtimes = RuntimeRegistry(<DestinationRuntime>[
      _runtime('aidoku', <String>[]),
      _runtime('tachi', <String>[], probe: () => const RuntimeUnavailableFailure('no JVM worker')),
    ]);
    final ConversionJob job = _job(runtimes);
    check(job.enabled(const Paperback(), const Aidoku())).isTrue();
    check(job.unavailable(const Aidoku(), const Mihon())).isA<RuntimeUnavailableFailure>();
    check(job.unavailable(const Aidoku(), const Paperback())).isA<CapabilityUnavailableFailure>();
    // No verified writer for SY yet.
    check(job.unavailable(const Aidoku(), const TachiSy())!.message).contains('writer');
    // A direct pair needs the direct converter (the CLI registers it).
    check(job.unavailable(const Mihon(), const Tachimanga())!.message).contains('direct');

    final output = MemoryOutput();
    await check(
      job.run(_request(await _input(const Aidoku()), const Aidoku(), const Mihon()), output),
    ).throws<DestinationUnavailable>();
    check(output.publishes).equals(0);
  });

  group('language narrowing', () {
    RuntimeRegistry multiLanguage(List<String> calls) => RuntimeRegistry(<DestinationRuntime>[
      DestinationRuntime(
        ecosystem: 'tachi',
        serves: (BackupFormat f) => f is Tachiyomi,
        createLoader: () => FakePluginLoader(
          sources: <PluginSource>[
            for (final (String id, String lang) in <(String, String)>[('1', 'en'), ('2', 'ja'), ('3', 'all')])
              FakePluginSource(
                id,
                language: lang,
                manga: <FakeManga>[FakeManga('/m', 'Onimai', chapters: destinationChapters(prefix: '/c'))],
              ),
          ],
        ),
      ),
    ]);

    Future<Uint8List> englishAidoku() async {
      final MangaMatchConfirmation c = fetchedConfirmation(
        statefulManga(language: 'en'),
        runtimeIdentity('aidoku', 'en.origin'),
        mangaId: 'o',
        chapters: destinationChapters(prefix: 'o-'),
        title: 'Onimai',
      );
      return const AidokuBackupBuilder().build(<MangaConversionPlan>[planConversion(c)]).toData();
    }

    test("a multi-source package is narrowed to the backup's languages plus multi-language sources", () async {
      final searched = <String>[];
      final ConversionResult r = await _job(
        multiLanguage(<String>[]),
        searched: searched,
      ).run(_request(await englishAidoku(), const Aidoku(), const Mihon()), MemoryOutput());
      check(searched).deepEquals(<String>['Fake 1', 'Fake 3']);
      check(r.report.notes).any((Subject<String> it) => it.contains('Only sources in en'));
      check(r.report.notes).any((Subject<String> it) => it.contains('1 loaded source(s) of other languages'));
    });

    test('--languages overrides the inferred languages', () async {
      final searched = <String>[];
      await _job(
        multiLanguage(<String>[]),
        searched: searched,
        languages: SourceLanguagePolicy.parse('ja'),
      ).run(_request(await englishAidoku(), const Aidoku(), const Mihon()), MemoryOutput());
      check(searched).deepEquals(<String>['Fake 2', 'Fake 3']);
    });

    test('a backup with no recorded language searches every source and says so', () async {
      final searched = <String>[];
      final ConversionResult r = await _job(
        multiLanguage(<String>[]),
        searched: searched,
      ).run(_request(await _input(const Mihon()), const Mihon(), const Mihon()), MemoryOutput());
      check(searched).length.equals(3);
      check(r.report.notes).any((Subject<String> it) => it.contains('records no content language'));
    });

    test('entries are narrowed by their listed languages; unrecognised codes are kept', () {
      final policy = SourceLanguagePolicy.parse('pt');
      const entries = <ExtensionEntry>[
        StubExtensionEntry(id: 'br', name: 'BR', languages: <String>['pt-BR']),
        StubExtensionEntry(id: 'en', name: 'EN', languages: <String>['en']),
        StubExtensionEntry(id: 'multi', name: 'Multi', languages: <String>['multi']),
        StubExtensionEntry(id: 'flag', name: 'Flag', languages: <String>['🇬🇧']),
      ];
      final ({int hidden, List<ExtensionEntry> visible}) r = policy.apply(entries);
      check(r.visible.map((ExtensionEntry e) => e.id)).deepEquals(<String>['br', 'multi', 'flag']);
      check(r.hidden).equals(1);
      check(() => SourceLanguagePolicy.parse('not a code!')).throws<FormatException>();
      check(SourceLanguagePolicy.parse('all').languages).isNull();
    });
  });
}

/// The [T] that [run] fails with.
Future<T> _caught<T extends Object>(Future<Object?> run) async {
  try {
    await run;
  } on T catch (e) {
    return e;
  }
  throw StateError('expected the run to fail with $T');
}

/// An Aidoku writer whose validation always finds a problem.
final class _InvalidWriter extends AidokuBackupBuilder {
  const _InvalidWriter();

  @override
  List<String> validate(Uint8List bytes, List<MangaConversionPlan> plans) => const <String>[
    'history points at a non-fetched chapter',
  ];
}
