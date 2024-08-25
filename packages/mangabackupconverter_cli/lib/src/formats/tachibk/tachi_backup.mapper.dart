// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, unnecessary_cast, override_on_non_overriding_member
// ignore_for_file: strict_raw_type, inference_failure_on_untyped_parameter

part of 'tachi_backup.dart';

class TachiBackupMapper extends ClassMapperBase<TachiBackup> {
  TachiBackupMapper._();

  static TachiBackupMapper? _instance;
  static TachiBackupMapper ensureInitialized() {
    if (_instance == null) {
      MapperContainer.globals.use(_instance = TachiBackupMapper._());
      MapperContainer.globals.useAll([SecondsEpochDateTimeMapper()]);
      TachiSourceMapper.ensureInitialized();
      TachiBackupCategoryMapper.ensureInitialized();
      TachiBackupMangaMapper.ensureInitialized();
      TachiBackupExtensionRepoMapper.ensureInitialized();
      TachiForkMapper.ensureInitialized();
    }
    return _instance!;
  }

  @override
  final String id = 'TachiBackup';

  static List<TachiSource> _$backupBrokenSources(TachiBackup v) =>
      v.backupBrokenSources;
  static const Field<TachiBackup, List<TachiSource>> _f$backupBrokenSources =
      Field('backupBrokenSources', _$backupBrokenSources);
  static List<TachiSource> _$backupSources(TachiBackup v) => v.backupSources;
  static const Field<TachiBackup, List<TachiSource>> _f$backupSources =
      Field('backupSources', _$backupSources);
  static List<TachiBackupCategory> _$backupCategories(TachiBackup v) =>
      v.backupCategories;
  static const Field<TachiBackup, List<TachiBackupCategory>>
      _f$backupCategories = Field('backupCategories', _$backupCategories);
  static List<TachiBackupManga> _$backupManga(TachiBackup v) => v.backupManga;
  static const Field<TachiBackup, List<TachiBackupManga>> _f$backupManga =
      Field('backupManga', _$backupManga);
  static List<TachiBackupExtensionRepo> _$backupExtensionRepo(TachiBackup v) =>
      v.backupExtensionRepo;
  static const Field<TachiBackup, List<TachiBackupExtensionRepo>>
      _f$backupExtensionRepo =
      Field('backupExtensionRepo', _$backupExtensionRepo);
  static TachiFork _$fork(TachiBackup v) => v.fork;
  static const Field<TachiBackup, TachiFork> _f$fork =
      Field('fork', _$fork, opt: true, def: TachiFork.mihon);

  @override
  final MappableFields<TachiBackup> fields = const {
    #backupBrokenSources: _f$backupBrokenSources,
    #backupSources: _f$backupSources,
    #backupCategories: _f$backupCategories,
    #backupManga: _f$backupManga,
    #backupExtensionRepo: _f$backupExtensionRepo,
    #fork: _f$fork,
  };

  static TachiBackup _instantiate(DecodingData data) {
    return TachiBackup(
        backupBrokenSources: data.dec(_f$backupBrokenSources),
        backupSources: data.dec(_f$backupSources),
        backupCategories: data.dec(_f$backupCategories),
        backupManga: data.dec(_f$backupManga),
        backupExtensionRepo: data.dec(_f$backupExtensionRepo),
        fork: data.dec(_f$fork));
  }

  @override
  final Function instantiate = _instantiate;

  static TachiBackup fromMap(Map<String, dynamic> map) {
    return ensureInitialized().decodeMap<TachiBackup>(map);
  }

  static TachiBackup fromJson(String json) {
    return ensureInitialized().decodeJson<TachiBackup>(json);
  }
}

mixin TachiBackupMappable {
  String toJson() {
    return TachiBackupMapper.ensureInitialized()
        .encodeJson<TachiBackup>(this as TachiBackup);
  }

  Map<String, dynamic> toMap() {
    return TachiBackupMapper.ensureInitialized()
        .encodeMap<TachiBackup>(this as TachiBackup);
  }

  TachiBackupCopyWith<TachiBackup, TachiBackup, TachiBackup> get copyWith =>
      _TachiBackupCopyWithImpl(this as TachiBackup, $identity, $identity);
  @override
  String toString() {
    return TachiBackupMapper.ensureInitialized()
        .stringifyValue(this as TachiBackup);
  }

  @override
  bool operator ==(Object other) {
    return TachiBackupMapper.ensureInitialized()
        .equalsValue(this as TachiBackup, other);
  }

  @override
  int get hashCode {
    return TachiBackupMapper.ensureInitialized().hashValue(this as TachiBackup);
  }
}

extension TachiBackupValueCopy<$R, $Out>
    on ObjectCopyWith<$R, TachiBackup, $Out> {
  TachiBackupCopyWith<$R, TachiBackup, $Out> get $asTachiBackup =>
      $base.as((v, t, t2) => _TachiBackupCopyWithImpl(v, t, t2));
}

