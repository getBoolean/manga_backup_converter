import 'package:manga_backup_core/src/common/language_code.dart';
import 'package:manga_backup_core/src/conversion/source_manga_data.dart';

/// Which loaded sources are searched, by content language (user decision,
/// U7).
///
/// Narrowing applies only inside the extensions the user picked: each picked
/// package keeps its sources in [languages] plus multi-language ones (a
/// Tachi MangaDex package exposes one source per language). The extension
/// selection list itself is never filtered by language. Languages compare as
/// [LanguageCode]s (`pt-BR` matches `pt`); a source whose language is not a
/// recognisable code is kept rather than hidden. A `null` [languages] set
/// narrows nothing.
final class SourceLanguagePolicy {
  const SourceLanguagePolicy({this.languages, this.explicit = false});

  /// No narrowing: every source is searched.
  const SourceLanguagePolicy.any() : languages = null, explicit = true;

  /// The languages found in [manga]: chapter languages and Aidoku-style
  /// `<lang>.<name>` source IDs. Empty when the backup records none (a Tachi
  /// backup stores no source or chapter language), in which case nothing is
  /// narrowed.
  factory SourceLanguagePolicy.inferredFrom(List<SourceMangaData> manga) {
    final found = <String>{};
    void add(String? value) {
      final LanguageCode? code = LanguageCode.tryParse(value);
      if (code != null && !code.isMultiple) found.add(code.tag);
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
  /// (or any other multi-language code) for no narrowing.
  factory SourceLanguagePolicy.parse(String value) {
    final parsed = <(String, LanguageCode?)>[
      for (final String part in value.split(','))
        if (part.trim().isNotEmpty) (part.trim(), LanguageCode.tryParse(part)),
    ];
    if (parsed.isEmpty ||
        parsed.any(((String, LanguageCode?) p) => p.$1.toLowerCase() == 'any' || (p.$2?.isMultiple ?? false))) {
      return const SourceLanguagePolicy.any();
    }
    return SourceLanguagePolicy(
      languages: <String>{
        for (final (String part, LanguageCode? code) in parsed)
          code?.tag ?? (throw FormatException('Not a language code: "$part"')),
      },
      explicit: true,
    );
  }

  /// The languages searched, as normalized tags; `null` for every language.
  final Set<String>? languages;

  /// Whether the user chose [languages] (`--languages`) rather than the
  /// backup implying them.
  final bool explicit;

  static final RegExp _sourcePrefix = RegExp(r'^([a-z]{2,3}(?:-[a-z0-9]{2,8})?)\.[^.]');

  /// Whether a source in [language] is searched.
  bool allowsLanguage(String? language) {
    final Set<String>? wanted = languages;
    if (wanted == null) return true;
    final LanguageCode? code = LanguageCode.tryParse(language);
    if (code == null) return true;
    return wanted.map(LanguageCode.tryParse).nonNulls.any(code.admits);
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
