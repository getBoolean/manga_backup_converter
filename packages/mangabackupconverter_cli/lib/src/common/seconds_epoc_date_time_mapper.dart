import 'package:dart_mappable/dart_mappable.dart';

class SecondsEpochDateTimeMapper extends SimpleMapper<DateTime> {
  const SecondsEpochDateTimeMapper();

  @override
  DateTime decode(Object value) {
    return DateTime.fromMillisecondsSinceEpoch(((value as num) * 1000).round());
  }

  @override
  dynamic encode(DateTime self) {
    return self.millisecondsSinceEpoch / 1000;
  }
}
