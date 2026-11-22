import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:source_runtime/source_contracts.dart';
import 'package:test/scaffolding.dart';

import '../support/test_refs.dart';

class _Session implements SourceSession {
  _Session({this.fetchOutcome, this.searchOutcome});

  @override
  final SourceIdentity identity = testIdentity('src');

  @override
  String get displayName => 'Source';

  @override
  SourceCapabilities get capabilities =>
      SourceCapabilities(operations: const <SourceOperation>{SourceOperation.search, SourceOperation.mangaDetails});

  @override
  String get settingsRevision => 'rev';

  final SourceOutcome<MangaSnapshot>? fetchOutcome;
  final SourceOutcome<SearchPage>? searchOutcome;
  SearchRequest? lastSearch;
  int closed = 0;

  @override
  Future<SourceOutcome<SearchPage>> search(SearchRequest request, {CancellationToken? cancel}) async {
    lastSearch = request;
    return searchOutcome!;
  }

  @override
  Future<SourceOutcome<MangaSnapshot>> fetchManga(NativeMangaRef ref, {CancellationToken? cancel}) async =>
      fetchOutcome!;

  @override
  Future<void> close() async => closed++;
}

void main() {
  group('SessionPluginSource (KTD15 adapter)', () {
    test('search results carry the session native references and warnings', () async {
      final ref = NativeMangaRef(
        source: testIdentity('src'),
        mangaId: '9007199254740993',
        settingsRevision: 'rev',
        context: const <String, Object?>{'url': '/m/1'},
      );
      final session = _Session(
        searchOutcome: SourceSuccess<SearchPage>(
          SearchPage(
            hits: <SearchHit>[SearchHit(ref: ref, title: 'T')],
            nextCursor: '2',
            warnings: const <String>['[CB] bad selector'],
          ),
        ),
      );
      final SourceOutcome<PluginSearchPageResult> outcome = await SessionPluginSource(session).search('q');
      final PluginSearchPageResult page = outcome.valueOrNull!;
      check(page.results.single.ref.mangaId).equals('9007199254740993');
      check(page.results.single.ref.context['url']).equals('/m/1');
      check(page.results.single.pluginSourceName).equals('Source');
      check(page.nextCursor).equals('2');
      check(page.warnings).deepEquals(<String>['[CB] bad selector']);
      check(session.lastSearch!.cursor).isNull();
    });

    test('the next page passes the source cursor through unchanged', () async {
      const cursor = '{"page":2,"token":"a b"}';
      final session = _Session(
        searchOutcome: const SourceSuccess<SearchPage>(SearchPage(hits: <SearchHit>[])),
      );
      final PluginSearchPageResult page = (await SessionPluginSource(session).search('q', cursor: cursor)).valueOrNull!;
      check(session.lastSearch!.cursor).equals(cursor);
      check(page.hasNextPage).isFalse();
    });

    test('a failed search stays typed', () async {
      final SourceOutcome<PluginSearchPageResult> outcome = await SessionPluginSource(
        _Session(searchOutcome: const SourceFailed<SearchPage>(InteractionRequiredFailure('captcha'))),
      ).search('q');
      check(outcome.failureOrNull).isA<InteractionRequiredFailure>();
    });

    test('a null/failed detail lookup is a typed failure, never an empty snapshot', () async {
      final source = SessionPluginSource(
        _Session(fetchOutcome: const SourceFailed<MangaSnapshot>(SourceErrorFailure('returned no details'))),
      );
      final DetailsOutcome outcome = await source.fetchDetails(testRef('src', 'm'));
      check(outcome).isA<DetailsFailed>().has((DetailsFailed f) => f.failure.message, 'message').contains('no details');
    });

    test('an empty successful snapshot is DetailsEmpty; scanlators are all kept', () async {
      final NativeMangaRef ref = testRef('src', 'm');
      final DetailsOutcome empty = await SessionPluginSource(
        _Session(
          fetchOutcome: SourceSuccess<MangaSnapshot>(
            MangaSnapshot(
              ref: ref,
              metadata: const MangaMetadata(title: 'T'),
              chapters: const <NativeChapter>[],
            ),
          ),
        ),
      ).fetchDetails(ref);
      check(empty).isA<DetailsEmpty>();

      final DetailsOutcome full = await SessionPluginSource(
        _Session(
          fetchOutcome: SourceSuccess<MangaSnapshot>(
            MangaSnapshot(
              ref: ref,
              metadata: const MangaMetadata(title: 'T'),
              chapters: const <NativeChapter>[
                NativeChapter(chapterId: 'c', sourceOrder: 0, chapterNumber: 1, scanlators: <String>['A', 'B']),
              ],
            ),
          ),
        ),
      ).fetchDetails(ref);
      final PluginChapter chapter = (full as DetailsFetched).manga.chapters.single;
      check(chapter.scanlators).deepEquals(<String>['A', 'B']);
      check(chapter.scanlator).equals('A, B');
    });

    test('a reference bound to another settings revision is stale', () async {
      final DetailsOutcome outcome = await SessionPluginSource(
        _Session(),
      ).fetchDetails(testRef('src', 'm', settingsRevision: 'other'));
      check(outcome).isA<DetailsFailed>().has((DetailsFailed f) => f.failure, 'failure').isA<StaleReferenceFailure>();
    });

    test('dispose closes the session once and runs the package close', () async {
      final session = _Session();
      var packageClosed = 0;
      final source = SessionPluginSource(session, onDispose: () => packageClosed++);
      await source.dispose();
      await source.dispose();
      check(session.closed).equals(1);
      check(packageClosed).equals(1);
    });
  });

  group('ConversionOwner', () {
    test('closes in reverse order, continues past failures, and closes late adoptions immediately', () async {
      final order = <String>[];
      final owner = ConversionOwner();
      await owner.adopt(() => order.add('a'));
      await owner.adopt(() => throw StateError('b failed'));
      await owner.adopt(() => order.add('c'));
      await check(owner.close()).throws<StateError>();
      check(order).deepEquals(<String>['c', 'a']);
      await owner.adopt(() => order.add('late'));
      check(order.last).equals('late');
    });
  });

  test('redactFailure keeps the code and the operation of a capability failure', () {
    final SourceFailure out = redactFailure(
      const CapabilityUnavailableFailure('browser', 'needs token=abc'),
      (String m) => m.replaceAll('abc', '[REDACTED]'),
    );
    check(out)
        .isA<CapabilityUnavailableFailure>()
        .has((CapabilityUnavailableFailure f) => f.operation, 'op')
        .equals('browser');
    check(out.message).equals('needs token=[REDACTED]');
  });
}
