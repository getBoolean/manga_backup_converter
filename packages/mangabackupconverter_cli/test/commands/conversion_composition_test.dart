// The CLI composition root (KTD15): which formats it can read and write,
// which desktop runtimes it registers, and when a destination is enabled.
@TestOn('vm')
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:mangabackupconverter_cli/src/commands/conversion_composition.dart';
import 'package:mangabackupconverter_cli/src/commands/plugin_cache.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_paperback.dart';
import 'package:mangabackupconverter_cli/src/pipeline/plugin_source_tachi.dart';
import 'package:source_runtime/source_runtime.dart';
import 'package:tachi_plugin_loader/tachi_plugin_loader.dart';
import 'package:tachi_plugin_loader/testing.dart';
import 'package:test/scaffolding.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('u7_composition_'));
  tearDown(() => deleteTestDirectory(temp));

  DesktopTachiRuntime tachi({bool located = true}) => DesktopTachiRuntime(
    locate: () => located
        ? SourceSuccess<TachiWorkerLocation>(
            TachiWorkerLocation(
              java: 'java',
              classpathDirectory: temp.path,
              handshakeDeadline: const Duration(seconds: 1),
            ),
          )
        : const SourceFailed<TachiWorkerLocation>(RuntimeUnavailableFailure('no Tachi worker install')),
    cacheDirectory: temp,
    fetch: (Uri url) async => throw UnimplementedError(),
  );

  RuntimeRegistry registry({bool tachiLocated = true, SourceFailure? paperback}) => cliRuntimeRegistry(
    cache: PluginCache(cacheDir: temp),
    tachi: tachi(located: tachiLocated),
    cacheRoot: temp.path,
    paperbackProbe: () => paperback,
    interactionTimeout: const Duration(minutes: 5),
  );

  test('formats: portable writers plus the native Tachimanga/Mangayomi codecs and the direct converter', () {
    final FormatRegistry formats = cliFormatRegistry();
    check(formats.writableFormats).deepEquals(<BackupFormat>[const Aidoku(), const Paperback(), const Mihon()]);
    check(formats.codecFor(const Tachimanga())).isNotNull();
    check(formats.codecFor(const Mangayomi())).isNotNull();
    check(formats.directConverter).isNotNull();
    // Every R5 destination plus the direct Tachimanga↔Tachi targets.
    check(formats.outputFormats).containsEqualInOrder(<BackupFormat>[
      const Aidoku(),
      const Paperback(),
      const Mihon(),
      const Tachimanga(),
    ]);
  });

  test('the CLI registers the Aidoku, Paperback and Tachi desktop runtimes', () {
    final RuntimeRegistry r = registry();
    check(r.runtimes.map((DestinationRuntime d) => d.ecosystem).toList()).deepEquals(<String>[
      'aidoku',
      'paperback',
      'tachi',
    ]);
    check(r.runtimeFor(const Mihon())!.ecosystem).equals('tachi');
    check(r.runtimeFor(const Tachimanga())!.ecosystem).equals('tachi');
  });

  test('all six R5 directions are enabled when their runtimes are available', () {
    final FormatRegistry formats = cliFormatRegistry();
    final RuntimeRegistry r = registry();
    for (final (BackupFormat s, BackupFormat t) in const <(BackupFormat, BackupFormat)>[
      (Paperback(), Aidoku()),
      (Aidoku(), Paperback()),
      (Paperback(), Mihon()),
      (Mihon(), Paperback()),
      (Aidoku(), Mihon()),
      (Mihon(), Aidoku()),
    ]) {
      check(because: '$s → $t', conversionUnavailable(formats, r, s, t)).isNull();
    }
    // The direct Tachi/Tachimanga path needs no runtime at all.
    check(conversionUnavailable(formats, registry(tachiLocated: false), const Tachimanga(), const Mihon())).isNull();
    check(conversionUnavailable(formats, registry(tachiLocated: false), const Mihon(), const Tachimanga())).isNull();
  });

  test('a destination whose runtime is unavailable is disabled with a typed failure, not a fallback', () {
    final FormatRegistry formats = cliFormatRegistry();
    check(conversionUnavailable(formats, registry(tachiLocated: false), const Aidoku(), const Mihon()))
        .isA<RuntimeUnavailableFailure>();
    check(
      conversionUnavailable(
        formats,
        registry(paperback: const RuntimeUnavailableFailure('needs the built CLI executable')),
        const Aidoku(),
        const Paperback(),
      ),
    ).isA<RuntimeUnavailableFailure>();
    // No verified SY writer; forcing migration onto Tachimanga has no writer.
    check(conversionUnavailable(formats, registry(), const Aidoku(), const TachiSy())).isNotNull();
    check(
      conversionUnavailable(formats, registry(), const Mihon(), const Tachimanga(), forceMigration: true),
    ).isNotNull();
  });

  test('the desktop Paperback probe refuses `dart run` and the test runner', () {
    check(paperbackWorkerUnavailable()).isA<RuntimeUnavailableFailure>();
  });

  test('Tachi CONTENT_WARNING_MIXED is suggestive and shown by default; NSFW stays hidden until --confirm-adult', () {
    TachiPackageListing listing(String? warning) => TachiPackageListing(
      repository: TachiRepository(baseUrl: keiyoushiRepository, name: 'k', signingKeyFingerprint: keiyoushiFingerprint),
      packageId: 'p',
      name: 'P',
      versionName: '1',
      versionCode: 1,
      extensionLib: '1.5',
      sources: const <TachiIndexSource>[],
      contentWarning: warning,
    );
    ContentRatingLevel rating(String? warning) => listing(warning).contentRating;
    check(rating('CONTENT_WARNING_MIXED')).equals(ContentRatingLevel.suggestive);
    check(rating('CONTENT_WARNING_NSFW')).equals(ContentRatingLevel.unknown);
    check(const SourceRatingPolicy().allows(rating('CONTENT_WARNING_MIXED'))).isTrue();
    check(const SourceRatingPolicy().allows(rating('CONTENT_WARNING_SAFE'))).isTrue();
    check(const SourceRatingPolicy().allows(rating('CONTENT_WARNING_NSFW'))).isFalse();
    check(const SourceRatingPolicy(adultContentConfirmed: true).allows(rating('CONTENT_WARNING_NSFW'))).isTrue();
  });
}
