import 'package:checks/checks.dart';
import 'package:manga_backup_core/manga_backup_core.dart';
import 'package:test/scaffolding.dart';

void main() {
  group('LanguageCode', () {
    // value → (tag, primary, isMultiple), or null when not a code. The
    // reconciler (`knownLanguage`) and the language policy
    // (`normalizeLanguage`) used to disagree on the rows marked "changed".
    final table = <String?, (String, String, bool)?>{
      null: null,
      '': null,
      'en': ('en', 'en', false),
      'en-US': ('en-us', 'en', false),
      'pt_BR': ('pt-br', 'pt', false),
      ' JA ': ('ja', 'ja', false),
      'zh-x-yue': ('zh-x-yue', 'zh', false), // changed: the policy rejected one-letter subtags
      'all': ('all', 'all', true), // changed: a real code in the reconciler
      'mul': ('mul', 'mul', true), // changed: a real code in both
      'multi': ('multi', 'multi', true),
      'other': ('other', 'other', true),
      'und': null, // changed: a real code in the policy
      'unknown': null,
      'English': null,
      '🇬🇧': null,
      'en-': null, // changed: the reconciler read the primary subtag
    };
    for (final MapEntry<String?, (String, String, bool)?> row in table.entries) {
      test('parses ${row.key == null ? 'null' : '"${row.key}"'}', () {
        final LanguageCode? code = LanguageCode.tryParse(row.key);
        final (String, String, bool)? want = row.value;
        if (want == null) {
          check(code).isNull();
        } else {
          check(code).isNotNull();
          check((code!.tag, code.primary, code.isMultiple)).equals(want);
        }
      });
    }

    test('codes admit the same primary language; multi-language codes admit every language', () {
      LanguageCode c(String v) => LanguageCode.tryParse(v)!;
      check(c('pt-BR').admits(c('pt'))).isTrue();
      check(c('en').admits(c('ja'))).isFalse();
      check(c('en').admits(c('all'))).isTrue();
      check(c('mul').admits(c('ja'))).isTrue();
    });
  });
}
