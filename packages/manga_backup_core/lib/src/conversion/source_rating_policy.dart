import 'dart:math';

import 'package:manga_backup_core/src/conversion/extension_entry.dart';
import 'package:source_runtime/source_contracts.dart';

/// Which sources a user may pick, by content rating.
///
/// Adult (NSFW) sources stay hidden from source selection until the user
/// enables an age-confirming setting ([adultContentConfirmed]). Every host
/// (the CLI now, the mobile apps later) applies this one policy before
/// presenting or auto-selecting sources. Ratings outside the known range
/// (unknown) are treated as adult.
final class SourceRatingPolicy {
  const SourceRatingPolicy({this.adultContentConfirmed = false, this.maxRating});

  static const int safe = 0;
  static const int suggestive = 1;
  static const int nsfw = 2;

  /// The user confirmed they are of legal age to see adult sources.
  final bool adultContentConfirmed;

  /// An optional lower ceiling chosen by the user (0 safe, 1 suggestive,
  /// 2 NSFW). It can only narrow what [adultContentConfirmed] allows.
  final int? maxRating;

  /// Whether [maxRating] asks for adult content without the age confirmation.
  bool get requestsUnconfirmedAdult => !adultContentConfirmed && (maxRating ?? safe) >= nsfw;

  /// The highest rating shown.
  int get effectiveMaxRating {
    final int ceiling = adultContentConfirmed ? nsfw : suggestive;
    return min(maxRating ?? ceiling, ceiling);
  }

  /// Whether a source with [contentRating] may be shown. Unknown ratings are
  /// treated as adult.
  bool allows(int contentRating) {
    final int rating = contentRating < safe || contentRating > nsfw ? nsfw : contentRating;
    return rating <= effectiveMaxRating;
  }

  /// The integer rating of a contract [ContentRatingLevel]; unknown is adult.
  static int ratingOf(ContentRatingLevel level) => switch (level) {
    ContentRatingLevel.safe => safe,
    ContentRatingLevel.suggestive => suggestive,
    ContentRatingLevel.nsfw || ContentRatingLevel.unknown => nsfw,
  };

  /// Splits [entries] into the visible ones and the number hidden.
  ({List<ExtensionEntry> visible, int hidden}) apply(List<ExtensionEntry> entries) {
    final List<ExtensionEntry> visible = entries.where((ExtensionEntry e) => allows(e.contentRating)).toList();
    return (visible: visible, hidden: entries.length - visible.length);
  }
}
