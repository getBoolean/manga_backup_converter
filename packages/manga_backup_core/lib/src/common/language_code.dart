/// A content language as a backup, source or chapter reports it: the single
/// definition of which values are language codes and when two of them
/// disagree.
///
/// Codes are compared by primary subtag, case-insensitively (`pt-BR` is
/// `pt`). A value that is not a code (a Paperback bundle's flag emoji such
/// as `🇬🇧`, `English`, `unknown`, `und`) parses to `null`: unknown, so it
/// never conflicts with anything. Multi-language codes (`all`, `mul`,
/// `multi`, `multiple`, `other`) parse but never conflict either.
final class LanguageCode {
  const LanguageCode._(this.tag, this.primary);

  /// The code for [value], or `null` when [value] is not a language code.
  static LanguageCode? tryParse(String? value) {
    final String? tag = value?.trim().toLowerCase().replaceAll('_', '-');
    if (tag == null) return null;
    if (_multiple.contains(tag)) return LanguageCode._(tag, tag);
    if (!_tag.hasMatch(tag)) return null;
    final String primary = tag.split('-').first;
    return primary == 'und' ? null : LanguageCode._(tag, primary);
  }

  /// The normalized tag: lower case, `-` separated (`pt-br`).
  final String tag;

  /// The primary language subtag (`pt`), or the multi-language code itself.
  final String primary;

  /// Whether this code stands for several languages rather than one.
  bool get isMultiple => _multiple.contains(primary);

  /// Whether this code and [other] can describe the same content: the same
  /// primary language, or either one multi-language.
  bool admits(LanguageCode other) => isMultiple || other.isMultiple || primary == other.primary;

  static const Set<String> _multiple = <String>{'all', 'mul', 'multi', 'multiple', 'other'};
  static final RegExp _tag = RegExp(r'^[a-z]{2,3}(-[a-z0-9]{1,8})*$');

  @override
  String toString() => tag;
}
