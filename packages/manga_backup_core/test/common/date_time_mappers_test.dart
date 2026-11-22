import 'package:checks/checks.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:manga_backup_core/src/common/aidoku_date_time_mapper.dart';
import 'package:manga_backup_core/src/common/paperback_date_time_mapper.dart';
import 'package:manga_backup_core/src/common/seconds_epoc_date_time_mapper.dart';
import 'package:manga_backup_core/src/formats/aidoku/aidoku_backup_history.dart';
import 'package:manga_backup_core/src/formats/paperback/paperback_backup_chapter.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('AidokuDateTimeMapper', () {
    const mapper = AidokuDateTimeMapper();

    test('decode from num treats value as seconds since epoch', () {
      // 1700000000 seconds = 2023-11-14T22:13:20.000Z
      final DateTime result = mapper.decode(1700000000);
      check(result).equals(
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
    });

    test('decode from num 0 returns Unix epoch', () {
      final DateTime result = mapper.decode(0);
      check(result).equals(DateTime.fromMillisecondsSinceEpoch(0));
    });

    test('decode from String parses ISO 8601', () {
      final DateTime result = mapper.decode('2023-11-14T22:13:20.000Z');
      check(result).equals(DateTime.utc(2023, 11, 14, 22, 13, 20));
    });

    test('decode from DateTime returns the same DateTime', () {
      final dt = DateTime.utc(2024, 6, 15, 12, 30);
      final DateTime result = mapper.decode(dt);
      check(result).equals(dt);
    });

    test('encode returns the DateTime itself', () {
      final dt = DateTime.utc(2024);
      final dynamic result = mapper.encode(dt);
      check(result).isA<DateTime>().equals(dt);
    });
  });

  group('SecondsEpochDateTimeMapper', () {
    const mapper = SecondsEpochDateTimeMapper();

    test('decode converts seconds to DateTime', () {
      final DateTime result = mapper.decode(1700000000);
      check(result).equals(
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
    });

    test('encode converts DateTime to seconds', () {
      final dt = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
      final dynamic result = mapper.encode(dt);
      check(result).isA<double>().isCloseTo(1700000000, 0.001);
    });

    test('round-trip preserves DateTime to second precision', () {
      final original = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
      final dynamic encoded = mapper.encode(original);
      final DateTime decoded = mapper.decode(encoded as num);
      check(decoded).equals(original);
    });
  });

  group('PaperbackDateCodec', () {
    test('decodes seconds since the Apple reference date as UTC', () {
      check(PaperbackDateCodec.decode(0)).equals(DateTime.utc(2001));
      check(PaperbackDateCodec.decode(700000000)).equals(DateTime.utc(2023, 3, 8, 20, 26, 40));
      check(PaperbackDateCodec.decode(700000000.5)).equals(DateTime.utc(2023, 3, 8, 20, 26, 40, 500));
    });

    test('encodes back to Apple-reference seconds', () {
      check(PaperbackDateCodec.encode(DateTime.utc(2023, 3, 8, 20, 26, 40))).equals(700000000);
      check(PaperbackDateCodec.encode(DateTime.utc(2001))).equals(0);
    });

    test('classifies sentinels and preserves their raw values', () {
      const double distantPast = -63114076800;
      const double distantFuture = 63113904000;
      check(PaperbackDateCodec.classify(PaperbackDateCodec.decode(distantPast))).equals(PaperbackDateKind.distantPast);
      check(
        PaperbackDateCodec.classify(PaperbackDateCodec.decode(distantFuture)),
      ).equals(PaperbackDateKind.distantFuture);
      check(
        PaperbackDateCodec.classify(PaperbackDateCodec.decode(-appleReferenceDateOffsetSeconds)),
      ).equals(PaperbackDateKind.unixEpoch);
      check(PaperbackDateCodec.classify(PaperbackDateCodec.decode(700000000))).equals(PaperbackDateKind.date);

      check(PaperbackDateCodec.encode(PaperbackDateCodec.decode(distantPast))).equals(distantPast);
      check(PaperbackDateCodec.encode(PaperbackDateCodec.decode(distantFuture))).equals(distantFuture);
    });

    test('meaningful drops absent values and sentinels only', () {
      check(PaperbackDateCodec.meaningful(null)).isNull();
      check(PaperbackDateCodec.meaningful(PaperbackDateCodec.decode(-63114076800))).isNull();
      check(PaperbackDateCodec.meaningful(DateTime.utc(1970))).isNull();
      check(PaperbackDateCodec.meaningful(DateTime.utc(1995, 6))).equals(DateTime.utc(1995, 6));
    });
  });

  group('Paperback and Unix-seconds callers share one process', () {
    Map<String, dynamic> chapterMap() => <String, dynamic>{
      'volume': 0,
      'langCode': 'en',
      'group': '',
      'sortingIndex': 0,
      'id': 'c1',
      'chapNum': 1,
      'chapterId': 'c1',
      'time': 700000000,
      'isNew': false,
      'name': 'C1',
      'sourceManga': <String, dynamic>{'type': '__SOURCE_MANGA_V4', 'id': 'sm'},
    };

    test('Paperback decoding does not change the global Unix-seconds DateTime mapper', () {
      final PaperbackBackupChapter chapter = PaperbackBackupChapter.fromMap(chapterMap());
      check(chapter.time).equals(DateTime.utc(2023, 3, 8, 20, 26, 40));

      // SecondsEpochDateTimeMapper is what Mangayomi/Tachi/Tachimanga use.
      final DateTime unix = MapperContainer.globals.fromValue<DateTime>(1700000000);
      check(unix).equals(DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000));
    });

    test('Paperback dates are independent of whichever DateTime mapper registered last', () {
      // Aidoku registers a different global DateTime mapper.
      AidokuBackupHistoryMapper.ensureInitialized();
      final PaperbackBackupChapter chapter = PaperbackBackupChapter.fromMap(chapterMap());
      check(chapter.time).equals(DateTime.utc(2023, 3, 8, 20, 26, 40));
      check(chapter.toMap()['time'] as num).equals(700000000);

      MapperContainer.globals.use(const SecondsEpochDateTimeMapper());
      final PaperbackBackupChapter again = PaperbackBackupChapter.fromMap(chapterMap());
      check(again.toMap()['time'] as num).equals(700000000);
    });
  });
}
