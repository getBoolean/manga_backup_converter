// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'tachi_source.dart';

class TachiSourceMapper extends ClassMapperBase<TachiSource> {
  TachiSourceMapper._();

  static TachiSourceMapper? _instance;
  static TachiSourceMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TachiSourceMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'TachiSource';

  static String _$name(TachiSource v) => v.name;
  static const Field<TachiSource, String> _f$name = Field('name', _$name);
  static int _$sourceId(TachiSource v) => v.sourceId;
  static const Field<TachiSource, int> _f$sourceId =
      Field('sourceId', _$sourceId);

  @override
  final MappableFields<TachiSource> fields = const {
    #name: _f$name,
    #sourceId: _f$sourceId,
  };

  static TachiSource _instantiate(DecodingData data) {
    return TachiSource(
        name: data.dec(_f$name), sourceId: data.dec(_f$sourceId));
  }

  @override
  final Function instantiate = _instantiate;

  static TachiSource fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<TachiSource>(map);
  }

  static TachiSource fromJson(String json) {
    return ensureInitialized().decodeJson<TachiSource>(json);
  }
}

mixin TachiSourceMappable {
  String toJson() {
    return TachiSourceMapper.ensureInitialized()
        .encodeJson<TachiSource>(this as TachiSource);
  }

  Map<String, dynamic> toMap() {
    return TachiSourceMapper.ensureInitialized()
        .encodeMap<TachiSource>(this as TachiSource);
  }

  TachiSourceCopyWith<TachiSource, TachiSource, TachiSource> get copyWith =>
      _TachiSourceCopyWithImpl(this as TachiSource, $identity, $identity);
  @override
  String toString() {
    return TachiSourceMapper.ensureInitialized()
        .stringifyValue(this as TachiSource);
  }

  @override
  bool operator ==(Object other) {
    return TachiSourceMapper.ensureInitialized()
        .equalsValue(this as TachiSource, other);
  }

  @override
  int get hashCode {
    return TachiSourceMapper.ensureInitialized().hashValue(this as TachiSource);
  }
}

extension TachiSourceValueCopy<$R, $Out>
    on ObjectCopyWith<$R, TachiSource, $Out> {
  TachiSourceCopyWith<$R, TachiSource, $Out> get $asTachiSource =>
      $base.as((v, t, t2) => _TachiSourceCopyWithImpl(v, t, t2));
}

abstract class TachiSourceCopyWith<$R, $In extends TachiSource, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  $R call({String? name, int? sourceId});
  TachiSourceCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _TachiSourceCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, TachiSource, $Out>
    implements TachiSourceCopyWith<$R, TachiSource, $Out> {
  _TachiSourceCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<TachiSource> $mapper =
      TachiSourceMapper.ensureInitialized();
  @override
  $R call({String? name, int? sourceId}) => $apply(FieldCopyWithData({
        if (name != null) #name: name,
        if (sourceId != null) #sourceId: sourceId
      }));
  @override
  TachiSource $make(CopyWithData data) => TachiSource(
      name: data.get(#name, or: $value.name),
      sourceId: data.get(#sourceId, or: $value.sourceId));

  @override
  TachiSourceCopyWith<$R2, TachiSource, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _TachiSourceCopyWithImpl($value, $cast, t);
}
