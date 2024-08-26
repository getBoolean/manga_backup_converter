// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'tachimanga_backup_db.dart';

class TachimangaBackupDbMapper extends ClassMapperBase<TachimangaBackupDb> {
  TachimangaBackupDbMapper._();

  static TachimangaBackupDbMapper? _instance;
  static TachimangaBackupDbMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TachimangaBackupDbMapper._());
      TachimangaBackupCategoriesMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'TachimangaBackupDb';

  static List<TachimangaBackupCategories> _$categories(TachimangaBackupDb v) =>
      v.categories;
  static const Field<TachimangaBackupDb, List<TachimangaBackupCategories>>
      _f$categories = Field('categories', _$categories);

  @override
  final MappableFields<TachimangaBackupDb> fields = const {
    #categories: _f$categories,
  };

  static TachimangaBackupDb _instantiate(DecodingData data) {
    return TachimangaBackupDb(categories: data.dec(_f$categories));
  }

  @override
  final Function instantiate = _instantiate;
}

mixin TachimangaBackupDbMappable {
  TachimangaBackupDbCopyWith<TachimangaBackupDb, TachimangaBackupDb,
          TachimangaBackupDb>
      get copyWith => _TachimangaBackupDbCopyWithImpl(
          this as TachimangaBackupDb, $identity, $identity);
  @override
  String toString() {
    return TachimangaBackupDbMapper.ensureInitialized()
        .stringifyValue(this as TachimangaBackupDb);
  }

  @override
  bool operator ==(Object other) {
    return TachimangaBackupDbMapper.ensureInitialized()
        .equalsValue(this as TachimangaBackupDb, other);
  }

  @override
  int get hashCode {
    return TachimangaBackupDbMapper.ensureInitialized()
        .hashValue(this as TachimangaBackupDb);
  }
}

extension TachimangaBackupDbValueCopy<$R, $Out>
    on ObjectCopyWith<$R, TachimangaBackupDb, $Out> {
  TachimangaBackupDbCopyWith<$R, TachimangaBackupDb, $Out>
      get $asTachimangaBackupDb =>
          $base.as((v, t, t2) => _TachimangaBackupDbCopyWithImpl(v, t, t2));
}

abstract class TachimangaBackupDbCopyWith<$R, $In extends TachimangaBackupDb,
    $Out> implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<
      $R,
      TachimangaBackupCategories,
      TachimangaBackupCategoriesCopyWith<$R, TachimangaBackupCategories,
          TachimangaBackupCategories>> get categories;
  $R call({List<TachimangaBackupCategories>? categories});
  TachimangaBackupDbCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(
      Then<$Out2, $R2> t);
}

class _TachimangaBackupDbCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, TachimangaBackupDb, $Out>
    implements TachimangaBackupDbCopyWith<$R, TachimangaBackupDb, $Out> {
  _TachimangaBackupDbCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<TachimangaBackupDb> $mapper =
      TachimangaBackupDbMapper.ensureInitialized();
  @override
  ListCopyWith<
      $R,
      TachimangaBackupCategories,
      TachimangaBackupCategoriesCopyWith<$R, TachimangaBackupCategories,
          TachimangaBackupCategories>> get categories => ListCopyWith(
      $value.categories,
      (v, t) => v.copyWith.$chain(t),
      (v) => call(categories: v));
  @override
  $R call({List<TachimangaBackupCategories>? categories}) => $apply(
      FieldCopyWithData({if (categories != null) #categories: categories}));
  @override
  TachimangaBackupDb $make(CopyWithData data) => TachimangaBackupDb(
      categories: data.get(#categories, or: $value.categories));

  @override
  TachimangaBackupDbCopyWith<$R2, TachimangaBackupDb, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _TachimangaBackupDbCopyWithImpl($value, $cast, t);
}
