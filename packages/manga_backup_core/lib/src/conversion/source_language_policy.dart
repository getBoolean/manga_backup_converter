import 'package:manga_backup_core/src/conversion/extension_entry.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';

/// Which sources are searched, by content language (user decision, U7).
///
/// Only sources whose language matches the input backup's languages, plus
/// multi-language (`all`/`multi`) sources, are offered and searched. This
/// applies to every ecosystem, including the per-language sources of one
/// multi-source package (a Tachi MangaDex package exposes one source per
/// language). Languages match by primary subtag and case-insensitively
/// (`pt-BR` matches `pt`); a source whose language is not a recognisable
/// code is kept rather than hidden. A `null` [languages] set narrows
/// nothing.
final class SourceLanguagePolicy {
  const SourceLanguagePolicy({this.languages, this.explicit = false});

  /// No narrowing: every source is offered.
  const SourceLanguagePolicy.any() : languages = null, explicit = true;

  /// The languages found in [manga]: chapter languages and Aidoku-style
  /// `<lang>.<name>` source IDs. Empty when the backup records none (a Tachi
  /// backup stores no source or chapter language), in which case nothing is
  /// narrowed.
  factory SourceLanguagePolicy.inferredFrom(List<SourceMangaData> manga) {
    final found = <String>{};
    void add(String? code) {
      final String? normalized = normalizeLanguage(code);
      if (normalized != null && !multiLanguageCodes.contains(normalized)) found.add(normalized);
    }

    for (final m in manga) {
      final RegExpMatch? prefix = _sourcePrefix.firstMatch(m.sourceId ?? '');
      add(prefix?.group(1));
      for (final c in <SourceChapter>[...m.chapters, ...m.secondarySourceChapters]) {
        add(c.language);
      }
    }
    return SourceLanguagePolicy(languages: found.isEmpty ? null : found);
  }

  /// Parses a `--languages` value: comma-separated codes, or `all`/`any`
  /// for no narrowing.
  factory SourceLanguagePolicy.parse(String value) {
    final codes = <String>{
      for (final String part in value.split(','))
        if (part.trim().isNotEmpty) part.trim().toLowerCase(),
    };
    if (codes.isEmpty || codes.contains('all') || codes.contains('any')) return const SourceLanguagePolicy.any();
    final normalized = <String>{};
    for (final code in codes) {
      final String? n = normalizeLanguage(code);
      if (n == null) throw FormatException('Not a language code: "$code"');
      normalized.add(n);
    }
    return SourceLanguagePolicy(languages: normalized, explicit: true);
  }

  /// The languages searched, normalized; `null` for every language.
  final Set<String>? languages;

  /// Whether the user chose [languages] (`--languages`) rather than the
  /// backup implying them.
  final bool explicit;

  /// Language codes that mean "several languages".
  static const Set<String> multiLanguageCodes = <String>{'all', 'multi', 'multiple', 'other'};

  static final RegExp _code = RegExp(r'^[a-z]{2,3}(-[a-z0-9]{2,8})*$');
  static final RegExp _sourcePrefix = RegExp(r'^([a-z]{2,3}(?:-[a-z0-9]{2,8})?)\.[^.]');

  /// Lower-cased [code] when it looks like a BCP 47 code, else `null`.
  static String? normalizeLanguage(String? code) {
    final String? c = code?.trim().toLowerCase().replaceAll('_', '-');
    return c == null || !_code.hasMatch(c) ? null : c;
  }

  static String _primary(String code) => code.split('-').first;

  /// Whether a source in [language] is searched.
  bool allowsLanguage(String? language) {
    final Set<String>? wanted = languages;
    if (wanted == null) return true;
    final String? l = normalizeLanguage(language);
    if (l == null || multiLanguageCodes.contains(l)) return true;
    return wanted.any((String w) => _primary(w) == _primary(l));
  }

  /// Whether a source (package) listing [sourceLanguages] is offered: any
  /// matching language, or no recognisable language at all.
  bool allowsAny(Iterable<String> sourceLanguages) {
    if (languages == null) return true;
    final List<String> recognised = sourceLanguages.map(normalizeLanguage).nonNulls.toList();
    return recognised.isEmpty || recognised.any(allowsLanguage);
  }

  /// Splits [entries] into the offered ones and the number hidden.
  ({List<ExtensionEntry> visible, int hidden}) apply(List<ExtensionEntry> entries) {
    final List<ExtensionEntry> visible = entries.where((ExtensionEntry e) => allowsAny(e.languages)).toList();
    return (visible: visible, hidden: entries.length - visible.length);
  }

  /// A one-line description for the conversion report.
  String describe() {
    final Set<String>? wanted = languages;
    if (wanted == null) {
      return explicit
          ? 'Sources of every language were searched (--languages all)'
          : 'The backup records no content language, so sources of every language were searched '
                '(narrow them with --languages)';
    }
    final String list = (wanted.toList()..sort()).join(', ');
    return explicit
        ? 'Only sources in $list (and multi-language sources) were searched (--languages)'
        : 'Only sources in $list (and multi-language sources) were searched, as found in the backup '
              '(override with --languages)';
  }
}
