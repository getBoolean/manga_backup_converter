import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_tachi.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:test/scaffolding.dart';

const String _fingerprint = '9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2';

void main() {
  group('--tachi-artifact', () {
    test('kind alone, per repository (any spelling) and per package', () {
      final TachiArtifactPolicy policy = parseTachiArtifactOverrides(<String>[
        'apk',
        'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.json=JAR',
        'eu.kanade.tachiyomi.extension.en.weebcentral=apk',
      ]);
      check(policy.all).equals(TachiArtifactKind.apk);
      check(
        policy.repositories,
      ).deepEquals(<Uri, TachiArtifactKind>{
        Uri.parse('https://raw.githubusercontent.com/keiyoushi/extensions/repo'): TachiArtifactKind.jar,
      });
      check(
        policy.packages,
      ).deepEquals(<String, TachiArtifactKind>{'eu.kanade.tachiyomi.extension.en.weebcentral': TachiArtifactKind.apk});
    });

    test('rejects unknown kinds', () {
      check(() => parseTachiArtifactOverrides(<String>['dex'])).throws<FormatException>();
      check(() => parseTachiArtifactOverrides(<String>['=jar'])).throws<FormatException>();
    });
  });

  group('--trust-tachi-repo', () {
    test('pins a repository under its canonical URL, whatever file the user named', () async {
      final store = PinnedTrustStore(
        InMemoryTrustStore(),
        PinnedTrustStore.parsePins(<String>[
          'https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json=${_fingerprint.toUpperCase()}',
        ]),
      );
      check(
        await store.fingerprintFor('tachi', Uri.parse('https://raw.githubusercontent.com/keiyoushi/extensions/repo')),
      ).equals(_fingerprint);
      check(await store.fingerprintFor('paperback', Uri.parse('https://example.invalid'))).isNull();
    });

    test('rejects malformed pins', () {
      check(() => PinnedTrustStore.parsePins(<String>['no-equals'])).throws<FormatException>();
      check(() => PinnedTrustStore.parsePins(<String>['https://x.invalid/repo=abc'])).throws<FormatException>();
      check(() => PinnedTrustStore.parsePins(<String>['file:///repo=$_fingerprint'])).throws<FormatException>();
    });
  });
}
