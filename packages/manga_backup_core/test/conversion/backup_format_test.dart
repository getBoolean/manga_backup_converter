import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('BackupFormat', () {
    test('values contains all 9 formats', () {
      check(BackupFormat.values).length.equals(9);
      check(BackupFormat.values[0]).isA<Aidoku>();
      check(BackupFormat.values[1]).isA<Paperback>();
      check(BackupFormat.values[2]).isA<Mihon>();
      check(BackupFormat.values[3]).isA<TachiSy>();
      check(BackupFormat.values[4]).isA<TachiJ2k>();
      check(BackupFormat.values[5]).isA<TachiYokai>();
      check(BackupFormat.values[6]).isA<TachiNeko>();
      check(BackupFormat.values[7]).isA<Tachimanga>();
      check(BackupFormat.values[8]).isA<Mangayomi>();
    });

    test('byName resolves each alias correctly', () {
      check(BackupFormat.byName('aidoku')).isA<Aidoku>();
      check(BackupFormat.byName('paperback')).isA<Paperback>();
      check(BackupFormat.byName('mihon')).isA<Mihon>();
      check(BackupFormat.byName('sy')).isA<TachiSy>();
      check(BackupFormat.byName('j2k')).isA<TachiJ2k>();
      check(BackupFormat.byName('yokai')).isA<TachiYokai>();
      check(BackupFormat.byName('neko')).isA<TachiNeko>();
      check(BackupFormat.byName('tachimanga')).isA<Tachimanga>();
      check(BackupFormat.byName('mangayomi')).isA<Mangayomi>();
    });

    test('byName throws ArgumentError for unknown alias', () {
      check(() => BackupFormat.byName('unknown')).throws<ArgumentError>();
    });

    test('byExtension resolves .aib to Aidoku', () {
      check(BackupFormat.byExtension('.aib')).isNotNull().isA<Aidoku>();
    });

    test('byExtension resolves .tachibk to Mihon (first Tachi fork)', () {
      check(BackupFormat.byExtension('.tachibk')).isNotNull().isA<Mihon>();
    });

    test('byExtension resolves .pas4, .tmb, and .backup', () {
      check(BackupFormat.byExtension('.pas4')).isNotNull().isA<Paperback>();
      check(BackupFormat.byExtension('.tmb')).isNotNull().isA<Tachimanga>();
      check(BackupFormat.byExtension('.backup')).isNotNull().isA<Mangayomi>();
    });

    test('byExtension returns null for unknown extension', () {
      check(BackupFormat.byExtension('.zip')).isNull();
      check(BackupFormat.byExtension('.json')).isNull();
      check(BackupFormat.byExtension('')).isNull();
    });

    test('validExtensions contains all unique extensions', () {
      final List<String> extensions = BackupFormat.validExtensions;
      check(extensions).contains('.aib');
      check(extensions).contains('.pas4');
      check(extensions).contains('.tachibk');
      check(extensions).contains('.proto.gz');
      check(extensions).contains('.tmb');
      check(extensions).contains('.backup');
      check(extensions).length.equals(6);
    });

    test('alias and toString for each format', () {
      final expected = <BackupFormat, (String, String)>{
        const Aidoku(): ('aidoku', 'Aidoku'),
        const Paperback(): ('paperback', 'Paperback'),
        const Mihon(): ('mihon', 'Mihon'),
        const TachiSy(): ('sy', 'TachiSy'),
        const TachiJ2k(): ('j2k', 'TachiJ2k'),
        const TachiYokai(): ('yokai', 'TachiYokai'),
        const TachiNeko(): ('neko', 'TachiNeko'),
        const Tachimanga(): ('tachimanga', 'Tachimanga'),
        const Mangayomi(): ('mangayomi', 'Mangayomi'),
      };
      for (final MapEntry<BackupFormat, (String, String)> entry in expected.entries) {
        check(entry.key.alias).equals(entry.value.$1);
        check(entry.key.toString()).equals(entry.value.$2);
      }
    });

    test('formats carry no writer: the portable FormatRegistry supplies one per writable format (KTD15)', () {
      final registry = FormatRegistry.portable();
      check(registry.writerFor(const Aidoku())).isA<AidokuBackupBuilder>();
      check(registry.writerFor(const Paperback())).isA<PaperbackBackupBuilder>();
      check(registry.writerFor(const Mihon())).isA<TachiBackupBuilder>();
      for (final BackupFormat f in <BackupFormat>[
        const TachiSy(),
        const TachiJ2k(),
        const TachiYokai(),
        const TachiNeko(),
        const Tachimanga(),
        const Mangayomi(),
      ]) {
        check(because: '$f has no verified writer', registry.writerFor(f)).isNull();
      }
      check(registry.writableFormats).deepEquals(<BackupFormat>[const Aidoku(), const Paperback(), const Mihon()]);
    });

    test('equality: same type are equal, different types are not', () {
      check(const Aidoku()).equals(const Aidoku());
      check(const Paperback()).equals(const Paperback());
      check(const Mihon()).equals(const Mihon());
      check(const Aidoku() as BackupFormat).not((it) => it.equals(const Paperback()));
      check(const Mihon() as BackupFormat).not((it) => it.equals(const TachiSy()));
      check(const Aidoku().hashCode).equals(const Aidoku().hashCode);
    });
  });
}
