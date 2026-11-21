import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:tachi_plugin_loader/testing.dart';
import 'package:test/scaffolding.dart';

void main() {
  final keiyoushi = TachiRepository(
    baseUrl: keiyoushiRepository,
    name: 'Keiyoushi',
    signingKeyFingerprint: keiyoushiFingerprint,
  );
  final TachiCapture weebCentral = tachiCaptures()[1];

  TachiPackageListing listing({bool jar = true, bool apk = true}) => parseTachiIndex(keiyoushi, <Object?>[
    <String, Object?>{
      ...weebCentral.indexEntry,
      'resources': <String, Object?>{
        if (jar) 'jarUrl': weebCentral.urlOf(TachiArtifactKind.jar).toString(),
        if (apk) 'apkUrl': weebCentral.urlOf(TachiArtifactKind.apk).toString(),
      },
    },
  ]).single;

  group('TachiArtifactPolicy', () {
    TachiArtifactChoice chosen(TachiArtifactPolicy policy, TachiPackageListing l) =>
        (policy.select(l) as SourceSuccess<TachiArtifactChoice>).value;

    test('selects the JAR when published and the APK otherwise', () {
      check(chosen(const TachiArtifactPolicy(), listing()).kind).equals(TachiArtifactKind.jar);
      check(chosen(const TachiArtifactPolicy(), listing(jar: false)).kind).equals(TachiArtifactKind.apk);
      check(
        chosen(const TachiArtifactPolicy(), listing()).url,
      ).equals(weebCentral.urlOf(TachiArtifactKind.jar));
    });

    test('a package override wins over a repository override, which wins over the global one', () {
      final TachiPackageListing l = listing();
      check(chosen(const TachiArtifactPolicy(all: TachiArtifactKind.apk), l).kind).equals(TachiArtifactKind.apk);
      check(
        chosen(
          TachiArtifactPolicy(all: TachiArtifactKind.jar, repositories: {keiyoushiRepository: TachiArtifactKind.apk}),
          l,
        ).kind,
      ).equals(TachiArtifactKind.apk);
      check(
        chosen(
          TachiArtifactPolicy(
            repositories: {keiyoushiRepository: TachiArtifactKind.apk},
            packages: {l.packageId: TachiArtifactKind.jar},
          ),
          l,
        ).kind,
      ).equals(TachiArtifactKind.jar);
    });

    test('a forced kind the index does not publish is a typed failure, never the other kind', () {
      final SourceOutcome<TachiArtifactChoice> outcome = const TachiArtifactPolicy(
        all: TachiArtifactKind.jar,
      ).select(listing(jar: false));
      check(outcome)
          .isA<SourceFailed<TachiArtifactChoice>>()
          .has((f) => f.failure, 'failure')
          .isA<ArtifactIncompatibleFailure>();
    });
  });

  group('TachiArtifactStore', () {
    late Directory temp;
    late TachiArtifactStore store;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('tachi_store_');
      store = TachiArtifactStore(
        cache: ArtifactCache(Directory('${temp.path}/cache')),
        fetch: FixtureFetch(const <FixtureRepository>[]).call,
      );
    });

    tearDown(() => temp.deleteSync(recursive: true));

    test('admits downloads content-addressed: the binding is the digest of exactly these bytes', () async {
      final Uint8List jar = weebCentral.bytesOf(TachiArtifactKind.jar);
      final ArtifactLease lease = (await store.admit(
        jar,
        kind: TachiArtifactKind.jar,
        version: '1.6.27',
      ) as SourceSuccess<ArtifactLease>).value;
      check(lease.binding.sha256).equals(weebCentral.sha256Of(TachiArtifactKind.jar));
      check(lease.binding.kind).equals('jar');
      check(await lease.readVerified()).deepEquals(jar);
      check(store.cache.leaseCount(lease.binding, TachiArtifactStore.downloadProfile)).equals(1);
      lease.release();
    });

    test('rejects bytes that are not an archive', () async {
      final SourceOutcome<ArtifactLease> outcome = await store.admit(
        Uint8List.fromList('<html>not found</html>'.codeUnits),
        kind: TachiArtifactKind.jar,
        version: '1',
      );
      check(outcome).isA<SourceFailed<ArtifactLease>>();
    });

    test('an unserved URL is a typed download failure', () async {
      final SourceOutcome<Uint8List> outcome = await store.download(
        TachiArtifactChoice(kind: TachiArtifactKind.jar, url: Uri.parse('https://example.invalid/x.jar')),
      );
      check(outcome).isA<SourceFailed<Uint8List>>();
    });
  });
}
