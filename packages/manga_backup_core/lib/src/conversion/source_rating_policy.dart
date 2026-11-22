import 'package:manga_backup_core/src/conversion/extension_entry.dart';
import 'package:source_runtime/source_contracts.dart';

/// Which sources a user may pick, by content rating.
///
/// Adult (NSFW) sources stay hidden from source selection until the user
/// enables an age-confirming setting ([adultContentConfirmed]). Every host
/// (the CLI now, the mobile apps later) applies this one policy before
/// presenting or auto-selecting sources. An unknown rating is hidden exactly
/// like an adult one.
final class SourceRatingPolicy {
  const SourceRatingPolicy({this.adultContentConfirmed = false, this.maxRating});

  /// The user confirmed they are of legal age to see adult sources.
  final bool adultContentConfirmed;

  /// An optional lower ceiling chosen by the user. It can only narrow what
  /// [adultContentConfirmed] allows.
  final ContentRatingLevel? maxRating;

  /// Whether [maxRating] asks for adult content without the age confirmation.
  bool get requestsUnconfirmedAdult => !adultContentConfirmed && _rank(maxRating ?? ContentRatingLevel.safe) >= _adult;

  /// The highest rating shown.
  ContentRatingLevel get effectiveMaxRating {
    final ContentRatingLevel ceiling = adultContentConfirmed ? ContentRatingLevel.nsfw : ContentRatingLevel.suggestive;
    final ContentRatingLevel? chosen = maxRating;
    return chosen == null || _rank(chosen) > _rank(ceiling) ? ceiling : chosen;
  }

  /// Whether a source rated [rating] may be shown.
  bool allows(ContentRatingLevel rating) => _rank(rating) <= _rank(effectiveMaxRating);

  static const int _adult = 2;

  /// Unknown ranks with NSFW: it is never shown before the age confirmation.
  static int _rank(ContentRatingLevel level) => switch (level) {
    ContentRatingLevel.safe => 0,
    ContentRatingLevel.suggestive => 1,
    ContentRatingLevel.nsfw || ContentRatingLevel.unknown => _adult,
  };

  /// Splits [entries] into the visible ones and the number hidden.
  ({List<ExtensionEntry> visible, int hidden}) apply(List<ExtensionEntry> entries) {
    final List<ExtensionEntry> visible = entries.where((ExtensionEntry e) => allows(e.contentRating)).toList();
    return (visible: visible, hidden: entries.length - visible.length);
  }
}
