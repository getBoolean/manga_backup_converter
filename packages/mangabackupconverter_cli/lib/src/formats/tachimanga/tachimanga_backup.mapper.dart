// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'tachimanga_backup.dart';

class TachimangaBackupMapper extends ClassMapperBase<TachimangaBackup> {
  TachimangaBackupMapper._();

  static TachimangaBackupMapper? _instance;
  static TachimangaBackupMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TachimangaBackupMapper._());
      MapperContainer.globals.useAll([SecondsEpochDateTimeMapper()]);
      TachimangaBackupMetaMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'TachimangaBackup';

  static TachimangaBackupMeta _$meta(TachimangaBackup v) => v.meta;
  static const Field<TachimangaBackup, TachimangaBackupMeta> _f$meta =
      Field('meta', _$meta);
  static String? _$name(TachimangaBackup v) => v.name;
  static const Field<TachimangaBackup, String> _f$name =
      Field('name', _$name, opt: true);

  @override
  final MappableFields<TachimangaBackup> fields = const {
    #meta: _f$meta,
    #name: _f$name,
  };

  static TachimangaBackup _instantiate(DecodingData data) {
    return TachimangaBackup(meta: data.dec(_f$meta), name: data.dec(_f$name));
  }

  @override
  final Function instantiate = _instantiate;

  static TachimangaBackup fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<TachimangaBackup>(map);
  }

  static TachimangaBackup fromJson(String json) {
    return ensureInitialized().decodeJson<TachimangaBackup>(json);
  }
}

mixin TachimangaBackupMappable {
  String toJson() {
    return TachimangaBackupMapper.ensureInitialized()
        .encodeJson<TachimangaBackup>(this as TachimangaBackup);
  }

  Map<String, dynamic> toMap() {
    return TachimangaBackupMapper.ensureInitialized()
        .encodeMap<TachimangaBackup>(this as TachimangaBackup);
  }

  TachimangaBackupCopyWith<TachimangaBackup, TachimangaBackup, TachimangaBackup>
      get copyWith => _TachimangaBackupCopyWithImpl(
          this as TachimangaBackup, $identity, $identity);
  @override
  String toString() {
    return TachimangaBackupMapper.ensureInitialized()
        .stringifyValue(this as TachimangaBackup);
  }

  @override
  bool operator ==(Object other) {
    return TachimangaBackupMapper.ensureInitialized()
        .equalsValue(this as TachimangaBackup, other);
  }

  @override
  int get hashCode {
    return TachimangaBackupMapper.ensureInitialized()
        .hashValue(this as TachimangaBackup);
  }
}

extension TachimangaBackupValueCopy<$R, $Out>
    on ObjectCopyWith<$R, TachimangaBackup, $Out> {
  TachimangaBackupCopyWith<$R, TachimangaBackup, $Out>
      get $asTachimangaBackup =>
          $base.as((v, t, t2) => _TachimangaBackupCopyWithImpl(v, t, t2));
}

abstract class TachimangaBackupCopyWith<$R, $In extends TachimangaBackup, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  TachimangaBackupMetaCopyWith<$R, TachimangaBackupMeta, TachimangaBackupMeta>
      get meta;
  $R call({TachimangaBackupMeta? meta, String? name});
  TachimangaBackupCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
      Then<$Out2, $R2> t);
}

class _TachimangaBackupCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, TachimangaBackup, $Out>
    implements TachimangaBackupCopyWith<$R, TachimangaBackup, $Out> {
  _TachimangaBackupCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<TachimangaBackup> $mapper =
      TachimangaBackupMapper.ensureInitialized();
  @override
  TachimangaBackupMetaCopyWith<$R, TachimangaBackupMeta, TachimangaBackupMeta>
      get meta => $value.meta.copyWith.$chain((v) => call(meta: v));
  @override
  $R call({TachimangaBackupMeta? meta, Object? name = $none}) =>
      $apply(FieldCopyWithData(
          {if (meta != null) #meta: meta, if (name != $none) #name: name}));
  @override
  TachimangaBackup $make(CopyWithData data) => TachimangaBackup(
      meta: data.get(#meta, or: $value.meta),
      name: data.get(#name, or: $value.name));

  @override
  TachimangaBackupCopyWith<$R2, TachimangaBackup, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _TachimangaBackupCopyWithImpl($value, $cast, t);
}
