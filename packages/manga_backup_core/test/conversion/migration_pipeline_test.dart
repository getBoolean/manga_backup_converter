import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import '../support/fakes.dart';

const List<String> _repos = <String>['https://repo.invalid/index.json'];

MigrationPipeline _pipeline({
  required PluginLoader loader,
  SelectionPort? selection,
  OnConfirmMatches onConfirmMatches = confirmExactTitle,
  bool acceptPartial = false,
  JournalStore? journalStore,
  SourceRatingPolicy ratingPolicy = const SourceRatingPolicy(),
  TrustStore? trustStore,
  FutureOr<void> Function(ConversionOwner owner)? onOwnerOpened,
  DirectConverter? directConverter,
  FormatRegistry? formats,
  SourceLanguagePolicy? languagePolicy,
  String Function(String)? redact,
}) => MigrationPipeline(
  repoUrls: _repos,
  pluginLoader: loader,
  selection:
      selection ??
      CallbackSelectionPort(
        onSelectExtensions: (List<ExtensionEntry> e) async => e,
        onConfirmMatches: onConfirmMatches,
        acceptPartial: acceptPartial,
      ),
  onProgress: (_, _, _) {},
  journalStore: journalStore,
  ratingPolicy: ratingPolicy,
  trustStore: trustStore,
  onOwnerOpened: onOwnerOpened,
  directConverter: directConverter,
  formats: formats,
  languagePolicy: languagePolicy,
  redact: redact ?? (String s) => s,
);

Future<ConversionDraft> _run(MigrationPipeline pipeline, ConvertableBackup backup, {String? inputIdentity}) =>
    pipeline.run(
      sourceBackup: backup,
      sourceFormat: const Mihon(),
      targetFormat: const Aidoku(),
      inputIdentity: inputIdentity,
    );

