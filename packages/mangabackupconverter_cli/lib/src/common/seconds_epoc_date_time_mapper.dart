import 'package:dart_mappable/dart_mappable.dart';

class SecondsEpochDateTimeMapper extends SimpleMapper<DateTime> {
  const SecondsEpochDateTimeMapper();

  @override
  DateTime decode(dynamic value) {
    return DateTime.fromMillisecondsSinceEpoch(value * 1000);
  }

  @override
  dynamic encode(DateTime self) {
    return self.millisecondsSinceEpoch / 1000;
  }
}
