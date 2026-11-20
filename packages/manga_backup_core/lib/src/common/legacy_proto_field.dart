import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';

/// Reads a varint field that was removed from a protobuf schema but may still
/// be present in older backups (the parser keeps it as an unknown field).
///
/// Returns the last value written for [tagNumber], or `null` if absent.
int? legacyVarintField(GeneratedMessage message, int tagNumber) {
  final List<Int64>? varints = message.unknownFields.getField(tagNumber)?.varints;
  if (varints == null || varints.isEmpty) return null;
  return varints.last.toInt();
}
