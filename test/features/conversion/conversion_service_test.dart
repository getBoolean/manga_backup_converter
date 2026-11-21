import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart' show test;
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter/src/features/conversion/application/conversion_service.dart';
import 'package:riverpod/riverpod.dart';
import 'package:source_runtime/source_contracts.dart';

final _identity = SourceIdentity(
  ecosystem: 'paperback',
  packageId: 'https://repo.invalid/#WeebCentral',
  sourceId: 'WeebCentral',
  artifact: const ArtifactBinding(sha256: 'abc', kind: 'test', version: '1'),
);

/// A device runtime as a mobile composition root would register it.
final class _DeviceSource implements PluginSource {
  _DeviceSource();

  int searches = 0;

  @override
  SourceIdentity get identity => _identity;
  @override
  String get sourceId => 'WeebCentral';
  @override
  String get sourceName => 'Weeb Central';
  @override
  String get settingsRevision => 'rev';
  @override
  String? get language => 'en';

  NativeMangaRef get _ref => NativeMangaRef(
    source: _identity,
    mangaId: 'onimai',
    settingsRevision: 'rev',
  );

  @override
  Future<SourceOutcome<PluginSearchPageResult>> search(
    String query,
    int page,
  ) async {
    searches++;
    return SourceSuccess<PluginSearchPageResult>(
      PluginSearchPageResult(
        results: <PluginSearchResult>[
          PluginSearchResult(ref: _ref, title: 'Onimai'),
        ],
        hasNextPage: false,
      ),
    );
  }

  @override
  Future<DetailsOutcome> fetchDetails(NativeMangaRef ref) async =>
      DetailsOutcome.fromSnapshot(
        SourceSuccess<MangaSnapshot>(
          MangaSnapshot(
            ref: ref,
            metadata: const MangaMetadata(title: 'Onimai'),
            chapters: const <NativeChapter>[
              NativeChapter(
                chapterId: 'c2',
                sourceOrder: 0,
                chapterNumber: 2,
                title: 'Chapter 2',
              ),
              NativeChapter(
                chapterId: 'c1',
                sourceOrder: 1,
                chapterNumber: 1,
                title: 'Chapter 1',
              ),
            ],
          ),
        ),
      );

  @override
  Future<void> dispose() async {}
}

final class _DeviceLoader extends PluginLoader {
  _DeviceLoader(this.source);

  final _DeviceSource source;

  @override
  Future<List<ExtensionEntry>> fetchExtensionLists(
    List<String> repoUrls, {
    void Function(String)? onWarning,
    RepositoryTrustGate? trust,
  }) async => const <ExtensionEntry>[
    StubExtensionEntry(
      id: 'wc',
      name: 'Weeb Central',
      languages: <String>['en'],
    ),
  ];

  @override
  Future<List<PluginSource>> loadPlugins(
    List<ExtensionEntry> extensions, {
    void Function(int current, int total, String message)? onProgress,
    ConversionOwner? owner,
    void Function(PluginLoadFailure failure)? onFailure,
  }) async => <PluginSource>[source];
}

final class _MemoryOutput implements ConversionOutput {
  Uint8List? bytes;

  @override
  Future<void> publish(Uint8List data) async => bytes = data;
}

/// An input Mihon backup with chapter 1 read.
Future<Uint8List> _mihonInput() => TachiBackup(
  backupManga: <TachiBackupManga>[
    TachiBackupManga(
      source: 1,
      url: '/m',
      title: 'Onimai',
      artist: '',
      author: '',
      description: '',
      genre: const <String>[],
      status: 0,
      thumbnailUrl: '',
      dateAdded: 0,
      viewer: 0,
      chapters: const <TachiBackupChapter>[
        TachiBackupChapter(
          url: '/c1',
          name: 'Chapter 1',
          scanlator: '',
          read: true,
          bookmark: false,
          lastPageRead: 0,
          dateFetch: 0,
          dateUpload: 0,
          chapterNumber: 1,
          sourceOrder: 0,
        ),
      ],
      categories: const <int>[],
      tracking: const <TachiBackupTracking>[],
      favorite: true,
      chapterFlags: 0,
      viewerFlags: 0,
      history: const <TachiBackupHistory>[],
    ),
  ],
).toData();

void main() {
  test('the app service runs the core conversion job with the injected device runtime and adapters', () async {
    final source = _DeviceSource();
    final service = ConversionService(
      runtimes: RuntimeRegistry(<DestinationRuntime>[
        DestinationRuntime(
          ecosystem: 'paperback',
          serves: (BackupFormat f) => f is Paperback,
          createLoader: () => _DeviceLoader(source),
        ),
      ]),
    );
    check(service.availableTargets(const Mihon()))
        .deepEquals(<BackupFormat>[const Paperback()]);

    final output = _MemoryOutput();
    final ConversionResult result = await service.convert(
      ConversionRequest(
        input: await _mihonInput(),
        sourceFormat: const Mihon(),
        targetFormat: const Paperback(),
        repoUrls: const <String>['https://repo.invalid'],
      ),
      selection: CallbackSelectionPort(
        onSelectExtensions: (List<ExtensionEntry> e) async => e,
        onConfirmMatches: (_, List<SourceMangaData> manga, onSearch, _) async {
          final results = <PluginSearchResult>[];
          await for (final PluginSearchEvent e in onSearch('Onimai')) {
            if (e is PluginSearchResults) results.addAll(e.results);
          }
          return <MangaMatchConfirmation>[
            MangaMatchConfirmation(
              sourceManga: manga.single,
              confirmedMatch: results.single,
            ),
          ];
        },
      ),
      output: output,
    );

    check(source.searches).equals(1);
    final PaperbackBackup published = PaperbackBackup.fromData(output.bytes!);
    check(published.sourceManga!.single.sourceId).equals('WeebCentral');
    check(published.chapterProgressMarker!.single.completed).isTrue();
    check(
      result.report.count(
        RecordKind.chapterState,
        RecordDisposition.transferred,
      ),
    ).equals(1);
    check(result.report.isPartial).isFalse();
  });

  test('without a registered device runtime every migration target is a typed failure', () {
    final ConversionService service = ProviderContainer().read(
      conversionServiceProvider,
    );
    check(service.availableTargets(const Mihon())).isEmpty();
    check(service.unavailable(const Mihon(), const Aidoku()))
        .isA<CapabilityUnavailableFailure>();
  });
}
