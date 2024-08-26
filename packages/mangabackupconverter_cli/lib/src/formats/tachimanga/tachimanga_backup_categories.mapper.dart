// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'tachimanga_backup_categories.dart';

class TachimangaBackupCategoriesMapper
    extends ClassMapperBase<TachimangaBackupCategories> {
  TachimangaBackupCategoriesMapper._();

  static TachimangaBackupCategoriesMapper? _instance;
  static TachimangaBackupCategoriesMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals
          .use(_instance = TachimangaBackupCategoriesMapper._());
    }
    return _instance!;
  }

  @override
  final String id = 'TachimangaBackupCategories';

  static int _$id(TachimangaBackupCategories v) => v.id;
  static const Field<TachimangaBackupCategories, int> _f$id = Field('id', _$id);
  static String _$name(TachimangaBackupCategories v) => v.name;
  static const Field<TachimangaBackupCategories, String> _f$name =
      Field('name', _$name);
  static int _$order(TachimangaBackupCategories v) => v.order;
  static const Field<TachimangaBackupCategories, int> _f$order =
      Field('order', _$order);
  static bool _$isDefault(TachimangaBackupCategories v) => v.isDefault;
  static const Field<TachimangaBackupCategories, bool> _f$isDefault =
      Field('isDefault', _$isDefault, key: 'is_default');

  @override
  final MappableFields<TachimangaBackupCategories> fields = const {
    #id: _f$id,
    #name: _f$name,
    #order: _f$order,
    #isDefault: _f$isDefault,
  };

  static TachimangaBackupCategories _instantiate(DecodingData data) {
    return TachimangaBackupCategories(
        id: data.dec(_f$id),
        name: data.dec(_f$name),
        order: data.dec(_f$order),
        isDefault: data.dec(_f$isDefault));
  }

  @override
  final Function instantiate = _instantiate;

  static TachimangaBackupCategories fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<TachimangaBackupCategories>(map);
  }

  static TachimangaBackupCategories fromJson(String json) {
    return ensureInitialized().decodeJson<TachimangaBackupCategories>(json);
  }
}

mixin TachimangaBackupCategoriesMappable {
  String toJson() {
    return TachimangaBackupCategoriesMapper.ensureInitialized()
        .encodeJson<TachimangaBackupCategories>(
            this as TachimangaBackupCategories);
  }

  Map<String, dynamic> toMap() {
    return TachimangaBackupCategoriesMapper.ensureInitialized()
        .encodeMap<TachimangaBackupCategories>(
            this as TachimangaBackupCategories);
  }

  TachimangaBackupCategoriesCopyWith<TachimangaBackupCategories,
          TachimangaBackupCategories, TachimangaBackupCategories>
      get copyWith => _TachimangaBackupCategoriesCopyWithImpl(
          this as TachimangaBackupCategories, $identity, $identity);
  @override
  String toString() {
    return TachimangaBackupCategoriesMapper.ensureInitialized()
        .stringifyValue(this as TachimangaBackupCategories);
  }

  @override
  bool operator ==(Object other) {
    return TachimangaBackupCategoriesMapper.ensureInitialized()
        .equalsValue(this as TachimangaBackupCategories, other);
  }

  @override
  int get hashCode {
    return TachimangaBackupCategoriesMapper.ensureInitialized()
        .hashValue(this as TachimangaBackupCategories);
  }
}

extension TachimangaBackupCategoriesValueCopy<$R, $Out>
    on ObjectCopyWith<$R, TachimangaBackupCategories, $Out> {
  TachimangaBackupCategoriesCopyWith<$R, TachimangaBackupCategories, $Out>
      get $asTachimangaBackupCategories => $base
          .as((v, t, t2) => _TachimangaBackupCategoriesCopyWithImpl(v, t, t2));
}

abstract class TachimangaBackupCategoriesCopyWith<
    $R,
    $In extends TachimangaBackupCategories,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  $R call({int? id, String? name, int? order, bool? isDefault});
  TachimangaBackupCategoriesCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
      Then<$Out2, $R2> t);
}

class _TachimangaBackupCategoriesCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, TachimangaBackupCategories, $Out>
    implements
        TachimangaBackupCategoriesCopyWith<$R, TachimangaBackupCategories,
            $Out> {
  _TachimangaBackupCategoriesCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<TachimangaBackupCategories> $mapper =
      TachimangaBackupCategoriesMapper.ensureInitialized();
  @override
  $R call({int? id, String? name, int? order, bool? isDefault}) =>
      $apply(FieldCopyWithData({
        if (id != null) #id: id,
        if (name != null) #name: name,
        if (order != null) #order: order,
        if (isDefault != null) #isDefault: isDefault
      }));
  @override
  TachimangaBackupCategories $make(CopyWithData data) =>
      TachimangaBackupCategories(
          id: data.get(#id, or: $value.id),
          name: data.get(#name, or: $value.name),
          order: data.get(#order, or: $value.order),
          isDefault: data.get(#isDefault, or: $value.isDefault));

  @override
  TachimangaBackupCategoriesCopyWith<$R2, TachimangaBackupCategories, $Out2>
      $chain<$R2, $Out2>(Then<$Out2, $R2> t) =>
          _TachimangaBackupCategoriesCopyWithImpl($value, $cast, t);
}
