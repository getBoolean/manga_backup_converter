import 'package:dart_mappable/dart_mappable.dart';

/// Seconds between the Unix epoch (1970-01-01) and the Apple reference date
/// (2001-01-01T00:00:00Z).
const int appleReferenceDateOffsetSeconds = 978307200;

/// How a decoded Paperback timestamp should be interpreted.
enum PaperbackDateKind {
  /// An ordinary timestamp.
  date,

  /// Swift `Date.distantPast` (year 1): "no date".
  distantPast,

  /// Swift `Date.distantFuture` (year 4001): "no date".
  distantFuture,

  /// 1970-01-01T00:00:00Z, which is what a JavaScript extension's `new Date(0)`
  /// becomes once Paperback stores it: "unknown date".
  unixEpoch,
}

/// Codec for Paperback (.pas4) timestamps.
///
/// Paperback is a Swift app; its backup JSON uses the default `JSONEncoder`
/// date strategy, which writes a `Date` as a floating-point number of seconds
/// since the Apple reference date (2001-01-01T00:00:00Z) — not since the Unix
/// epoch. Unix-seconds callers (Mangayomi, Tachi, Tachimanga) keep using
/// `SecondsEpochDateTimeMapper`.
///
/// Decoded values are UTC [DateTime]s. Sentinel values are decoded to the
/// instant they encode (so they round-trip unchanged) and are classified with
/// [classify]; use [meaningful] when normalizing into pipeline data.
abstract final class PaperbackDateCodec {
  // Swift's distantPast/distantFuture are about ±6.31e10 reference seconds.
  // Anything this far out is a sentinel, never a real reading/upload date.
  static const double _sentinelMagnitudeSeconds = 6.0e10;

  static DateTime decode(num appleReferenceSeconds) => DateTime.fromMillisecondsSinceEpoch(
    ((appleReferenceSeconds + appleReferenceDateOffsetSeconds) * 1000).round(),
    isUtc: true,
  );

  static num encode(DateTime date) => date.millisecondsSinceEpoch / 1000 - appleReferenceDateOffsetSeconds;

  static PaperbackDateKind classify(DateTime date) {
    final num seconds = encode(date);
    if (seconds <= -_sentinelMagnitudeSeconds) return PaperbackDateKind.distantPast;
    if (seconds >= _sentinelMagnitudeSeconds) return PaperbackDateKind.distantFuture;
    if (date.millisecondsSinceEpoch == 0) return PaperbackDateKind.unixEpoch;
    return PaperbackDateKind.date;
  }

  /// Returns [date] unless it is absent or a "no date" sentinel.
  static DateTime? meaningful(DateTime? date) {
    if (date == null) return null;
    return classify(date) == PaperbackDateKind.date ? date : null;
  }
}

/// Field hook that applies [PaperbackDateCodec] to a Paperback date field.
///
/// A hook (rather than a `SimpleMapper<DateTime>` in `includeCustomMappers`)
/// is required because generated mappers register custom mappers in the
/// process-wide `MapperContainer.globals`, keyed by type: a second
/// `DateTime` mapper would silently replace the Unix-seconds mapper used by
/// other formats, or be replaced by it. The hook converts before the container
/// is consulted, so it is independent of which `DateTime` mapper is
/// registered.
class PaperbackDateHook extends MappingHook {
  const PaperbackDateHook();

  @override
  Object? beforeDecode(Object? value) => value is num ? PaperbackDateCodec.decode(value) : value;

  @override
  Object? beforeEncode(Object? value) => value is DateTime ? PaperbackDateCodec.encode(value) : value;
}