void main() {
  group('MigrationPipeline', () {
    test('passes every source manga to the selection port and builds the confirmed matches', () async {
      final source = FakePluginSource(
        'dest',
        manga: <FakeManga>[
          FakeManga('k1', 'Alpha', chapters: <NativeChapter>[nativeChapter('c1', 1)]),
        ],
      );
      List<SourceMangaData>? received;
      final ConversionDraft draft = await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[source]),
          onConfirmMatches: (names, manga, onSearch, onFetch) {
            received = manga;
            return confirmExactTitle(names, manga, onSearch, onFetch);
          },
        ),
        FakeBackup(<SourceMangaData>[sourceManga('Alpha')]),
      );
      check(received).isNotNull().length.equals(1);
      final backup = draft.backup as AidokuBackup;
      check(backup.manga!.single.id).equals('k1');
      check(backup.chapters!.single.id).equals('c1');
      check(draft.report.isPartial).isFalse();
    });

    test('direct conversion uses the injected converter and needs one', () async {
      final input = FakeBackup(const <SourceMangaData>[]);
      final output = FakeBackup(const <SourceMangaData>[]);
      final FormatRegistry formats = FormatRegistry.portable()
        ..registerCodec(const Tachimanga(), (Uint8List bytes, {String? name}) async => output);
      final ConversionDraft draft = await _pipeline(
        loader: FakePluginLoader(),
        formats: formats,
        directConverter: (ConvertableBackup s, BackupFormat t, ConversionReport r) => output,
      ).run(sourceBackup: input, sourceFormat: const Mihon(), targetFormat: const Tachimanga());
      check(identical(draft.backup, output)).isTrue();
      await check(
        _pipeline(
          loader: FakePluginLoader(),
        ).run(sourceBackup: input, sourceFormat: const Mihon(), targetFormat: const Tachimanga()),
      ).throws<DestinationUnavailable>();
    });

    test('forceMigration takes the plugin path for a direct-conversion pair', () async {
      var migrated = false;
      final ConversionDraft draft =
          await _pipeline(
            loader: FakePluginLoader(sources: <PluginSource>[FakePluginSource('dest')]),
            onConfirmMatches: (_, List<SourceMangaData> manga, _, _) async {
              migrated = true;
              return const <MangaMatchConfirmation>[];
            },
            acceptPartial: true,
          ).run(
            sourceBackup: FakeBackup(<SourceMangaData>[sourceManga('A')]),
            sourceFormat: const Tachimanga(),
            targetFormat: const Mihon(),
            forceMigration: true,
          );
      check(migrated).isTrue();
      check(draft.backup).isA<TachiBackup>();
    });

    test('forcing migration onto a format with no writer is a typed failure before any source work', () async {
      var migrated = false;
      DestinationUnavailable? caught;
      try {
        await _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[FakePluginSource('dest')]),
          onConfirmMatches: (_, List<SourceMangaData> manga, _, _) async {
            migrated = true;
            return const <MangaMatchConfirmation>[];
          },
        ).run(
          sourceBackup: FakeBackup(<SourceMangaData>[sourceManga('A')]),
          sourceFormat: const Mihon(),
          targetFormat: const Tachimanga(),
          forceMigration: true,
        );
      } on DestinationUnavailable catch (e) {
        caught = e;
      }
      check(caught?.failure.code).equals('capability-unavailable');
      check(migrated).isFalse();
    });

    test('streams search start and results per plugin', () async {
      late Stream<PluginSearchEvent> Function(String) captured;
      await _run(
        _pipeline(
          loader: FakePluginLoader(
            sources: <PluginSource>[
              FakePluginSource('dest', manga: <FakeManga>[FakeManga('k', 'Alpha')]),
            ],
          ),
          onConfirmMatches: (_, List<SourceMangaData> manga, onSearch, _) async {
            captured = onSearch;
            return <MangaMatchConfirmation>[
              for (final m in manga) MangaMatchConfirmation(sourceManga: m, excluded: true),
            ];
          },
        ),
        FakeBackup(<SourceMangaData>[sourceManga('Alpha')]),
      );
      final List<PluginSearchEvent> events = await captured('Alpha').toList();
      check(events.first).isA<PluginSearchStarted>();
      check(events.last).isA<PluginSearchResults>().has((PluginSearchResults r) => r.results.length, 'n').equals(1);
    });
  });

  group('conversion owner', () {
    test('a plugin loaded before a later load failure is closed before the failure is returned', () async {
      final first = FakePluginSource('first');
      var scopeClosed = false;
      final Future<ConversionDraft> run = _run(
        _pipeline(
          loader: FakePluginLoader(
            load: (ConversionOwner? owner) async {
              await owner!.adopt(first.dispose);
              throw StateError('second package failed');
            },
          ),
          onOwnerOpened: (ConversionOwner owner) => owner.adopt(() async {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            scopeClosed = true;
          }),
        ),
        FakeBackup(<SourceMangaData>[sourceManga('A')]),
      );
      await check(run).throws<StateError>();
      check(first.disposed).equals(1);
      check(scopeClosed).isTrue();
    });

    test('every loaded plugin is disposed once after a successful run', () async {
      final source = FakePluginSource('dest');
      await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[source]),
          acceptPartial: true,
        ),
        FakeBackup(<SourceMangaData>[sourceManga('A')]),
      );
      check(source.disposed).equals(1);
    });
  });

  group('typed detail outcomes', () {
    test('a failed details fetch leaves the manga unresolved with its failure, not built with no chapters', () async {
      final source = FakePluginSource(
        'dest',
        manga: <FakeManga>[FakeManga('k', 'Alpha', failure: const SourceErrorFailure('plugin returned no details'))],
      );
      final backup = FakeBackup(<SourceMangaData>[
        sourceManga('Alpha', chapters: <SourceChapter>[SourceChapter(title: 'c1', chapterNumber: 1, isRead: true)]),
      ]);
      final PluginLoader loader = FakePluginLoader(sources: <PluginSource>[source]);

      final Future<ConversionDraft> declined = _run(_pipeline(loader: loader), backup);
      await check(declined).throws<PartialConversionDeclined>();

      final ConversionDraft draft = await _run(_pipeline(loader: loader, acceptPartial: true), backup);
      check((draft.backup as AidokuBackup).manga).isNotNull().isEmpty();
      final ReportEntry manga = draft.report.where(RecordKind.manga, RecordDisposition.unresolved).single;
      check(manga.reason).isNotNull().contains('source-error');
      check(draft.report.count(RecordKind.chapterState, RecordDisposition.transferred)).equals(0);
      check(draft.report.count(RecordKind.chapterState, RecordDisposition.unresolved)).equals(1);
      check(draft.report.failures.single.stage).equals(FailureStage.details);
      check(draft.partialAccepted).isTrue();
    });

    test('a successful fetch with no chapters builds the manga without chapters', () async {
      final ConversionDraft draft = await _run(
        _pipeline(
          loader: FakePluginLoader(
            sources: <PluginSource>[
              FakePluginSource('dest', manga: <FakeManga>[FakeManga('k', 'Alpha')]),
            ],
          ),
        ),
        FakeBackup(<SourceMangaData>[sourceManga('Alpha')]),
      );
      final backup = draft.backup as AidokuBackup;
      check(backup.manga!.single.id).equals('k');
      check(backup.chapters).isNull();
      check(draft.report.isPartial).isFalse();
    });

    test('one source succeeding beside another needing interaction keeps both in the report', () async {
      final ConversionDraft draft = await _run(
        _pipeline(
          loader: FakePluginLoader(
            sources: <PluginSource>[
              FakePluginSource('ok', manga: <FakeManga>[FakeManga('k', 'Alpha')]),
              FakePluginSource('challenge', searchFailure: const InteractionRequiredFailure('captcha')),
            ],
          ),
        ),
        FakeBackup(<SourceMangaData>[sourceManga('Alpha')]),
      );
      check(draft.report.count(RecordKind.manga, RecordDisposition.transferred)).equals(1);
      final SourceFailureRecord failure = draft.report.failures.single;
      check(failure.stage).equals(FailureStage.search);
      check(failure.code).equals('interaction-required');
      check(failure.manga).equals('Alpha');
    });
  });

  group('partial acceptance', () {
    final unmatched = FakeBackup(<SourceMangaData>[sourceManga('Nowhere')]);
    PluginLoader loader() => FakePluginLoader(sources: <PluginSource>[FakePluginSource('dest')]);

    test('an unattended partial conversion publishes nothing without --accept-partial', () async {
      await check(_run(_pipeline(loader: loader()), unmatched)).throws<PartialConversionDeclined>();
    });

    test('--accept-partial (the port default) accepts and records the decision', () async {
      final ConversionDraft draft = await _run(_pipeline(loader: loader(), acceptPartial: true), unmatched);
      check(draft.partialAccepted).isTrue();
      check(draft.report.decisions).contains('Partial conversion accepted');
    });

    test('an explicit user exclusion is not a partial conversion', () async {
      final ConversionDraft draft = await _run(
        _pipeline(
          loader: loader(),
          onConfirmMatches: (_, List<SourceMangaData> manga, _, _) async => <MangaMatchConfirmation>[
            for (final m in manga) MangaMatchConfirmation(sourceManga: m, excluded: true),
          ],
        ),
        unmatched,
      );
      check(draft.report.isPartial).isFalse();
      check(draft.report.where(RecordKind.manga, RecordDisposition.excluded).single.manga).equals('Nowhere');
    });
  });

  group('chapter decisions through SelectionPort', () {
    test('only the chosen correspondence receives state, and the decision is reported', () async {
      final source = FakePluginSource(
        'dest',
        manga: <FakeManga>[
          FakeManga(
            'k',
            'Alpha',
            chapters: <NativeChapter>[
              nativeChapter('d5a', 5, scanlators: <String>['X']),
              nativeChapter('d5b', 5, order: 1, scanlators: <String>['Y']),
              nativeChapter('d7', 7, order: 2),
            ],
          ),
        ],
      );
      final c5 = SourceChapter(title: 'c5', chapterKey: 'c5', chapterNumber: 5, isRead: true);
      final c7a = SourceChapter(title: 'c7a', chapterKey: 'c7a', chapterNumber: 7, scanlator: 'A', isRead: true);
      final c7b = SourceChapter(title: 'c7b', chapterKey: 'c7b', chapterNumber: 7, scanlator: 'B', isRead: true);
      ChapterAmbiguityRequest? asked;
      final ConversionDraft draft = await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[source]),
          selection: CallbackSelectionPort(
            onSelectExtensions: (List<ExtensionEntry> e) async => e,
            onConfirmMatches: confirmExactTitle,
            onResolveChapters: (ChapterAmbiguityRequest request) async {
              asked = request;
              return <ChapterDecision>[
                // Ambiguous c5 → d5b; collision on d7 → c7a, c7b excluded.
                ChapterDecision(sourceChapterKey: stableChapterKey(c5), destinationChapterId: 'd5b'),
                ChapterDecision(sourceChapterKey: stableChapterKey(c7a), destinationChapterId: 'd7'),
                ChapterDecision.exclude(stableChapterKey(c7b)),
              ];
            },
          ),
        ),
        FakeBackup(<SourceMangaData>[
          sourceManga('Alpha', chapters: <SourceChapter>[c5, c7a, c7b]),
        ]),
      );
      check(asked).isNotNull().has((ChapterAmbiguityRequest r) => r.unresolved.length, 'unresolved').equals(2);
      final backup = draft.backup as AidokuBackup;
      check(backup.history!.map((AidokuBackupHistory h) => h.chapterId).toSet()).deepEquals(<String>{'d5b', 'd7'});
      check(draft.report.count(RecordKind.chapterState, RecordDisposition.transferred)).equals(2);
      check(draft.report.count(RecordKind.chapterState, RecordDisposition.excluded)).equals(1);
      check(draft.report.isPartial).isFalse();
      check(draft.report.decisions.join('\n')).contains('→ destination "Chapter d5b"');
      check(draft.report.decisions.join('\n')).contains('excluded source chapter c7b');
    });

    test('a user assignment onto an already-matched destination becomes a collision with no state', () async {
      final source = FakePluginSource(
        'dest',
        manga: <FakeManga>[
          FakeManga('k', 'Alpha', chapters: <NativeChapter>[nativeChapter('d1', 1), nativeChapter('d2', 2, order: 1)]),
        ],
      );
      final c1 = SourceChapter(title: 'c1', chapterKey: 'c1', chapterNumber: 1, isRead: true);
      final c9 = SourceChapter(title: 'c9', chapterKey: 'c9', chapterNumber: 9, isRead: true);
      final ConversionDraft draft = await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[source]),
          selection: CallbackSelectionPort(
            onSelectExtensions: (List<ExtensionEntry> e) async => e,
            onConfirmMatches: confirmExactTitle,
            onResolveChapters: (_) async => <ChapterDecision>[
              ChapterDecision(sourceChapterKey: stableChapterKey(c9), destinationChapterId: 'd1'),
            ],
            acceptPartial: true,
          ),
        ),
        FakeBackup(<SourceMangaData>[
          sourceManga('Alpha', chapters: <SourceChapter>[c1, c9]),
        ]),
      );
      check((draft.backup as AidokuBackup).history).isNull();
      check(draft.report.count(RecordKind.chapterState, RecordDisposition.unresolved)).equals(2);
    });
  });

  group('complete accounting (KTD8)', () {
    test('every input record ends transferred, excluded, unrepresentable or unresolved', () async {
      final source = FakePluginSource(
        'dest',
        manga: <FakeManga>[
          FakeManga('a', 'Alpha', chapters: <NativeChapter>[nativeChapter('d1', 1), nativeChapter('d2', 2, order: 1)]),
          FakeManga('b', 'Beta', failure: const TimeoutFailure('slow')),
        ],
      );
      final tracking = <SourceTrackingEntry>[SourceTrackingEntry(syncId: 1, title: 'AL')];
      final backup = FakeBackup(
        <SourceMangaData>[
          sourceManga(
            'Alpha',
            tracking: tracking,
            chapters: <SourceChapter>[
              SourceChapter(title: '1', chapterNumber: 1, isRead: true, isBookmarked: true),
              SourceChapter(title: '3', chapterNumber: 3, isRead: true),
              SourceChapter(title: 'unread', chapterNumber: 2),
            ],
          ),
          sourceManga('Beta', chapters: <SourceChapter>[SourceChapter(title: '1', chapterNumber: 1, isRead: true)]),
          sourceManga('Gamma', tracking: tracking),
          sourceManga('Delta'),
        ],
        losses: const <ExtractionLoss>[ExtractionLoss(subject: 'Paperback library entry lib-x', reason: 'dangling')],
      );
      final ConversionDraft draft = await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[source]),
          acceptPartial: true,
          onConfirmMatches: (names, manga, onSearch, onFetch) async {
            final List<MangaMatchConfirmation> exact = await confirmExactTitle(names, manga, onSearch, onFetch);
            return <MangaMatchConfirmation>[
              for (final c in exact)
                if (c.sourceManga.details.title == 'Delta')
                  MangaMatchConfirmation(sourceManga: c.sourceManga, excluded: true)
                else
                  c,
            ];
          },
        ),
        backup,
      );
      final ConversionReport r = draft.report;
      // 4 extracted manga + 1 extraction loss.
      check(r.count(RecordKind.manga)).equals(5);
      check(r.count(RecordKind.manga, RecordDisposition.transferred)).equals(1);
      check(r.count(RecordKind.manga, RecordDisposition.excluded)).equals(1);
      check(r.count(RecordKind.manga, RecordDisposition.unresolved)).equals(3);
      // State-bearing chapters: Alpha 1 + 3, Beta 1.
      check(r.count(RecordKind.chapterState)).equals(3);
      check(r.count(RecordKind.chapterState, RecordDisposition.transferred)).equals(1);
      // Tracking: Alpha (built, unrepresentable) + Gamma (unresolved manga).
      check(r.count(RecordKind.tracking)).equals(2);
      check(r.count(RecordKind.tracking, RecordDisposition.unrepresentable)).equals(1);
      check(r.count(RecordKind.field, RecordDisposition.unrepresentable)).equals(1);
      check(r.failures.single.code).equals('timeout');
    });
  });

  group('repository trust through SelectionPort', () {
    test(
      'first-seen and changed fingerprints ask; a remembered one does not; a rejected repository is dropped',
      () async {
        final store = InMemoryTrustStore();
        final asked = <RepositoryTrustRequest>[];
        TrustDecision answer = TrustDecision.trustAndRemember;
        Future<void> runWith(String fingerprint) => _run(
          _pipeline(
            loader: FakePluginLoader(sources: <PluginSource>[FakePluginSource('dest')], signedRepository: fingerprint),
            trustStore: store,
            selection: CallbackSelectionPort(
              onSelectExtensions: (List<ExtensionEntry> e) async => e,
              onConfirmMatches: (_, manga, _, _) async => <MangaMatchConfirmation>[
                for (final m in manga) MangaMatchConfirmation(sourceManga: m, excluded: true),
              ],
              onRepositoryTrust: (RepositoryTrustRequest request) async {
                asked.add(request);
                return answer;
              },
            ),
          ),
          FakeBackup(<SourceMangaData>[sourceManga('A')]),
        );

        await runWith('AA:BB');
        check(asked.single.isChange).isFalse();
        await runWith('AA:BB');
        check(asked).length.equals(1);
        answer = TrustDecision.reject;
        await check(runWith('CC:DD')).throws<MigrationException>();
        check(asked.last.isChange).isTrue();
        check(asked.last.previousFingerprint).equals('AA:BB');
      },
    );

    test('a port without a trust callback rejects first-seen repositories, and the error names the decision', () async {
      await check(
        _run(
          _pipeline(loader: FakePluginLoader(signedRepository: 'AA')),
          FakeBackup(<SourceMangaData>[sourceManga('A')]),
        ),
      ).throws<MigrationException>(
        (Subject<MigrationException> it) => it
            .has((MigrationException e) => '$e', 'message')
            .contains('First-seen signing fingerprint for ${_repos.single} (test): reject'),
      );
    });
  });

  group('adult-source policy', () {
    const extensions = <ExtensionEntry>[
      StubExtensionEntry(id: 'safe', name: 'Safe'),
      AidokuExtensionEntry(id: 'adult', name: 'Adult', version: 1, iconUrl: '', downloadUrl: '', contentRating: 2),
      AidokuExtensionEntry(id: 'odd', name: 'Unknown', version: 1, iconUrl: '', downloadUrl: '', contentRating: 7),
    ];

    Future<SourceSelectionRequest> offered(SourceRatingPolicy policy, {List<String>? pick}) async {
      late SourceSelectionRequest seen;
      await _run(
        _pipeline(
          loader: FakePluginLoader(extensions: extensions, sources: <PluginSource>[FakePluginSource('dest')]),
          ratingPolicy: policy,
          selection: CallbackSelectionPort(
            onSelectExtensions: (List<ExtensionEntry> e) async => e,
            onSelectSources: (SourceSelectionRequest request) async {
              seen = request;
              // A misbehaving UI returning every extension is still filtered.
              return pick == null ? request.available : extensions;
            },
            onConfirmMatches: (_, manga, _, _) async => <MangaMatchConfirmation>[
              for (final m in manga) MangaMatchConfirmation(sourceManga: m, excluded: true),
            ],
          ),
        ),
        FakeBackup(<SourceMangaData>[sourceManga('A')]),
      );
      return seen;
    }

    test('adult and unrated sources are hidden until the age-confirming setting is enabled', () async {
      final SourceSelectionRequest hidden = await offered(const SourceRatingPolicy());
      check(hidden.available.map((ExtensionEntry e) => e.id).toList()).deepEquals(<String>['safe']);
      check(hidden.hiddenByRating).equals(2);

      final SourceSelectionRequest shown = await offered(const SourceRatingPolicy(adultContentConfirmed: true));
      check(shown.available.map((ExtensionEntry e) => e.id).toList()).deepEquals(<String>['safe', 'adult', 'odd']);
    });

    test('the policy holds even when a selection UI returns a hidden source', () {
      const policy = SourceRatingPolicy();
      check(policy.allows(2)).isFalse();
      check(policy.allows(-1)).isFalse();
      check(policy.requestsUnconfirmedAdult).isFalse();
      check(const SourceRatingPolicy(maxRating: 2).requestsUnconfirmedAdult).isTrue();
      check(const SourceRatingPolicy(adultContentConfirmed: true, maxRating: 0).allows(1)).isFalse();
      check(SourceRatingPolicy.ratingOf(ContentRatingLevel.unknown)).equals(SourceRatingPolicy.nsfw);
    });
  });

  group('conversion journal', () {
    const secret = 'hunter2-session-token';
    SettingsSnapshot settings({String lang = 'en'}) =>
        SettingsSnapshot(values: <String, Object>{'lang': lang}, secrets: const <String, String>{'token': secret});

    FakePluginSource destination(SettingsSnapshot s) => FakePluginSource(
      'dest',
      settings: s,
      manga: <FakeManga>[
        FakeManga('a', 'Alpha', chapters: <NativeChapter>[nativeChapter('d1', 1)]),
        FakeManga('b', 'Beta', chapters: <NativeChapter>[nativeChapter('e1', 1)]),
      ],
    );

    final input = FakeBackup(<SourceMangaData>[
      sourceManga('Alpha', chapters: <SourceChapter>[SourceChapter(title: '1', chapterNumber: 1, isRead: true)]),
      sourceManga('Beta'),
    ]);

    test('a resumed conversion in a new process keeps confirmations and snapshots without secrets', () async {
      final store = InMemoryJournalStore();
      var confirmCalls = 0;

      // First process: confirm and fetch, then die before building.
      final FakePluginSource first = destination(settings());
      await check(
        _run(
          _pipeline(
            loader: FakePluginLoader(sources: <PluginSource>[first]),
            journalStore: store,
            selection: CallbackSelectionPort(
              onSelectExtensions: (List<ExtensionEntry> e) async => e,
              onConfirmMatches: (names, manga, onSearch, onFetch) {
                confirmCalls++;
                return confirmExactTitle(names, manga, onSearch, onFetch);
              },
              onAcceptPartial: (_) => throw StateError('process killed'),
            ),
          ),
          FakeBackup(<SourceMangaData>[...input.entries, sourceManga('Nowhere')]),
          inputIdentity: 'input-digest',
        ),
      ).throws<StateError>();
      check(confirmCalls).equals(1);
      check(first.fetches).equals(2);
      final String journalText = jsonEncode(store.json);
      check(journalText).not((it) => it.contains(secret));
      check(journalText).contains('"snapshot"');

      // Second process: new sources, secrets re-entered for the same keys.
      final FakePluginSource resumed = destination(settings());
      final searchedAgain = <String>[];
      var resumedWith = 0;
      var previous = <ExtensionEntry>[];
      final ConversionDraft draft = await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[resumed]),
          journalStore: store,
          selection: CallbackSelectionPort(
            onSelectExtensions: (List<ExtensionEntry> e) async => e,
            onSelectSources: (SourceSelectionRequest request) async {
              previous = request.previousSelection;
              return request.available;
            },
            onConfirmMatches: (names, manga, onSearch, onFetch) {
              searchedAgain.addAll(manga.map((SourceMangaData m) => m.details.title));
              return confirmExactTitle(names, manga, onSearch, onFetch);
            },
            acceptPartial: true,
          ),
        ).copyWithResume((int n) => resumedWith = n),
        FakeBackup(<SourceMangaData>[...input.entries, sourceManga('Nowhere')]),
        inputIdentity: 'input-digest',
      );
      check(confirmCalls).equals(1);
      // Only the manga without a confirmed match is searched again.
      check(searchedAgain).deepEquals(<String>['Nowhere']);
      check(resumedWith).equals(2);
      check(previous.map((ExtensionEntry e) => e.id).toList()).deepEquals(<String>['ext']);
      check(resumed.fetches).equals(0);
      check((draft.backup as AidokuBackup).manga!.map((AidokuBackupManga m) => m.id).toSet()).deepEquals(<String>{
        'a',
        'b',
      });
      check((draft.backup as AidokuBackup).history!.single.chapterId).equals('d1');
    });

    test('a changed non-secret setting reopens the affected decisions', () async {
      final store = InMemoryJournalStore();
      await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[destination(settings())]),
          journalStore: store,
          selection: CallbackSelectionPort(
            onSelectExtensions: (List<ExtensionEntry> e) async => e,
            onConfirmMatches: confirmExactTitle,
            onAcceptPartial: (_) => throw StateError('process killed'),
          ),
        ),
        FakeBackup(<SourceMangaData>[...input.entries, sourceManga('Nowhere')]),
        inputIdentity: 'input-digest',
      ).then((_) {}, onError: (Object _) {});

      final reopened = <String>[];
      final FakePluginSource changed = destination(settings(lang: 'fr'));
      await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[changed]),
          journalStore: store,
          selection: CallbackSelectionPort(
            onSelectExtensions: (List<ExtensionEntry> e) async => e,
            onConfirmMatches: (names, manga, onSearch, onFetch) {
              reopened.addAll(manga.map((SourceMangaData m) => m.details.title));
              return confirmExactTitle(names, manga, onSearch, onFetch);
            },
            acceptPartial: true,
          ),
        ),
        FakeBackup(<SourceMangaData>[...input.entries, sourceManga('Nowhere')]),
        inputIdentity: 'input-digest',
      );
      // Matched manga reopen; unmatched manga were never journaled as decisions.
      check(reopened).deepEquals(<String>['Alpha', 'Beta', 'Nowhere']);
      check(changed.fetches).equals(2);
    });

    test('a killed-and-resumed conversion reproduces an uninterrupted one', () async {
      FakePluginSource source() => FakePluginSource(
        'dest',
        settings: settings(),
        manga: <FakeManga>[
          FakeManga(
            'a',
            'Alpha',
            coverUrl: 'https://img.invalid/a.jpg',
            authors: const <String>['Search Author'],
            chapters: <NativeChapter>[nativeChapter('d1', 1)],
          ),
        ],
      );
      FakePluginSource flaky() => FakePluginSource('flaky', searchFailure: const InteractionRequiredFailure('captcha'));
      final backup = FakeBackup(<SourceMangaData>[...input.entries, sourceManga('Nowhere')]);

      final ConversionDraft straight = await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[source(), flaky()]),
          acceptPartial: true,
        ),
        backup,
      );

      final store = InMemoryJournalStore();
      await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[source(), flaky()]),
          journalStore: store,
          selection: CallbackSelectionPort(
            onSelectExtensions: (List<ExtensionEntry> e) async => e,
            onConfirmMatches: confirmExactTitle,
            onAcceptPartial: (_) => throw StateError('process killed'),
          ),
        ),
        backup,
        inputIdentity: 'in',
      ).then((_) {}, onError: (Object _) {});
      final ConversionDraft resumed = await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[source(), flaky()]),
          journalStore: store,
          acceptPartial: true,
        ),
        backup,
        inputIdentity: 'in',
      );

      check(resumed.report.digest).equals(straight.report.digest);
      final AidokuBackupManga a = (straight.backup as AidokuBackup).manga!.single;
      final AidokuBackupManga b = (resumed.backup as AidokuBackup).manga!.single;
      check(b.cover).equals(a.cover);
      check(b.author).equals(a.author);
      check(a.cover).equals('https://img.invalid/a.jpg');
    });

    test('a journaled partial acceptance is not asked again', () async {
      final store = InMemoryJournalStore();
      final backup = FakeBackup(<SourceMangaData>[...input.entries, sourceManga('Nowhere')]);
      var asked = 0;
      MigrationPipeline pipeline() => _pipeline(
        loader: FakePluginLoader(sources: <PluginSource>[destination(settings())]),
        journalStore: store,
        selection: CallbackSelectionPort(
          onSelectExtensions: (List<ExtensionEntry> e) async => e,
          onConfirmMatches: confirmExactTitle,
          onAcceptPartial: (_) async {
            asked++;
            return true;
          },
        ),
      );
      await _run(pipeline(), backup, inputIdentity: 'in');
      final ConversionDraft again = await _run(pipeline(), backup, inputIdentity: 'in');
      check(asked).equals(1);
      check(again.partialAccepted).isTrue();
    });

    test('a journal for different input is ignored', () async {
      final store = InMemoryJournalStore();
      await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[destination(settings())]),
          journalStore: store,
        ),
        input,
        inputIdentity: 'one',
      );
      var asked = 0;
      await _run(
        _pipeline(
          loader: FakePluginLoader(sources: <PluginSource>[destination(settings())]),
          journalStore: store,
          onConfirmMatches: (names, manga, onSearch, onFetch) {
            asked++;
            return confirmExactTitle(names, manga, onSearch, onFetch);
          },
        ),
        input,
        inputIdentity: 'two',
      );
      check(asked).equals(1);
    });

    test('failure messages are redacted before they reach the report and journal', () async {
      final store = InMemoryJournalStore();
      final ConversionDraft draft = await _run(
        _pipeline(
          loader: FakePluginLoader(
            sources: <PluginSource>[
              FakePluginSource('ok', manga: <FakeManga>[FakeManga('k', 'Alpha')]),
              FakePluginSource('bad', searchFailure: const SourceErrorFailure('401 with token=$secret')),
            ],
          ),
          journalStore: store,
          redact: (String s) => s.replaceAll(secret, '[REDACTED]'),
        ),
        FakeBackup(<SourceMangaData>[sourceManga('Alpha')]),
        inputIdentity: 'id',
      );
      check(jsonEncode(draft.report.toJson())).not((it) => it.contains(secret));
      check(jsonEncode(store.json)).not((it) => it.contains(secret));
      check(draft.report.failures.single.message).contains('[REDACTED]');
    });
  });
}

extension on MigrationPipeline {
  /// A copy with an [MigrationPipeline.onResume] callback.
  MigrationPipeline copyWithResume(void Function(int decisions) onResume) => MigrationPipeline(
    repoUrls: repoUrls,
    selection: selection,
    onProgress: onProgress,
    pluginLoader: pluginLoader,
    directConverter: directConverter,
    onOwnerOpened: onOwnerOpened,
    journalStore: journalStore,
    onResume: onResume,
    ratingPolicy: ratingPolicy,
    trustStore: trustStore,
    redact: redact,
  );
}
