// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'tachibk_backup.dart';

class TachibkBackupMapper extends ClassMapperBase<TachibkBackup> {
  TachibkBackupMapper._();

  static TachibkBackupMapper? _instance;
  static TachibkBackupMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TachibkBackupMapper._());
      MapperContainer.globals.useAll([SecondsEpochDateTimeMapper()]);
    }
    return _instance!;
  }

  @override
  final String id = 'TachibkBackup';

  static Map<String, Object> _$data(TachibkBackup v) => v.data;
  static const Field<TachibkBackup, Map<String, Object>> _f$data =
      Field('data', _$data);

  @override
  final MappableFields<TachibkBackup> fields = const {
    #data: _f$data,
  };

  static TachibkBackup _instantiate(DecodingData data) {
    return TachibkBackup(data: data.dec(_f$data));
  }

  @override
  final Function instantiate = _instantiate;

  static TachibkBackup fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<TachibkBackup>(map);
  }

  static TachibkBackup fromJson(String json) {
    return ensureInitialized().decodeJson<TachibkBackup>(json);
  }
}

mixin TachibkBackupMappable {
  String toJson() {
    return TachibkBackupMapper.ensureInitialized()
        .encodeJson<TachibkBackup>(this as TachibkBackup);
  }

  Map<String, dynamic> toMap() {
    return TachibkBackupMapper.ensureInitialized()
        .encodeMap<TachibkBackup>(this as TachibkBackup);
  }

  TachibkBackupCopyWith<TachibkBackup, TachibkBackup, TachibkBackup>
      get copyWith => _TachibkBackupCopyWithImpl(
          this as TachibkBackup, $identity, $identity);
  @override
  String toString() {
    return TachibkBackupMapper.ensureInitialized()
        .stringifyValue(this as TachibkBackup);
  }

  @override
  bool operator ==(Object other) {
    return TachibkBackupMapper.ensureInitialized()
        .equalsValue(this as TachibkBackup, other);
  }

  @override
  int get hashCode {
    return TachibkBackupMapper.ensureInitialized()
        .hashValue(this as TachibkBackup);
  }
}

extension TachibkBackupValueCopy<$R, $Out>
    on ObjectCopyWith<$R, TachibkBackup, $Out> {
  TachibkBackupCopyWith<$R, TachibkBackup, $Out> get $asTachibkBackup =>
      $base.as((v, t, t2) => _TachibkBackupCopyWithImpl(v, t, t2));
}

abstract class TachibkBackupCopyWith<$R, $In extends TachibkBackup, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  MapCopyWith<$R, String, Object, ObjectCopyWith<$R, Object, Object>> get data;
  $R call({Map<String, Object>? data});
  TachibkBackupCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _TachibkBackupCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, TachibkBackup, $Out>
    implements TachibkBackupCopyWith<$R, TachibkBackup, $Out> {
  _TachibkBackupCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<TachibkBackup> $mapper =
      TachibkBackupMapper.ensureInitialized();
  @override
  MapCopyWith<$R, String, Object, ObjectCopyWith<$R, Object, Object>>
      get data => MapCopyWith($value.data,
          (v, t) => ObjectCopyWith(v, $identity, t), (v) => call(data: v));
  @override
  $R call({Map<String, Object>? data}) =>
      $apply(FieldCopyWithData({if (data != null) #data: data}));
  @override
  TachibkBackup $make(CopyWithData data) =>
      TachibkBackup(data: data.get(#data, or: $value.data));

  @override
  TachibkBackupCopyWith<$R2, TachibkBackup, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _TachibkBackupCopyWithImpl($value, $cast, t);
}