abstract class TachiBackupCopyWith<$R, $In extends TachiBackup, $Out>
    implements ClassCopyWith<$R, $In, $Out> {
  ListCopyWith<$R, TachiSource,
          TachiSourceCopyWith<$R, TachiSource, TachiSource>>
      get backupBrokenSources;
  ListCopyWith<$R, TachiSource,
      TachiSourceCopyWith<$R, TachiSource, TachiSource>> get backupSources;
  ListCopyWith<
      $R,
      TachiBackupCategory,
      TachiBackupCategoryCopyWith<$R, TachiBackupCategory,
          TachiBackupCategory>> get backupCategories;
  ListCopyWith<$R, TachiBackupManga,
          TachiBackupMangaCopyWith<$R, TachiBackupManga, TachiBackupManga>>
      get backupManga;
  ListCopyWith<
      $R,
      TachiBackupExtensionRepo,
      TachiBackupExtensionRepoCopyWith<$R, TachiBackupExtensionRepo,
          TachiBackupExtensionRepo>> get backupExtensionRepo;
  $R call(
      {List<TachiSource>? backupBrokenSources,
      List<TachiSource>? backupSources,
      List<TachiBackupCategory>? backupCategories,
      List<TachiBackupManga>? backupManga,
      List<TachiBackupExtensionRepo>? backupExtensionRepo,
      TachiFork? fork});
  TachiBackupCopyWith<$R2, $In, $Out2> $chain<$R2, $Out2>(Then<$Out2, $R2> t);
}

class _TachiBackupCopyWithImpl<$R, $Out>
    extends ClassCopyWithBase<$R, TachiBackup, $Out>
    implements TachiBackupCopyWith<$R, TachiBackup, $Out> {
  _TachiBackupCopyWithImpl(super.value, super.then, super.then2);

  @override
  late final ClassMapperBase<TachiBackup> $mapper =
      TachiBackupMapper.ensureInitialized();
  @override
  ListCopyWith<$R, TachiSource,
          TachiSourceCopyWith<$R, TachiSource, TachiSource>>
      get backupBrokenSources => ListCopyWith($value.backupBrokenSources,
          (v, t) => v.copyWith.$chain(t), (v) => call(backupBrokenSources: v));
  @override
  ListCopyWith<$R, TachiSource,
          TachiSourceCopyWith<$R, TachiSource, TachiSource>>
      get backupSources => ListCopyWith($value.backupSources,
          (v, t) => v.copyWith.$chain(t), (v) => call(backupSources: v));
  @override
  ListCopyWith<
      $R,
      TachiBackupCategory,
      TachiBackupCategoryCopyWith<$R, TachiBackupCategory,
          TachiBackupCategory>> get backupCategories => ListCopyWith(
      $value.backupCategories,
      (v, t) => v.copyWith.$chain(t),
      (v) => call(backupCategories: v));
  @override
  ListCopyWith<$R, TachiBackupManga,
          TachiBackupMangaCopyWith<$R, TachiBackupManga, TachiBackupManga>>
      get backupManga => ListCopyWith($value.backupManga,
          (v, t) => v.copyWith.$chain(t), (v) => call(backupManga: v));
  @override
  ListCopyWith<
      $R,
      TachiBackupExtensionRepo,
      TachiBackupExtensionRepoCopyWith<$R, TachiBackupExtensionRepo,
          TachiBackupExtensionRepo>> get backupExtensionRepo => ListCopyWith(
      $value.backupExtensionRepo,
      (v, t) => v.copyWith.$chain(t),
      (v) => call(backupExtensionRepo: v));
  @override
  $R call(
          {List<TachiSource>? backupBrokenSources,
          List<TachiSource>? backupSources,
          List<TachiBackupCategory>? backupCategories,
          List<TachiBackupManga>? backupManga,
          List<TachiBackupExtensionRepo>? backupExtensionRepo,
          TachiFork? fork}) =>
      $apply(FieldCopyWithData({
        if (backupBrokenSources != null)
          #backupBrokenSources: backupBrokenSources,
        if (backupSources != null) #backupSources: backupSources,
        if (backupCategories != null) #backupCategories: backupCategories,
        if (backupManga != null) #backupManga: backupManga,
        if (backupExtensionRepo != null)
          #backupExtensionRepo: backupExtensionRepo,
        if (fork != null) #fork: fork
      }));
  @override
  TachiBackup $make(CopyWithData data) => TachiBackup(
      backupBrokenSources:
          data.get(#backupBrokenSources, or: $value.backupBrokenSources),
      backupSources: data.get(#backupSources, or: $value.backupSources),
      backupCategories:
          data.get(#backupCategories, or: $value.backupCategories),
      backupManga: data.get(#backupManga, or: $value.backupManga),
      backupExtensionRepo:
          data.get(#backupExtensionRepo, or: $value.backupExtensionRepo),
      fork: data.get(#fork, or: $value.fork));

  @override
  TachiBackupCopyWith<$R2, TachiBackup, $Out2> $chain<$R2, $Out2>(
          Then<$Out2, $R2> t) =>
      _TachiBackupCopyWithImpl($value, $cast, t);
}
