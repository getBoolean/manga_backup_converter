// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'paperback_backup.dart';

class PaperbackBackupMapper extends ClassMapperBase<PaperbackBackup> {
  PaperbackBackupMapper._();

  static PaperbackBackupMapper? _instance;
  static PaperbackBackupMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = PaperbackBackupMapper._());
      MapperContainer.globals.useAll([SecondsEpochDateTimeMapper()]);
    }
    return _instance!;
  }

  @override
  final String id = 'PaperbackBackup';

  static Map<String, Object> _$data(PaperbackBackup v) => v.data;
  static const Field<PaperbackBackup, Map<String, Object>> _f$data =
      Field('data', _$data);

  @override
  final MappableFields<PaperbackBackup> fields = const {
    #data: _f$data,
  };

  static PaperbackBackup _instantiate(DecodingData data) {
    return PaperbackBackup(data: data.dec(_f$data));
  }

  @override
  final Function instantiate = _instantiate;

  static PaperbackBackup fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<PaperbackBackup>(map);
  }

  static PaperbackBackup fromJson(String json) {
    return ensureInitialized().decodeJson<PaperbackBackup>(json);
  }
}

mixin PaperbackBackupMappable {
  String toJson() {
    return PaperbackBackupMapper.ensureInitialized()
        .encodeJson<PaperbackBackup>(this as PaperbackBackup);
  }

  Map<String, dynamic> toMap() {
    return PaperbackBackupMapper.ensureInitialized()
        .encodeMap<PaperbackBackup>(this as PaperbackBackup);
  }

  PaperbackBackupCopyWith<PaperbackBackup, PaperbackBackup, PaperbackBackup>
      get copyWith => _PaperbackBackupCopyWithImpl(
          this as PaperbackBackup, $identity, $identity);
  @override
  String toString() {
    return PaperbackBackupMapper.ensureInitialized()
        .stringifyValue(this as PaperbackBackup);
  }

  @override
  bool operator ==(Object other) {
    return PaperbackBackupMapper.ensureInitialized()
        .equalsValue(this as PaperbackBackup, other);
  }

  @override
  int get hashCode {
    return PaperbackBackupMapper.ensureInitialized()
        .hashValue(this as PaperbackBackup);
  }
}

extension PaperbackBackupValueCopy<$R, $Out>
    on ObjectCopyWith<$R, PaperbackBackup, $Out> {
  PaperbackBackupCopyWith<$R, PaperbackBackup, $Out> get $asPaperbackBackup =>
      $base.as((v, t, t2) => _PaperbackBackupCopyWithImpl(v, t, t2));
}

abstract class PaperbackBackupCopyWith<$R, $In extends PaperbackBackup, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  MapCopyWith<$R, String, Object, ObjectCopyWith<$R, Object, Object>> get data;
  $R call({Map<String, Object>? data});
  PaperbackBackupCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
      Then<$Out2, $R2> t);
}

class _PaperbackBackupCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, PaperbackBackup, $Out>
    implements PaperbackBackupCopyWith<$R, PaperbackBackup, $Out> {
  _PaperbackBackupCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<PaperbackBackup> $mapper =
      PaperbackBackupMapper.ensureInitialized();
  @override
  MapCopyWith<$R, String, Object, ObjectCopyWith<$R, Object, Object>>
      get data => MapCopyWith($value.data,
          (v, t) => ObjectCopyWith(v, $identity, t), (v) => call(data: v));
  @override
  $R call({Map<String, Object>? data}) =>
      $apply(FieldCopyWithData({if (data != null) #data: data}));
  @override
  PaperbackBackup $make(CopyWithData data) =>
      PaperbackBackup(data: data.get(#data, or: $value.data));

  @override
  PaperbackBackupCopyWith<$R2, PaperbackBackup, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _PaperbackBackupCopyWithImpl($value, $cast, t);
}
