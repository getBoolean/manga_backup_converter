//
//  Generated code. Do not modify.
//  source: proto/schema_sy.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:core' as $core;

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'schema_sy.pbenum.dart';

export 'schema_sy.pbenum.dart';

class PreferenceValue extends $pb.GeneratedMessage {
  factory PreferenceValue({
    $core.String? type,
    $core.List<$core.int>? truevalue,
  }) {
    final $result = create();
    if (type != null) {
      $result.type = type;
    }
    if (truevalue != null) {
      $result.truevalue = truevalue;
    }
    return $result;
  }
  PreferenceValue._() : super();
  factory PreferenceValue.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory PreferenceValue.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PreferenceValue',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'type')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'truevalue', $pb.PbFieldType.QY);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  PreferenceValue clone() => PreferenceValue()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  PreferenceValue copyWith(void Function(PreferenceValue) updates) =>
      super.copyWith((message) => updates(message as PreferenceValue))
          as PreferenceValue;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static PreferenceValue create() => PreferenceValue._();
  PreferenceValue createEmptyInstance() => create();
  static $pb.PbList<PreferenceValue> createRepeated() =>
      $pb.PbList<PreferenceValue>();
  @$core.pragma('dart2js:noInline')
  static PreferenceValue getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<PreferenceValue>(create);
  static PreferenceValue? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get type => $_getSZ(0);
  @$pb.TagNumber(1)
  set type($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasType() => $_has(0);
  @$pb.TagNumber(1)
  void clearType() => clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get truevalue => $_getN(1);
  @$pb.TagNumber(2)
  set truevalue($core.List<$core.int> v) {
    $_setBytes(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasTruevalue() => $_has(1);
  @$pb.TagNumber(2)
  void clearTruevalue() => clearField(2);
}

/// Backup.kt
class Backup extends $pb.GeneratedMessage {
  factory Backup({
    $core.Iterable<BackupManga>? backupManga,
    $core.Iterable<BackupCategory>? backupCategories,
    $core.Iterable<BrokenBackupSource>? backupBrokenSources,
    $core.Iterable<BackupSource>? backupSources,
    $core.Iterable<BackupPreference>? backupPreferences,
    $core.Iterable<BackupSourcePreferences>? backupSourcePreferences,
    $core.Iterable<BackupExtensionRepos>? backupExtensionRepo,
    $core.Iterable<BackupSavedSearch>? backupSavedSearches,
  }) {
    final $result = create();
    if (backupManga != null) {
      $result.backupManga.addAll(backupManga);
    }
    if (backupCategories != null) {
      $result.backupCategories.addAll(backupCategories);
    }
    if (backupBrokenSources != null) {
      $result.backupBrokenSources.addAll(backupBrokenSources);
    }
    if (backupSources != null) {
      $result.backupSources.addAll(backupSources);
    }
    if (backupPreferences != null) {
      $result.backupPreferences.addAll(backupPreferences);
    }
    if (backupSourcePreferences != null) {
      $result.backupSourcePreferences.addAll(backupSourcePreferences);
    }
    if (backupExtensionRepo != null) {
      $result.backupExtensionRepo.addAll(backupExtensionRepo);
    }
    if (backupSavedSearches != null) {
      $result.backupSavedSearches.addAll(backupSavedSearches);
    }
    return $result;
  }
  Backup._() : super();
  factory Backup.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory Backup.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Backup',
      createEmptyInstance: create)
    ..pc<BackupManga>(
        1, _omitFieldNames ? '' : 'backupManga', $pb.PbFieldType.PM,
        protoName: 'backupManga', subBuilder: BackupManga.create)
    ..pc<BackupCategory>(
        2, _omitFieldNames ? '' : 'backupCategories', $pb.PbFieldType.PM,
        protoName: 'backupCategories', subBuilder: BackupCategory.create)
    ..pc<BrokenBackupSource>(
        100, _omitFieldNames ? '' : 'backupBrokenSources', $pb.PbFieldType.PM,
        protoName: 'backupBrokenSources', subBuilder: BrokenBackupSource.create)
    ..pc<BackupSource>(
        101, _omitFieldNames ? '' : 'backupSources', $pb.PbFieldType.PM,
        protoName: 'backupSources', subBuilder: BackupSource.create)
    ..pc<BackupPreference>(
        104, _omitFieldNames ? '' : 'backupPreferences', $pb.PbFieldType.PM,
        protoName: 'backupPreferences', subBuilder: BackupPreference.create)
    ..pc<BackupSourcePreferences>(105,
        _omitFieldNames ? '' : 'backupSourcePreferences', $pb.PbFieldType.PM,
        protoName: 'backupSourcePreferences',
        subBuilder: BackupSourcePreferences.create)
    ..pc<BackupExtensionRepos>(
        106, _omitFieldNames ? '' : 'backupExtensionRepo', $pb.PbFieldType.PM,
        protoName: 'backupExtensionRepo',
        subBuilder: BackupExtensionRepos.create)
    ..pc<BackupSavedSearch>(
        600, _omitFieldNames ? '' : 'backupSavedSearches', $pb.PbFieldType.PM,
        protoName: 'backupSavedSearches', subBuilder: BackupSavedSearch.create);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  Backup clone() => Backup()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  Backup copyWith(void Function(Backup) updates) =>
      super.copyWith((message) => updates(message as Backup)) as Backup;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static Backup create() => Backup._();
  Backup createEmptyInstance() => create();
  static $pb.PbList<Backup> createRepeated() => $pb.PbList<Backup>();
  @$core.pragma('dart2js:noInline')
  static Backup getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<Backup>(create);
  static Backup? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<BackupManga> get backupManga => $_getList(0);

  @$pb.TagNumber(2)
  $core.List<BackupCategory> get backupCategories => $_getList(1);

  @$pb.TagNumber(100)
  $core.List<BrokenBackupSource> get backupBrokenSources => $_getList(2);

  @$pb.TagNumber(101)
  $core.List<BackupSource> get backupSources => $_getList(3);

  @$pb.TagNumber(104)
  $core.List<BackupPreference> get backupPreferences => $_getList(4);

  @$pb.TagNumber(105)
  $core.List<BackupSourcePreferences> get backupSourcePreferences =>
      $_getList(5);

  @$pb.TagNumber(106)
  $core.List<BackupExtensionRepos> get backupExtensionRepo => $_getList(6);

  @$pb.TagNumber(600)
  $core.List<BackupSavedSearch> get backupSavedSearches => $_getList(7);
}

/// BackupCategory.kt
class BackupCategory extends $pb.GeneratedMessage {
  factory BackupCategory({
    $core.String? name,
    $fixnum.Int64? order,
    $fixnum.Int64? flags,
  }) {
    final $result = create();
    if (name != null) {
      $result.name = name;
    }
    if (order != null) {
      $result.order = order;
    }
    if (flags != null) {
      $result.flags = flags;
    }
    return $result;
  }
  BackupCategory._() : super();
  factory BackupCategory.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupCategory.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupCategory',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'name')
    ..aInt64(2, _omitFieldNames ? '' : 'order')
    ..aInt64(100, _omitFieldNames ? '' : 'flags');

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupCategory clone() => BackupCategory()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupCategory copyWith(void Function(BackupCategory) updates) =>
      super.copyWith((message) => updates(message as BackupCategory))
          as BackupCategory;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupCategory create() => BackupCategory._();
  BackupCategory createEmptyInstance() => create();
  static $pb.PbList<BackupCategory> createRepeated() =>
      $pb.PbList<BackupCategory>();
  @$core.pragma('dart2js:noInline')
  static BackupCategory getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupCategory>(create);
  static BackupCategory? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get order => $_getI64(1);
  @$pb.TagNumber(2)
  set order($fixnum.Int64 v) {
    $_setInt64(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasOrder() => $_has(1);
  @$pb.TagNumber(2)
  void clearOrder() => clearField(2);

  @$pb.TagNumber(100)
  $fixnum.Int64 get flags => $_getI64(2);
  @$pb.TagNumber(100)
  set flags($fixnum.Int64 v) {
    $_setInt64(2, v);
  }

  @$pb.TagNumber(100)
  $core.bool hasFlags() => $_has(2);
  @$pb.TagNumber(100)
  void clearFlags() => clearField(100);
}

/// BackupChapter.kt
class BackupChapter extends $pb.GeneratedMessage {
  factory BackupChapter({
    $core.String? url,
    $core.String? name,
    $core.String? scanlator,
    $core.bool? read,
    $core.bool? bookmark,
    $fixnum.Int64? lastPageRead,
    $fixnum.Int64? dateFetch,
    $fixnum.Int64? dateUpload,
    $core.double? chapterNumber,
    $fixnum.Int64? sourceOrder,
    $fixnum.Int64? lastModifiedAt,
    $fixnum.Int64? version,
  }) {
    final $result = create();
    if (url != null) {
      $result.url = url;
    }
    if (name != null) {
      $result.name = name;
    }
    if (scanlator != null) {
      $result.scanlator = scanlator;
    }
    if (read != null) {
      $result.read = read;
    }
    if (bookmark != null) {
      $result.bookmark = bookmark;
    }
    if (lastPageRead != null) {
      $result.lastPageRead = lastPageRead;
    }
    if (dateFetch != null) {
      $result.dateFetch = dateFetch;
    }
    if (dateUpload != null) {
      $result.dateUpload = dateUpload;
    }
    if (chapterNumber != null) {
      $result.chapterNumber = chapterNumber;
    }
    if (sourceOrder != null) {
      $result.sourceOrder = sourceOrder;
    }
    if (lastModifiedAt != null) {
      $result.lastModifiedAt = lastModifiedAt;
    }
    if (version != null) {
      $result.version = version;
    }
    return $result;
  }
  BackupChapter._() : super();
  factory BackupChapter.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupChapter.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupChapter',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'url')
    ..aQS(2, _omitFieldNames ? '' : 'name')
    ..aOS(3, _omitFieldNames ? '' : 'scanlator')
    ..aOB(4, _omitFieldNames ? '' : 'read')
    ..aOB(5, _omitFieldNames ? '' : 'bookmark')
    ..aInt64(6, _omitFieldNames ? '' : 'lastPageRead',
        protoName: 'lastPageRead')
    ..aInt64(7, _omitFieldNames ? '' : 'dateFetch', protoName: 'dateFetch')
    ..aInt64(8, _omitFieldNames ? '' : 'dateUpload', protoName: 'dateUpload')
    ..a<$core.double>(
        9, _omitFieldNames ? '' : 'chapterNumber', $pb.PbFieldType.OF,
        protoName: 'chapterNumber')
    ..aInt64(10, _omitFieldNames ? '' : 'sourceOrder', protoName: 'sourceOrder')
    ..aInt64(11, _omitFieldNames ? '' : 'lastModifiedAt',
        protoName: 'lastModifiedAt')
    ..aInt64(12, _omitFieldNames ? '' : 'version');

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupChapter clone() => BackupChapter()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupChapter copyWith(void Function(BackupChapter) updates) =>
      super.copyWith((message) => updates(message as BackupChapter))
          as BackupChapter;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupChapter create() => BackupChapter._();
  BackupChapter createEmptyInstance() => create();
  static $pb.PbList<BackupChapter> createRepeated() =>
      $pb.PbList<BackupChapter>();
  @$core.pragma('dart2js:noInline')
  static BackupChapter getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupChapter>(create);
  static BackupChapter? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get url => $_getSZ(0);
  @$pb.TagNumber(1)
  set url($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasUrl() => $_has(0);
  @$pb.TagNumber(1)
  void clearUrl() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => clearField(2);

  @$pb.TagNumber(3)
  $core.String get scanlator => $_getSZ(2);
  @$pb.TagNumber(3)
  set scanlator($core.String v) {
    $_setString(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasScanlator() => $_has(2);
  @$pb.TagNumber(3)
  void clearScanlator() => clearField(3);

  @$pb.TagNumber(4)
  $core.bool get read => $_getBF(3);
  @$pb.TagNumber(4)
  set read($core.bool v) {
    $_setBool(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasRead() => $_has(3);
  @$pb.TagNumber(4)
  void clearRead() => clearField(4);

  @$pb.TagNumber(5)
  $core.bool get bookmark => $_getBF(4);
  @$pb.TagNumber(5)
  set bookmark($core.bool v) {
    $_setBool(4, v);
  }

  @$pb.TagNumber(5)
  $core.bool hasBookmark() => $_has(4);
  @$pb.TagNumber(5)
  void clearBookmark() => clearField(5);

  @$pb.TagNumber(6)
  $fixnum.Int64 get lastPageRead => $_getI64(5);
  @$pb.TagNumber(6)
  set lastPageRead($fixnum.Int64 v) {
    $_setInt64(5, v);
  }

  @$pb.TagNumber(6)
  $core.bool hasLastPageRead() => $_has(5);
  @$pb.TagNumber(6)
  void clearLastPageRead() => clearField(6);

  @$pb.TagNumber(7)
  $fixnum.Int64 get dateFetch => $_getI64(6);
  @$pb.TagNumber(7)
  set dateFetch($fixnum.Int64 v) {
    $_setInt64(6, v);
  }

  @$pb.TagNumber(7)
  $core.bool hasDateFetch() => $_has(6);
  @$pb.TagNumber(7)
  void clearDateFetch() => clearField(7);

  @$pb.TagNumber(8)
  $fixnum.Int64 get dateUpload => $_getI64(7);
  @$pb.TagNumber(8)
  set dateUpload($fixnum.Int64 v) {
    $_setInt64(7, v);
  }

  @$pb.TagNumber(8)
  $core.bool hasDateUpload() => $_has(7);
  @$pb.TagNumber(8)
  void clearDateUpload() => clearField(8);

  @$pb.TagNumber(9)
  $core.double get chapterNumber => $_getN(8);
  @$pb.TagNumber(9)
  set chapterNumber($core.double v) {
    $_setFloat(8, v);
  }

  @$pb.TagNumber(9)
  $core.bool hasChapterNumber() => $_has(8);
  @$pb.TagNumber(9)
  void clearChapterNumber() => clearField(9);

  @$pb.TagNumber(10)
  $fixnum.Int64 get sourceOrder => $_getI64(9);
  @$pb.TagNumber(10)
  set sourceOrder($fixnum.Int64 v) {
    $_setInt64(9, v);
  }

  @$pb.TagNumber(10)
  $core.bool hasSourceOrder() => $_has(9);
  @$pb.TagNumber(10)
  void clearSourceOrder() => clearField(10);

  @$pb.TagNumber(11)
  $fixnum.Int64 get lastModifiedAt => $_getI64(10);
  @$pb.TagNumber(11)
  set lastModifiedAt($fixnum.Int64 v) {
    $_setInt64(10, v);
  }

  @$pb.TagNumber(11)
  $core.bool hasLastModifiedAt() => $_has(10);
  @$pb.TagNumber(11)
  void clearLastModifiedAt() => clearField(11);

  @$pb.TagNumber(12)
  $fixnum.Int64 get version => $_getI64(11);
  @$pb.TagNumber(12)
  set version($fixnum.Int64 v) {
    $_setInt64(11, v);
  }

  @$pb.TagNumber(12)
  $core.bool hasVersion() => $_has(11);
  @$pb.TagNumber(12)
  void clearVersion() => clearField(12);
}

/// BackupExtensionRepos.kt
class BackupExtensionRepos extends $pb.GeneratedMessage {
  factory BackupExtensionRepos({
    $core.String? baseUrl,
    $core.String? name,
    $core.String? shortName,
    $core.String? website,
    $core.String? signingKeyFingerprint,
  }) {
    final $result = create();
    if (baseUrl != null) {
      $result.baseUrl = baseUrl;
    }
    if (name != null) {
      $result.name = name;
    }
    if (shortName != null) {
      $result.shortName = shortName;
    }
    if (website != null) {
      $result.website = website;
    }
    if (signingKeyFingerprint != null) {
      $result.signingKeyFingerprint = signingKeyFingerprint;
    }
    return $result;
  }
  BackupExtensionRepos._() : super();
  factory BackupExtensionRepos.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupExtensionRepos.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupExtensionRepos',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'baseUrl', protoName: 'baseUrl')
    ..aQS(2, _omitFieldNames ? '' : 'name')
    ..aOS(3, _omitFieldNames ? '' : 'shortName', protoName: 'shortName')
    ..aQS(4, _omitFieldNames ? '' : 'website')
    ..aQS(5, _omitFieldNames ? '' : 'signingKeyFingerprint',
        protoName: 'signingKeyFingerprint');

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupExtensionRepos clone() =>
      BackupExtensionRepos()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupExtensionRepos copyWith(void Function(BackupExtensionRepos) updates) =>
      super.copyWith((message) => updates(message as BackupExtensionRepos))
          as BackupExtensionRepos;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupExtensionRepos create() => BackupExtensionRepos._();
  BackupExtensionRepos createEmptyInstance() => create();
  static $pb.PbList<BackupExtensionRepos> createRepeated() =>
      $pb.PbList<BackupExtensionRepos>();
  @$core.pragma('dart2js:noInline')
  static BackupExtensionRepos getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupExtensionRepos>(create);
  static BackupExtensionRepos? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get baseUrl => $_getSZ(0);
  @$pb.TagNumber(1)
  set baseUrl($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasBaseUrl() => $_has(0);
  @$pb.TagNumber(1)
  void clearBaseUrl() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => clearField(2);

  @$pb.TagNumber(3)
  $core.String get shortName => $_getSZ(2);
  @$pb.TagNumber(3)
  set shortName($core.String v) {
    $_setString(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasShortName() => $_has(2);
  @$pb.TagNumber(3)
  void clearShortName() => clearField(3);

  @$pb.TagNumber(4)
  $core.String get website => $_getSZ(3);
  @$pb.TagNumber(4)
  set website($core.String v) {
    $_setString(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasWebsite() => $_has(3);
  @$pb.TagNumber(4)
  void clearWebsite() => clearField(4);

  @$pb.TagNumber(5)
  $core.String get signingKeyFingerprint => $_getSZ(4);
  @$pb.TagNumber(5)
  set signingKeyFingerprint($core.String v) {
    $_setString(4, v);
  }

  @$pb.TagNumber(5)
  $core.bool hasSigningKeyFingerprint() => $_has(4);
  @$pb.TagNumber(5)
  void clearSigningKeyFingerprint() => clearField(5);
}

/// BackupFlatMetadata.kt
class BackupFlatMetadata extends $pb.GeneratedMessage {
  factory BackupFlatMetadata({
    BackupSearchMetadata? searchMetadata,
    $core.Iterable<BackupSearchTag>? searchTags,
    $core.Iterable<BackupSearchTitle>? searchTitles,
  }) {
    final $result = create();
    if (searchMetadata != null) {
      $result.searchMetadata = searchMetadata;
    }
    if (searchTags != null) {
      $result.searchTags.addAll(searchTags);
    }
    if (searchTitles != null) {
      $result.searchTitles.addAll(searchTitles);
    }
    return $result;
  }
  BackupFlatMetadata._() : super();
  factory BackupFlatMetadata.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupFlatMetadata.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupFlatMetadata',
      createEmptyInstance: create)
    ..aQM<BackupSearchMetadata>(1, _omitFieldNames ? '' : 'searchMetadata',
        protoName: 'searchMetadata', subBuilder: BackupSearchMetadata.create)
    ..pc<BackupSearchTag>(
        2, _omitFieldNames ? '' : 'searchTags', $pb.PbFieldType.PM,
        protoName: 'searchTags', subBuilder: BackupSearchTag.create)
    ..pc<BackupSearchTitle>(
        3, _omitFieldNames ? '' : 'searchTitles', $pb.PbFieldType.PM,
        protoName: 'searchTitles', subBuilder: BackupSearchTitle.create);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupFlatMetadata clone() => BackupFlatMetadata()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupFlatMetadata copyWith(void Function(BackupFlatMetadata) updates) =>
      super.copyWith((message) => updates(message as BackupFlatMetadata))
          as BackupFlatMetadata;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupFlatMetadata create() => BackupFlatMetadata._();
  BackupFlatMetadata createEmptyInstance() => create();
  static $pb.PbList<BackupFlatMetadata> createRepeated() =>
      $pb.PbList<BackupFlatMetadata>();
  @$core.pragma('dart2js:noInline')
  static BackupFlatMetadata getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupFlatMetadata>(create);
  static BackupFlatMetadata? _defaultInstance;

  @$pb.TagNumber(1)
  BackupSearchMetadata get searchMetadata => $_getN(0);
  @$pb.TagNumber(1)
  set searchMetadata(BackupSearchMetadata v) {
    setField(1, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasSearchMetadata() => $_has(0);
  @$pb.TagNumber(1)
  void clearSearchMetadata() => clearField(1);
  @$pb.TagNumber(1)
  BackupSearchMetadata ensureSearchMetadata() => $_ensure(0);

  @$pb.TagNumber(2)
  $core.List<BackupSearchTag> get searchTags => $_getList(1);

  @$pb.TagNumber(3)
  $core.List<BackupSearchTitle> get searchTitles => $_getList(2);
}

/// BackupHistory.kt
class BackupHistory extends $pb.GeneratedMessage {
  factory BackupHistory({
    $core.String? url,
    $fixnum.Int64? lastRead,
    $fixnum.Int64? readDuration,
  }) {
    final $result = create();
    if (url != null) {
      $result.url = url;
    }
    if (lastRead != null) {
      $result.lastRead = lastRead;
    }
    if (readDuration != null) {
      $result.readDuration = readDuration;
    }
    return $result;
  }
  BackupHistory._() : super();
  factory BackupHistory.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupHistory.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupHistory',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'url')
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'lastRead', $pb.PbFieldType.Q6,
        protoName: 'lastRead', defaultOrMaker: $fixnum.Int64.ZERO)
    ..aInt64(3, _omitFieldNames ? '' : 'readDuration',
        protoName: 'readDuration');

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupHistory clone() => BackupHistory()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupHistory copyWith(void Function(BackupHistory) updates) =>
      super.copyWith((message) => updates(message as BackupHistory))
          as BackupHistory;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupHistory create() => BackupHistory._();
  BackupHistory createEmptyInstance() => create();
  static $pb.PbList<BackupHistory> createRepeated() =>
      $pb.PbList<BackupHistory>();
  @$core.pragma('dart2js:noInline')
  static BackupHistory getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupHistory>(create);
  static BackupHistory? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get url => $_getSZ(0);
  @$pb.TagNumber(1)
  set url($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasUrl() => $_has(0);
  @$pb.TagNumber(1)
  void clearUrl() => clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get lastRead => $_getI64(1);
  @$pb.TagNumber(2)
  set lastRead($fixnum.Int64 v) {
    $_setInt64(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasLastRead() => $_has(1);
  @$pb.TagNumber(2)
  void clearLastRead() => clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get readDuration => $_getI64(2);
  @$pb.TagNumber(3)
  set readDuration($fixnum.Int64 v) {
    $_setInt64(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasReadDuration() => $_has(2);
  @$pb.TagNumber(3)
  void clearReadDuration() => clearField(3);
}

class BrokenBackupHistory extends $pb.GeneratedMessage {
  factory BrokenBackupHistory({
    $core.String? url,
    $fixnum.Int64? lastRead,
    $fixnum.Int64? readDuration,
  }) {
    final $result = create();
    if (url != null) {
      $result.url = url;
    }
    if (lastRead != null) {
      $result.lastRead = lastRead;
    }
    if (readDuration != null) {
      $result.readDuration = readDuration;
    }
    return $result;
  }
  BrokenBackupHistory._() : super();
  factory BrokenBackupHistory.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BrokenBackupHistory.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BrokenBackupHistory',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'url')
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'lastRead', $pb.PbFieldType.Q6,
        protoName: 'lastRead', defaultOrMaker: $fixnum.Int64.ZERO)
    ..aInt64(3, _omitFieldNames ? '' : 'readDuration',
        protoName: 'readDuration');

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BrokenBackupHistory clone() => BrokenBackupHistory()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BrokenBackupHistory copyWith(void Function(BrokenBackupHistory) updates) =>
      super.copyWith((message) => updates(message as BrokenBackupHistory))
          as BrokenBackupHistory;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BrokenBackupHistory create() => BrokenBackupHistory._();
  BrokenBackupHistory createEmptyInstance() => create();
  static $pb.PbList<BrokenBackupHistory> createRepeated() =>
      $pb.PbList<BrokenBackupHistory>();
  @$core.pragma('dart2js:noInline')
  static BrokenBackupHistory getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BrokenBackupHistory>(create);
  static BrokenBackupHistory? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get url => $_getSZ(0);
  @$pb.TagNumber(1)
  set url($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasUrl() => $_has(0);
  @$pb.TagNumber(1)
  void clearUrl() => clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get lastRead => $_getI64(1);
  @$pb.TagNumber(2)
  set lastRead($fixnum.Int64 v) {
    $_setInt64(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasLastRead() => $_has(1);
  @$pb.TagNumber(2)
  void clearLastRead() => clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get readDuration => $_getI64(2);
  @$pb.TagNumber(3)
  set readDuration($fixnum.Int64 v) {
    $_setInt64(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasReadDuration() => $_has(2);
  @$pb.TagNumber(3)
  void clearReadDuration() => clearField(3);
}

/// BackupManga.kt
class BackupManga extends $pb.GeneratedMessage {
  factory BackupManga({
    $fixnum.Int64? source,
    $core.String? url,
    $core.String? title,
    $core.String? artist,
    $core.String? author,
    $core.String? description,
    $core.Iterable<$core.String>? genre,
    $core.int? status,
    $core.String? thumbnailUrl,
    $fixnum.Int64? dateAdded,
    $core.int? viewer,
    $core.Iterable<BackupChapter>? chapters,
    $core.Iterable<$fixnum.Int64>? categories,
    $core.Iterable<BackupTracking>? tracking,
    $core.bool? favorite,
    $core.int? chapterFlags,
    $core.Iterable<BrokenBackupHistory>? brokenHistory,
    $core.int? viewerFlags,
    $core.Iterable<BackupHistory>? history,
    UpdateStrategy? updateStrategy,
    $fixnum.Int64? lastModifiedAt,
    $fixnum.Int64? favoriteModifiedAt,
    $core.Iterable<$core.String>? excludedScanlators,
    $fixnum.Int64? version,
    $core.Iterable<BackupMergedMangaReference>? mergedMangaReferences,
    BackupFlatMetadata? flatMetadata,
    $core.int? customStatus,
    $core.String? customThumbnailUrl,
    $core.String? customTitle,
    $core.String? customArtist,
    $core.String? customAuthor,
    $core.String? customDescription,
    $core.Iterable<$core.String>? customGenre,
  }) {
    final $result = create();
    if (source != null) {
      $result.source = source;
    }
    if (url != null) {
      $result.url = url;
    }
    if (title != null) {
      $result.title = title;
    }
    if (artist != null) {
      $result.artist = artist;
    }
    if (author != null) {
      $result.author = author;
    }
    if (description != null) {
      $result.description = description;
    }
    if (genre != null) {
      $result.genre.addAll(genre);
    }
    if (status != null) {
      $result.status = status;
    }
    if (thumbnailUrl != null) {
      $result.thumbnailUrl = thumbnailUrl;
    }
    if (dateAdded != null) {
      $result.dateAdded = dateAdded;
    }
    if (viewer != null) {
      $result.viewer = viewer;
    }
    if (chapters != null) {
      $result.chapters.addAll(chapters);
    }
    if (categories != null) {
      $result.categories.addAll(categories);
    }
    if (tracking != null) {
      $result.tracking.addAll(tracking);
    }
    if (favorite != null) {
      $result.favorite = favorite;
    }
    if (chapterFlags != null) {
      $result.chapterFlags = chapterFlags;
    }
    if (brokenHistory != null) {
      $result.brokenHistory.addAll(brokenHistory);
    }
    if (viewerFlags != null) {
      $result.viewerFlags = viewerFlags;
    }
    if (history != null) {
      $result.history.addAll(history);
    }
    if (updateStrategy != null) {
      $result.updateStrategy = updateStrategy;
    }
    if (lastModifiedAt != null) {
      $result.lastModifiedAt = lastModifiedAt;
    }
    if (favoriteModifiedAt != null) {
      $result.favoriteModifiedAt = favoriteModifiedAt;
    }
    if (excludedScanlators != null) {
      $result.excludedScanlators.addAll(excludedScanlators);
    }
    if (version != null) {
      $result.version = version;
    }
    if (mergedMangaReferences != null) {
      $result.mergedMangaReferences.addAll(mergedMangaReferences);
    }
    if (flatMetadata != null) {
      $result.flatMetadata = flatMetadata;
    }
    if (customStatus != null) {
      $result.customStatus = customStatus;
    }
    if (customThumbnailUrl != null) {
      $result.customThumbnailUrl = customThumbnailUrl;
    }
    if (customTitle != null) {
      $result.customTitle = customTitle;
    }
    if (customArtist != null) {
      $result.customArtist = customArtist;
    }
    if (customAuthor != null) {
      $result.customAuthor = customAuthor;
    }
    if (customDescription != null) {
      $result.customDescription = customDescription;
    }
    if (customGenre != null) {
      $result.customGenre.addAll(customGenre);
    }
    return $result;
  }
  BackupManga._() : super();
  factory BackupManga.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupManga.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupManga',
      createEmptyInstance: create)
    ..a<$fixnum.Int64>(1, _omitFieldNames ? '' : 'source', $pb.PbFieldType.Q6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aQS(2, _omitFieldNames ? '' : 'url')
    ..aOS(3, _omitFieldNames ? '' : 'title')
    ..aOS(4, _omitFieldNames ? '' : 'artist')
    ..aOS(5, _omitFieldNames ? '' : 'author')
    ..aOS(6, _omitFieldNames ? '' : 'description')
    ..pPS(7, _omitFieldNames ? '' : 'genre')
    ..a<$core.int>(8, _omitFieldNames ? '' : 'status', $pb.PbFieldType.O3)
    ..aOS(9, _omitFieldNames ? '' : 'thumbnailUrl', protoName: 'thumbnailUrl')
    ..aInt64(13, _omitFieldNames ? '' : 'dateAdded', protoName: 'dateAdded')
    ..a<$core.int>(14, _omitFieldNames ? '' : 'viewer', $pb.PbFieldType.O3)
    ..pc<BackupChapter>(
        16, _omitFieldNames ? '' : 'chapters', $pb.PbFieldType.PM,
        subBuilder: BackupChapter.create)
    ..p<$fixnum.Int64>(
        17, _omitFieldNames ? '' : 'categories', $pb.PbFieldType.P6)
    ..pc<BackupTracking>(
        18, _omitFieldNames ? '' : 'tracking', $pb.PbFieldType.PM,
        subBuilder: BackupTracking.create)
    ..aOB(100, _omitFieldNames ? '' : 'favorite')
    ..a<$core.int>(
        101, _omitFieldNames ? '' : 'chapterFlags', $pb.PbFieldType.O3,
        protoName: 'chapterFlags')
    ..pc<BrokenBackupHistory>(
        102, _omitFieldNames ? '' : 'brokenHistory', $pb.PbFieldType.PM,
        protoName: 'brokenHistory', subBuilder: BrokenBackupHistory.create)
    ..a<$core.int>(
        103, _omitFieldNames ? '' : 'viewerFlags', $pb.PbFieldType.O3)
    ..pc<BackupHistory>(
        104, _omitFieldNames ? '' : 'history', $pb.PbFieldType.PM,
        subBuilder: BackupHistory.create)
    ..e<UpdateStrategy>(
        105, _omitFieldNames ? '' : 'updateStrategy', $pb.PbFieldType.OE,
        protoName: 'updateStrategy',
        defaultOrMaker: UpdateStrategy.ALWAYS_UPDATE,
        valueOf: UpdateStrategy.valueOf,
        enumValues: UpdateStrategy.values)
    ..aInt64(106, _omitFieldNames ? '' : 'lastModifiedAt',
        protoName: 'lastModifiedAt')
    ..aInt64(107, _omitFieldNames ? '' : 'favoriteModifiedAt',
        protoName: 'favoriteModifiedAt')
    ..pPS(108, _omitFieldNames ? '' : 'excludedScanlators',
        protoName: 'excludedScanlators')
    ..aInt64(109, _omitFieldNames ? '' : 'version')
    ..pc<BackupMergedMangaReference>(
        600, _omitFieldNames ? '' : 'mergedMangaReferences', $pb.PbFieldType.PM,
        protoName: 'mergedMangaReferences',
        subBuilder: BackupMergedMangaReference.create)
    ..aOM<BackupFlatMetadata>(601, _omitFieldNames ? '' : 'flatMetadata',
        protoName: 'flatMetadata', subBuilder: BackupFlatMetadata.create)
    ..a<$core.int>(
        602, _omitFieldNames ? '' : 'customStatus', $pb.PbFieldType.O3,
        protoName: 'customStatus')
    ..aOS(603, _omitFieldNames ? '' : 'customThumbnailUrl',
        protoName: 'customThumbnailUrl')
    ..aOS(800, _omitFieldNames ? '' : 'customTitle', protoName: 'customTitle')
    ..aOS(801, _omitFieldNames ? '' : 'customArtist', protoName: 'customArtist')
    ..aOS(802, _omitFieldNames ? '' : 'customAuthor', protoName: 'customAuthor')
    ..aOS(804, _omitFieldNames ? '' : 'customDescription',
        protoName: 'customDescription')
    ..pPS(805, _omitFieldNames ? '' : 'customGenre', protoName: 'customGenre');

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupManga clone() => BackupManga()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupManga copyWith(void Function(BackupManga) updates) =>
      super.copyWith((message) => updates(message as BackupManga))
          as BackupManga;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupManga create() => BackupManga._();
  BackupManga createEmptyInstance() => create();
  static $pb.PbList<BackupManga> createRepeated() => $pb.PbList<BackupManga>();
  @$core.pragma('dart2js:noInline')
  static BackupManga getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupManga>(create);
  static BackupManga? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get source => $_getI64(0);
  @$pb.TagNumber(1)
  set source($fixnum.Int64 v) {
    $_setInt64(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasSource() => $_has(0);
  @$pb.TagNumber(1)
  void clearSource() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get url => $_getSZ(1);
  @$pb.TagNumber(2)
  set url($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasUrl() => $_has(1);
  @$pb.TagNumber(2)
  void clearUrl() => clearField(2);

  @$pb.TagNumber(3)
  $core.String get title => $_getSZ(2);
  @$pb.TagNumber(3)
  set title($core.String v) {
    $_setString(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasTitle() => $_has(2);
  @$pb.TagNumber(3)
  void clearTitle() => clearField(3);

  @$pb.TagNumber(4)
  $core.String get artist => $_getSZ(3);
  @$pb.TagNumber(4)
  set artist($core.String v) {
    $_setString(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasArtist() => $_has(3);
  @$pb.TagNumber(4)
  void clearArtist() => clearField(4);

  @$pb.TagNumber(5)
  $core.String get author => $_getSZ(4);
  @$pb.TagNumber(5)
  set author($core.String v) {
    $_setString(4, v);
  }

  @$pb.TagNumber(5)
  $core.bool hasAuthor() => $_has(4);
  @$pb.TagNumber(5)
  void clearAuthor() => clearField(5);

  @$pb.TagNumber(6)
  $core.String get description => $_getSZ(5);
  @$pb.TagNumber(6)
  set description($core.String v) {
    $_setString(5, v);
  }

  @$pb.TagNumber(6)
  $core.bool hasDescription() => $_has(5);
  @$pb.TagNumber(6)
  void clearDescription() => clearField(6);

  @$pb.TagNumber(7)
  $core.List<$core.String> get genre => $_getList(6);

  @$pb.TagNumber(8)
  $core.int get status => $_getIZ(7);
  @$pb.TagNumber(8)
  set status($core.int v) {
    $_setSignedInt32(7, v);
  }

  @$pb.TagNumber(8)
  $core.bool hasStatus() => $_has(7);
  @$pb.TagNumber(8)
  void clearStatus() => clearField(8);

  @$pb.TagNumber(9)
  $core.String get thumbnailUrl => $_getSZ(8);
  @$pb.TagNumber(9)
  set thumbnailUrl($core.String v) {
    $_setString(8, v);
  }

  @$pb.TagNumber(9)
  $core.bool hasThumbnailUrl() => $_has(8);
  @$pb.TagNumber(9)
  void clearThumbnailUrl() => clearField(9);

  @$pb.TagNumber(13)
  $fixnum.Int64 get dateAdded => $_getI64(9);
  @$pb.TagNumber(13)
  set dateAdded($fixnum.Int64 v) {
    $_setInt64(9, v);
  }

  @$pb.TagNumber(13)
  $core.bool hasDateAdded() => $_has(9);
  @$pb.TagNumber(13)
  void clearDateAdded() => clearField(13);

  @$pb.TagNumber(14)
  $core.int get viewer => $_getIZ(10);
  @$pb.TagNumber(14)
  set viewer($core.int v) {
    $_setSignedInt32(10, v);
  }

  @$pb.TagNumber(14)
  $core.bool hasViewer() => $_has(10);
  @$pb.TagNumber(14)
  void clearViewer() => clearField(14);

  @$pb.TagNumber(16)
  $core.List<BackupChapter> get chapters => $_getList(11);

  @$pb.TagNumber(17)
  $core.List<$fixnum.Int64> get categories => $_getList(12);

  @$pb.TagNumber(18)
  $core.List<BackupTracking> get tracking => $_getList(13);

  @$pb.TagNumber(100)
  $core.bool get favorite => $_getBF(14);
  @$pb.TagNumber(100)
  set favorite($core.bool v) {
    $_setBool(14, v);
  }

  @$pb.TagNumber(100)
  $core.bool hasFavorite() => $_has(14);
  @$pb.TagNumber(100)
  void clearFavorite() => clearField(100);

  @$pb.TagNumber(101)
  $core.int get chapterFlags => $_getIZ(15);
  @$pb.TagNumber(101)
  set chapterFlags($core.int v) {
    $_setSignedInt32(15, v);
  }

  @$pb.TagNumber(101)
  $core.bool hasChapterFlags() => $_has(15);
  @$pb.TagNumber(101)
  void clearChapterFlags() => clearField(101);

  @$pb.TagNumber(102)
  $core.List<BrokenBackupHistory> get brokenHistory => $_getList(16);

  @$pb.TagNumber(103)
  $core.int get viewerFlags => $_getIZ(17);
  @$pb.TagNumber(103)
  set viewerFlags($core.int v) {
    $_setSignedInt32(17, v);
  }

  @$pb.TagNumber(103)
  $core.bool hasViewerFlags() => $_has(17);
  @$pb.TagNumber(103)
  void clearViewerFlags() => clearField(103);

  @$pb.TagNumber(104)
  $core.List<BackupHistory> get history => $_getList(18);

  @$pb.TagNumber(105)
  UpdateStrategy get updateStrategy => $_getN(19);
  @$pb.TagNumber(105)
  set updateStrategy(UpdateStrategy v) {
    setField(105, v);
  }

  @$pb.TagNumber(105)
  $core.bool hasUpdateStrategy() => $_has(19);
  @$pb.TagNumber(105)
  void clearUpdateStrategy() => clearField(105);

  @$pb.TagNumber(106)
  $fixnum.Int64 get lastModifiedAt => $_getI64(20);
  @$pb.TagNumber(106)
  set lastModifiedAt($fixnum.Int64 v) {
    $_setInt64(20, v);
  }

  @$pb.TagNumber(106)
  $core.bool hasLastModifiedAt() => $_has(20);
  @$pb.TagNumber(106)
  void clearLastModifiedAt() => clearField(106);

  @$pb.TagNumber(107)
  $fixnum.Int64 get favoriteModifiedAt => $_getI64(21);
  @$pb.TagNumber(107)
  set favoriteModifiedAt($fixnum.Int64 v) {
    $_setInt64(21, v);
  }

  @$pb.TagNumber(107)
  $core.bool hasFavoriteModifiedAt() => $_has(21);
  @$pb.TagNumber(107)
  void clearFavoriteModifiedAt() => clearField(107);

  @$pb.TagNumber(108)
  $core.List<$core.String> get excludedScanlators => $_getList(22);

  @$pb.TagNumber(109)
  $fixnum.Int64 get version => $_getI64(23);
  @$pb.TagNumber(109)
  set version($fixnum.Int64 v) {
    $_setInt64(23, v);
  }

  @$pb.TagNumber(109)
  $core.bool hasVersion() => $_has(23);
  @$pb.TagNumber(109)
  void clearVersion() => clearField(109);

  @$pb.TagNumber(600)
  $core.List<BackupMergedMangaReference> get mergedMangaReferences =>
      $_getList(24);

  @$pb.TagNumber(601)
  BackupFlatMetadata get flatMetadata => $_getN(25);
  @$pb.TagNumber(601)
  set flatMetadata(BackupFlatMetadata v) {
    setField(601, v);
  }

  @$pb.TagNumber(601)
  $core.bool hasFlatMetadata() => $_has(25);
  @$pb.TagNumber(601)
  void clearFlatMetadata() => clearField(601);
  @$pb.TagNumber(601)
  BackupFlatMetadata ensureFlatMetadata() => $_ensure(25);

  @$pb.TagNumber(602)
  $core.int get customStatus => $_getIZ(26);
  @$pb.TagNumber(602)
  set customStatus($core.int v) {
    $_setSignedInt32(26, v);
  }

  @$pb.TagNumber(602)
  $core.bool hasCustomStatus() => $_has(26);
  @$pb.TagNumber(602)
  void clearCustomStatus() => clearField(602);

  @$pb.TagNumber(603)
  $core.String get customThumbnailUrl => $_getSZ(27);
  @$pb.TagNumber(603)
  set customThumbnailUrl($core.String v) {
    $_setString(27, v);
  }

  @$pb.TagNumber(603)
  $core.bool hasCustomThumbnailUrl() => $_has(27);
  @$pb.TagNumber(603)
  void clearCustomThumbnailUrl() => clearField(603);

  @$pb.TagNumber(800)
  $core.String get customTitle => $_getSZ(28);
  @$pb.TagNumber(800)
  set customTitle($core.String v) {
    $_setString(28, v);
  }

  @$pb.TagNumber(800)
  $core.bool hasCustomTitle() => $_has(28);
  @$pb.TagNumber(800)
  void clearCustomTitle() => clearField(800);

  @$pb.TagNumber(801)
  $core.String get customArtist => $_getSZ(29);
  @$pb.TagNumber(801)
  set customArtist($core.String v) {
    $_setString(29, v);
  }

  @$pb.TagNumber(801)
  $core.bool hasCustomArtist() => $_has(29);
  @$pb.TagNumber(801)
  void clearCustomArtist() => clearField(801);

  @$pb.TagNumber(802)
  $core.String get customAuthor => $_getSZ(30);
  @$pb.TagNumber(802)
  set customAuthor($core.String v) {
    $_setString(30, v);
  }

  @$pb.TagNumber(802)
  $core.bool hasCustomAuthor() => $_has(30);
  @$pb.TagNumber(802)
  void clearCustomAuthor() => clearField(802);

  @$pb.TagNumber(804)
  $core.String get customDescription => $_getSZ(31);
  @$pb.TagNumber(804)
  set customDescription($core.String v) {
    $_setString(31, v);
  }

  @$pb.TagNumber(804)
  $core.bool hasCustomDescription() => $_has(31);
  @$pb.TagNumber(804)
  void clearCustomDescription() => clearField(804);

  @$pb.TagNumber(805)
  $core.List<$core.String> get customGenre => $_getList(32);
}

/// BackupMergedMangaReference.kt
class BackupMergedMangaReference extends $pb.GeneratedMessage {
  factory BackupMergedMangaReference({
    $core.bool? isInfoManga,
    $core.bool? getChapterUpdates,
    $core.int? chapterSortMode,
    $core.int? chapterPriority,
    $core.bool? downloadChapters,
    $core.String? mergeUrl,
    $core.String? mangaUrl,
    $fixnum.Int64? mangaSourceId,
  }) {
    final $result = create();
    if (isInfoManga != null) {
      $result.isInfoManga = isInfoManga;
    }
    if (getChapterUpdates != null) {
      $result.getChapterUpdates = getChapterUpdates;
    }
    if (chapterSortMode != null) {
      $result.chapterSortMode = chapterSortMode;
    }
    if (chapterPriority != null) {
      $result.chapterPriority = chapterPriority;
    }
    if (downloadChapters != null) {
      $result.downloadChapters = downloadChapters;
    }
    if (mergeUrl != null) {
      $result.mergeUrl = mergeUrl;
    }
    if (mangaUrl != null) {
      $result.mangaUrl = mangaUrl;
    }
    if (mangaSourceId != null) {
      $result.mangaSourceId = mangaSourceId;
    }
    return $result;
  }
  BackupMergedMangaReference._() : super();
  factory BackupMergedMangaReference.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupMergedMangaReference.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupMergedMangaReference',
      createEmptyInstance: create)
    ..a<$core.bool>(1, _omitFieldNames ? '' : 'isInfoManga', $pb.PbFieldType.QB,
        protoName: 'isInfoManga')
    ..a<$core.bool>(
        2, _omitFieldNames ? '' : 'getChapterUpdates', $pb.PbFieldType.QB,
        protoName: 'getChapterUpdates')
    ..a<$core.int>(
        3, _omitFieldNames ? '' : 'chapterSortMode', $pb.PbFieldType.Q3,
        protoName: 'chapterSortMode')
    ..a<$core.int>(
        4, _omitFieldNames ? '' : 'chapterPriority', $pb.PbFieldType.Q3,
        protoName: 'chapterPriority')
    ..a<$core.bool>(
        5, _omitFieldNames ? '' : 'downloadChapters', $pb.PbFieldType.QB,
        protoName: 'downloadChapters')
    ..aQS(6, _omitFieldNames ? '' : 'mergeUrl', protoName: 'mergeUrl')
    ..aQS(7, _omitFieldNames ? '' : 'mangaUrl', protoName: 'mangaUrl')
    ..a<$fixnum.Int64>(
        8, _omitFieldNames ? '' : 'mangaSourceId', $pb.PbFieldType.Q6,
        protoName: 'mangaSourceId', defaultOrMaker: $fixnum.Int64.ZERO);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupMergedMangaReference clone() =>
      BackupMergedMangaReference()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupMergedMangaReference copyWith(
          void Function(BackupMergedMangaReference) updates) =>
      super.copyWith(
              (message) => updates(message as BackupMergedMangaReference))
          as BackupMergedMangaReference;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupMergedMangaReference create() => BackupMergedMangaReference._();
  BackupMergedMangaReference createEmptyInstance() => create();
  static $pb.PbList<BackupMergedMangaReference> createRepeated() =>
      $pb.PbList<BackupMergedMangaReference>();
  @$core.pragma('dart2js:noInline')
  static BackupMergedMangaReference getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupMergedMangaReference>(create);
  static BackupMergedMangaReference? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get isInfoManga => $_getBF(0);
  @$pb.TagNumber(1)
  set isInfoManga($core.bool v) {
    $_setBool(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasIsInfoManga() => $_has(0);
  @$pb.TagNumber(1)
  void clearIsInfoManga() => clearField(1);

  @$pb.TagNumber(2)
  $core.bool get getChapterUpdates => $_getBF(1);
  @$pb.TagNumber(2)
  set getChapterUpdates($core.bool v) {
    $_setBool(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasGetChapterUpdates() => $_has(1);
  @$pb.TagNumber(2)
  void clearGetChapterUpdates() => clearField(2);

  @$pb.TagNumber(3)
  $core.int get chapterSortMode => $_getIZ(2);
  @$pb.TagNumber(3)
  set chapterSortMode($core.int v) {
    $_setSignedInt32(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasChapterSortMode() => $_has(2);
  @$pb.TagNumber(3)
  void clearChapterSortMode() => clearField(3);

  @$pb.TagNumber(4)
  $core.int get chapterPriority => $_getIZ(3);
  @$pb.TagNumber(4)
  set chapterPriority($core.int v) {
    $_setSignedInt32(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasChapterPriority() => $_has(3);
  @$pb.TagNumber(4)
  void clearChapterPriority() => clearField(4);

  @$pb.TagNumber(5)
  $core.bool get downloadChapters => $_getBF(4);
  @$pb.TagNumber(5)
  set downloadChapters($core.bool v) {
    $_setBool(4, v);
  }

  @$pb.TagNumber(5)
  $core.bool hasDownloadChapters() => $_has(4);
  @$pb.TagNumber(5)
  void clearDownloadChapters() => clearField(5);

  @$pb.TagNumber(6)
  $core.String get mergeUrl => $_getSZ(5);
  @$pb.TagNumber(6)
  set mergeUrl($core.String v) {
    $_setString(5, v);
  }

  @$pb.TagNumber(6)
  $core.bool hasMergeUrl() => $_has(5);
  @$pb.TagNumber(6)
  void clearMergeUrl() => clearField(6);

  @$pb.TagNumber(7)
  $core.String get mangaUrl => $_getSZ(6);
  @$pb.TagNumber(7)
  set mangaUrl($core.String v) {
    $_setString(6, v);
  }

  @$pb.TagNumber(7)
  $core.bool hasMangaUrl() => $_has(6);
  @$pb.TagNumber(7)
  void clearMangaUrl() => clearField(7);

  @$pb.TagNumber(8)
  $fixnum.Int64 get mangaSourceId => $_getI64(7);
  @$pb.TagNumber(8)
  set mangaSourceId($fixnum.Int64 v) {
    $_setInt64(7, v);
  }

  @$pb.TagNumber(8)
  $core.bool hasMangaSourceId() => $_has(7);
  @$pb.TagNumber(8)
  void clearMangaSourceId() => clearField(8);
}

/// BackupPreference.kt
class BackupPreference extends $pb.GeneratedMessage {
  factory BackupPreference({
    $core.String? key,
    PreferenceValue? value,
  }) {
    final $result = create();
    if (key != null) {
      $result.key = key;
    }
    if (value != null) {
      $result.value = value;
    }
    return $result;
  }
  BackupPreference._() : super();
  factory BackupPreference.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupPreference.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupPreference',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'key')
    ..aQM<PreferenceValue>(2, _omitFieldNames ? '' : 'value',
        subBuilder: PreferenceValue.create);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupPreference clone() => BackupPreference()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupPreference copyWith(void Function(BackupPreference) updates) =>
      super.copyWith((message) => updates(message as BackupPreference))
          as BackupPreference;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupPreference create() => BackupPreference._();
  BackupPreference createEmptyInstance() => create();
  static $pb.PbList<BackupPreference> createRepeated() =>
      $pb.PbList<BackupPreference>();
  @$core.pragma('dart2js:noInline')
  static BackupPreference getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupPreference>(create);
  static BackupPreference? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get key => $_getSZ(0);
  @$pb.TagNumber(1)
  set key($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearKey() => clearField(1);

  @$pb.TagNumber(2)
  PreferenceValue get value => $_getN(1);
  @$pb.TagNumber(2)
  set value(PreferenceValue v) {
    setField(2, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearValue() => clearField(2);
  @$pb.TagNumber(2)
  PreferenceValue ensureValue() => $_ensure(1);
}

class BackupSourcePreferences extends $pb.GeneratedMessage {
  factory BackupSourcePreferences({
    $core.String? sourceKey,
    $core.Iterable<BackupPreference>? prefs,
  }) {
    final $result = create();
    if (sourceKey != null) {
      $result.sourceKey = sourceKey;
    }
    if (prefs != null) {
      $result.prefs.addAll(prefs);
    }
    return $result;
  }
  BackupSourcePreferences._() : super();
  factory BackupSourcePreferences.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupSourcePreferences.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupSourcePreferences',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'sourceKey', protoName: 'sourceKey')
    ..pc<BackupPreference>(
        2, _omitFieldNames ? '' : 'prefs', $pb.PbFieldType.PM,
        subBuilder: BackupPreference.create);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupSourcePreferences clone() =>
      BackupSourcePreferences()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupSourcePreferences copyWith(
          void Function(BackupSourcePreferences) updates) =>
      super.copyWith((message) => updates(message as BackupSourcePreferences))
          as BackupSourcePreferences;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupSourcePreferences create() => BackupSourcePreferences._();
  BackupSourcePreferences createEmptyInstance() => create();
  static $pb.PbList<BackupSourcePreferences> createRepeated() =>
      $pb.PbList<BackupSourcePreferences>();
  @$core.pragma('dart2js:noInline')
  static BackupSourcePreferences getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupSourcePreferences>(create);
  static BackupSourcePreferences? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get sourceKey => $_getSZ(0);
  @$pb.TagNumber(1)
  set sourceKey($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasSourceKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearSourceKey() => clearField(1);

  @$pb.TagNumber(2)
  $core.List<BackupPreference> get prefs => $_getList(1);
}

class IntPreferenceValue extends $pb.GeneratedMessage {
  factory IntPreferenceValue({
    $core.int? value,
  }) {
    final $result = create();
    if (value != null) {
      $result.value = value;
    }
    return $result;
  }
  IntPreferenceValue._() : super();
  factory IntPreferenceValue.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory IntPreferenceValue.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'IntPreferenceValue',
      createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'value', $pb.PbFieldType.Q3);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  IntPreferenceValue clone() => IntPreferenceValue()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  IntPreferenceValue copyWith(void Function(IntPreferenceValue) updates) =>
      super.copyWith((message) => updates(message as IntPreferenceValue))
          as IntPreferenceValue;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static IntPreferenceValue create() => IntPreferenceValue._();
  IntPreferenceValue createEmptyInstance() => create();
  static $pb.PbList<IntPreferenceValue> createRepeated() =>
      $pb.PbList<IntPreferenceValue>();
  @$core.pragma('dart2js:noInline')
  static IntPreferenceValue getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<IntPreferenceValue>(create);
  static IntPreferenceValue? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get value => $_getIZ(0);
  @$pb.TagNumber(1)
  set value($core.int v) {
    $_setSignedInt32(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearValue() => clearField(1);
}

class LongPreferenceValue extends $pb.GeneratedMessage {
  factory LongPreferenceValue({
    $fixnum.Int64? value,
  }) {
    final $result = create();
    if (value != null) {
      $result.value = value;
    }
    return $result;
  }
  LongPreferenceValue._() : super();
  factory LongPreferenceValue.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory LongPreferenceValue.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'LongPreferenceValue',
      createEmptyInstance: create)
    ..a<$fixnum.Int64>(1, _omitFieldNames ? '' : 'value', $pb.PbFieldType.Q6,
        defaultOrMaker: $fixnum.Int64.ZERO);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  LongPreferenceValue clone() => LongPreferenceValue()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  LongPreferenceValue copyWith(void Function(LongPreferenceValue) updates) =>
      super.copyWith((message) => updates(message as LongPreferenceValue))
          as LongPreferenceValue;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static LongPreferenceValue create() => LongPreferenceValue._();
  LongPreferenceValue createEmptyInstance() => create();
  static $pb.PbList<LongPreferenceValue> createRepeated() =>
      $pb.PbList<LongPreferenceValue>();
  @$core.pragma('dart2js:noInline')
  static LongPreferenceValue getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<LongPreferenceValue>(create);
  static LongPreferenceValue? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get value => $_getI64(0);
  @$pb.TagNumber(1)
  set value($fixnum.Int64 v) {
    $_setInt64(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearValue() => clearField(1);
}

class FloatPreferenceValue extends $pb.GeneratedMessage {
  factory FloatPreferenceValue({
    $core.double? value,
  }) {
    final $result = create();
    if (value != null) {
      $result.value = value;
    }
    return $result;
  }
  FloatPreferenceValue._() : super();
  factory FloatPreferenceValue.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory FloatPreferenceValue.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FloatPreferenceValue',
      createEmptyInstance: create)
    ..a<$core.double>(1, _omitFieldNames ? '' : 'value', $pb.PbFieldType.QF);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  FloatPreferenceValue clone() =>
      FloatPreferenceValue()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  FloatPreferenceValue copyWith(void Function(FloatPreferenceValue) updates) =>
      super.copyWith((message) => updates(message as FloatPreferenceValue))
          as FloatPreferenceValue;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static FloatPreferenceValue create() => FloatPreferenceValue._();
  FloatPreferenceValue createEmptyInstance() => create();
  static $pb.PbList<FloatPreferenceValue> createRepeated() =>
      $pb.PbList<FloatPreferenceValue>();
  @$core.pragma('dart2js:noInline')
  static FloatPreferenceValue getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FloatPreferenceValue>(create);
  static FloatPreferenceValue? _defaultInstance;

  @$pb.TagNumber(1)
  $core.double get value => $_getN(0);
  @$pb.TagNumber(1)
  set value($core.double v) {
    $_setFloat(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearValue() => clearField(1);
}

class StringPreferenceValue extends $pb.GeneratedMessage {
  factory StringPreferenceValue({
    $core.String? value,
  }) {
    final $result = create();
    if (value != null) {
      $result.value = value;
    }
    return $result;
  }
  StringPreferenceValue._() : super();
  factory StringPreferenceValue.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory StringPreferenceValue.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'StringPreferenceValue',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'value');

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  StringPreferenceValue clone() =>
      StringPreferenceValue()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  StringPreferenceValue copyWith(
          void Function(StringPreferenceValue) updates) =>
      super.copyWith((message) => updates(message as StringPreferenceValue))
          as StringPreferenceValue;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StringPreferenceValue create() => StringPreferenceValue._();
  StringPreferenceValue createEmptyInstance() => create();
  static $pb.PbList<StringPreferenceValue> createRepeated() =>
      $pb.PbList<StringPreferenceValue>();
  @$core.pragma('dart2js:noInline')
  static StringPreferenceValue getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<StringPreferenceValue>(create);
  static StringPreferenceValue? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get value => $_getSZ(0);
  @$pb.TagNumber(1)
  set value($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearValue() => clearField(1);
}

class BooleanPreferenceValue extends $pb.GeneratedMessage {
  factory BooleanPreferenceValue({
    $core.bool? value,
  }) {
    final $result = create();
    if (value != null) {
      $result.value = value;
    }
    return $result;
  }
  BooleanPreferenceValue._() : super();
  factory BooleanPreferenceValue.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BooleanPreferenceValue.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BooleanPreferenceValue',
      createEmptyInstance: create)
    ..a<$core.bool>(1, _omitFieldNames ? '' : 'value', $pb.PbFieldType.QB);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BooleanPreferenceValue clone() =>
      BooleanPreferenceValue()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BooleanPreferenceValue copyWith(
          void Function(BooleanPreferenceValue) updates) =>
      super.copyWith((message) => updates(message as BooleanPreferenceValue))
          as BooleanPreferenceValue;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BooleanPreferenceValue create() => BooleanPreferenceValue._();
  BooleanPreferenceValue createEmptyInstance() => create();
  static $pb.PbList<BooleanPreferenceValue> createRepeated() =>
      $pb.PbList<BooleanPreferenceValue>();
  @$core.pragma('dart2js:noInline')
  static BooleanPreferenceValue getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BooleanPreferenceValue>(create);
  static BooleanPreferenceValue? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get value => $_getBF(0);
  @$pb.TagNumber(1)
  set value($core.bool v) {
    $_setBool(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearValue() => clearField(1);
}

class StringSetPreferenceValue extends $pb.GeneratedMessage {
  factory StringSetPreferenceValue({
    $core.Iterable<$core.String>? value,
  }) {
    final $result = create();
    if (value != null) {
      $result.value.addAll(value);
    }
    return $result;
  }
  StringSetPreferenceValue._() : super();
  factory StringSetPreferenceValue.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory StringSetPreferenceValue.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'StringSetPreferenceValue',
      createEmptyInstance: create)
    ..pPS(1, _omitFieldNames ? '' : 'value')
    ..hasRequiredFields = false;

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  StringSetPreferenceValue clone() =>
      StringSetPreferenceValue()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  StringSetPreferenceValue copyWith(
          void Function(StringSetPreferenceValue) updates) =>
      super.copyWith((message) => updates(message as StringSetPreferenceValue))
          as StringSetPreferenceValue;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static StringSetPreferenceValue create() => StringSetPreferenceValue._();
  StringSetPreferenceValue createEmptyInstance() => create();
  static $pb.PbList<StringSetPreferenceValue> createRepeated() =>
      $pb.PbList<StringSetPreferenceValue>();
  @$core.pragma('dart2js:noInline')
  static StringSetPreferenceValue getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<StringSetPreferenceValue>(create);
  static StringSetPreferenceValue? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.String> get value => $_getList(0);
}

/// BackupSavedSearch.kt
class BackupSavedSearch extends $pb.GeneratedMessage {
  factory BackupSavedSearch({
    $core.String? name,
    $core.String? query,
    $core.String? filterList,
    $fixnum.Int64? source,
  }) {
    final $result = create();
    if (name != null) {
      $result.name = name;
    }
    if (query != null) {
      $result.query = query;
    }
    if (filterList != null) {
      $result.filterList = filterList;
    }
    if (source != null) {
      $result.source = source;
    }
    return $result;
  }
  BackupSavedSearch._() : super();
  factory BackupSavedSearch.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupSavedSearch.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupSavedSearch',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'query')
    ..aOS(3, _omitFieldNames ? '' : 'filterList', protoName: 'filterList')
    ..aInt64(4, _omitFieldNames ? '' : 'source');

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupSavedSearch clone() => BackupSavedSearch()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupSavedSearch copyWith(void Function(BackupSavedSearch) updates) =>
      super.copyWith((message) => updates(message as BackupSavedSearch))
          as BackupSavedSearch;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupSavedSearch create() => BackupSavedSearch._();
  BackupSavedSearch createEmptyInstance() => create();
  static $pb.PbList<BackupSavedSearch> createRepeated() =>
      $pb.PbList<BackupSavedSearch>();
  @$core.pragma('dart2js:noInline')
  static BackupSavedSearch getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupSavedSearch>(create);
  static BackupSavedSearch? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get query => $_getSZ(1);
  @$pb.TagNumber(2)
  set query($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasQuery() => $_has(1);
  @$pb.TagNumber(2)
  void clearQuery() => clearField(2);

  @$pb.TagNumber(3)
  $core.String get filterList => $_getSZ(2);
  @$pb.TagNumber(3)
  set filterList($core.String v) {
    $_setString(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasFilterList() => $_has(2);
  @$pb.TagNumber(3)
  void clearFilterList() => clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get source => $_getI64(3);
  @$pb.TagNumber(4)
  set source($fixnum.Int64 v) {
    $_setInt64(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasSource() => $_has(3);
  @$pb.TagNumber(4)
  void clearSource() => clearField(4);
}

/// BackupSource.kt
class BackupSource extends $pb.GeneratedMessage {
  factory BackupSource({
    $core.String? name,
    $fixnum.Int64? sourceId,
  }) {
    final $result = create();
    if (name != null) {
      $result.name = name;
    }
    if (sourceId != null) {
      $result.sourceId = sourceId;
    }
    return $result;
  }
  BackupSource._() : super();
  factory BackupSource.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupSource.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupSource',
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'sourceId', $pb.PbFieldType.Q6,
        protoName: 'sourceId', defaultOrMaker: $fixnum.Int64.ZERO);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupSource clone() => BackupSource()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupSource copyWith(void Function(BackupSource) updates) =>
      super.copyWith((message) => updates(message as BackupSource))
          as BackupSource;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupSource create() => BackupSource._();
  BackupSource createEmptyInstance() => create();
  static $pb.PbList<BackupSource> createRepeated() =>
      $pb.PbList<BackupSource>();
  @$core.pragma('dart2js:noInline')
  static BackupSource getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupSource>(create);
  static BackupSource? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get sourceId => $_getI64(1);
  @$pb.TagNumber(2)
  set sourceId($fixnum.Int64 v) {
    $_setInt64(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasSourceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearSourceId() => clearField(2);
}

class BrokenBackupSource extends $pb.GeneratedMessage {
  factory BrokenBackupSource({
    $core.String? name,
    $fixnum.Int64? sourceId,
  }) {
    final $result = create();
    if (name != null) {
      $result.name = name;
    }
    if (sourceId != null) {
      $result.sourceId = sourceId;
    }
    return $result;
  }
  BrokenBackupSource._() : super();
  factory BrokenBackupSource.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BrokenBackupSource.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BrokenBackupSource',
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'sourceId', $pb.PbFieldType.Q6,
        protoName: 'sourceId', defaultOrMaker: $fixnum.Int64.ZERO);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BrokenBackupSource clone() => BrokenBackupSource()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BrokenBackupSource copyWith(void Function(BrokenBackupSource) updates) =>
      super.copyWith((message) => updates(message as BrokenBackupSource))
          as BrokenBackupSource;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BrokenBackupSource create() => BrokenBackupSource._();
  BrokenBackupSource createEmptyInstance() => create();
  static $pb.PbList<BrokenBackupSource> createRepeated() =>
      $pb.PbList<BrokenBackupSource>();
  @$core.pragma('dart2js:noInline')
  static BrokenBackupSource getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BrokenBackupSource>(create);
  static BrokenBackupSource? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get sourceId => $_getI64(1);
  @$pb.TagNumber(2)
  set sourceId($fixnum.Int64 v) {
    $_setInt64(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasSourceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearSourceId() => clearField(2);
}

/// BackupTracking.kt
class BackupTracking extends $pb.GeneratedMessage {
  factory BackupTracking({
    $core.int? syncId,
    $fixnum.Int64? libraryId,
    $core.int? mediaIdInt,
    $core.String? trackingUrl,
    $core.String? title,
    $core.double? lastChapterRead,
    $core.int? totalChapters,
    $core.double? score,
    $core.int? status,
    $fixnum.Int64? startedReadingDate,
    $fixnum.Int64? finishedReadingDate,
    $fixnum.Int64? mediaId,
  }) {
    final $result = create();
    if (syncId != null) {
      $result.syncId = syncId;
    }
    if (libraryId != null) {
      $result.libraryId = libraryId;
    }
    if (mediaIdInt != null) {
      $result.mediaIdInt = mediaIdInt;
    }
    if (trackingUrl != null) {
      $result.trackingUrl = trackingUrl;
    }
    if (title != null) {
      $result.title = title;
    }
    if (lastChapterRead != null) {
      $result.lastChapterRead = lastChapterRead;
    }
    if (totalChapters != null) {
      $result.totalChapters = totalChapters;
    }
    if (score != null) {
      $result.score = score;
    }
    if (status != null) {
      $result.status = status;
    }
    if (startedReadingDate != null) {
      $result.startedReadingDate = startedReadingDate;
    }
    if (finishedReadingDate != null) {
      $result.finishedReadingDate = finishedReadingDate;
    }
    if (mediaId != null) {
      $result.mediaId = mediaId;
    }
    return $result;
  }
  BackupTracking._() : super();
  factory BackupTracking.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupTracking.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupTracking',
      createEmptyInstance: create)
    ..a<$core.int>(1, _omitFieldNames ? '' : 'syncId', $pb.PbFieldType.Q3,
        protoName: 'syncId')
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'libraryId', $pb.PbFieldType.Q6,
        protoName: 'libraryId', defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$core.int>(3, _omitFieldNames ? '' : 'mediaIdInt', $pb.PbFieldType.O3,
        protoName: 'mediaIdInt')
    ..aOS(4, _omitFieldNames ? '' : 'trackingUrl', protoName: 'trackingUrl')
    ..aOS(5, _omitFieldNames ? '' : 'title')
    ..a<$core.double>(
        6, _omitFieldNames ? '' : 'lastChapterRead', $pb.PbFieldType.OF,
        protoName: 'lastChapterRead')
    ..a<$core.int>(
        7, _omitFieldNames ? '' : 'totalChapters', $pb.PbFieldType.O3,
        protoName: 'totalChapters')
    ..a<$core.double>(8, _omitFieldNames ? '' : 'score', $pb.PbFieldType.OF)
    ..a<$core.int>(9, _omitFieldNames ? '' : 'status', $pb.PbFieldType.O3)
    ..aInt64(10, _omitFieldNames ? '' : 'startedReadingDate',
        protoName: 'startedReadingDate')
    ..aInt64(11, _omitFieldNames ? '' : 'finishedReadingDate',
        protoName: 'finishedReadingDate')
    ..aInt64(100, _omitFieldNames ? '' : 'mediaId', protoName: 'mediaId');

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupTracking clone() => BackupTracking()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupTracking copyWith(void Function(BackupTracking) updates) =>
      super.copyWith((message) => updates(message as BackupTracking))
          as BackupTracking;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupTracking create() => BackupTracking._();
  BackupTracking createEmptyInstance() => create();
  static $pb.PbList<BackupTracking> createRepeated() =>
      $pb.PbList<BackupTracking>();
  @$core.pragma('dart2js:noInline')
  static BackupTracking getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupTracking>(create);
  static BackupTracking? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get syncId => $_getIZ(0);
  @$pb.TagNumber(1)
  set syncId($core.int v) {
    $_setSignedInt32(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasSyncId() => $_has(0);
  @$pb.TagNumber(1)
  void clearSyncId() => clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get libraryId => $_getI64(1);
  @$pb.TagNumber(2)
  set libraryId($fixnum.Int64 v) {
    $_setInt64(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasLibraryId() => $_has(1);
  @$pb.TagNumber(2)
  void clearLibraryId() => clearField(2);

  @$pb.TagNumber(3)
  $core.int get mediaIdInt => $_getIZ(2);
  @$pb.TagNumber(3)
  set mediaIdInt($core.int v) {
    $_setSignedInt32(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasMediaIdInt() => $_has(2);
  @$pb.TagNumber(3)
  void clearMediaIdInt() => clearField(3);

  @$pb.TagNumber(4)
  $core.String get trackingUrl => $_getSZ(3);
  @$pb.TagNumber(4)
  set trackingUrl($core.String v) {
    $_setString(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasTrackingUrl() => $_has(3);
  @$pb.TagNumber(4)
  void clearTrackingUrl() => clearField(4);

  @$pb.TagNumber(5)
  $core.String get title => $_getSZ(4);
  @$pb.TagNumber(5)
  set title($core.String v) {
    $_setString(4, v);
  }

  @$pb.TagNumber(5)
  $core.bool hasTitle() => $_has(4);
  @$pb.TagNumber(5)
  void clearTitle() => clearField(5);

  @$pb.TagNumber(6)
  $core.double get lastChapterRead => $_getN(5);
  @$pb.TagNumber(6)
  set lastChapterRead($core.double v) {
    $_setFloat(5, v);
  }

  @$pb.TagNumber(6)
  $core.bool hasLastChapterRead() => $_has(5);
  @$pb.TagNumber(6)
  void clearLastChapterRead() => clearField(6);

  @$pb.TagNumber(7)
  $core.int get totalChapters => $_getIZ(6);
  @$pb.TagNumber(7)
  set totalChapters($core.int v) {
    $_setSignedInt32(6, v);
  }

  @$pb.TagNumber(7)
  $core.bool hasTotalChapters() => $_has(6);
  @$pb.TagNumber(7)
  void clearTotalChapters() => clearField(7);

  @$pb.TagNumber(8)
  $core.double get score => $_getN(7);
  @$pb.TagNumber(8)
  set score($core.double v) {
    $_setFloat(7, v);
  }

  @$pb.TagNumber(8)
  $core.bool hasScore() => $_has(7);
  @$pb.TagNumber(8)
  void clearScore() => clearField(8);

  @$pb.TagNumber(9)
  $core.int get status => $_getIZ(8);
  @$pb.TagNumber(9)
  set status($core.int v) {
    $_setSignedInt32(8, v);
  }

  @$pb.TagNumber(9)
  $core.bool hasStatus() => $_has(8);
  @$pb.TagNumber(9)
  void clearStatus() => clearField(9);

  @$pb.TagNumber(10)
  $fixnum.Int64 get startedReadingDate => $_getI64(9);
  @$pb.TagNumber(10)
  set startedReadingDate($fixnum.Int64 v) {
    $_setInt64(9, v);
  }

  @$pb.TagNumber(10)
  $core.bool hasStartedReadingDate() => $_has(9);
  @$pb.TagNumber(10)
  void clearStartedReadingDate() => clearField(10);

  @$pb.TagNumber(11)
  $fixnum.Int64 get finishedReadingDate => $_getI64(10);
  @$pb.TagNumber(11)
  set finishedReadingDate($fixnum.Int64 v) {
    $_setInt64(10, v);
  }

  @$pb.TagNumber(11)
  $core.bool hasFinishedReadingDate() => $_has(10);
  @$pb.TagNumber(11)
  void clearFinishedReadingDate() => clearField(11);

  @$pb.TagNumber(100)
  $fixnum.Int64 get mediaId => $_getI64(11);
  @$pb.TagNumber(100)
  set mediaId($fixnum.Int64 v) {
    $_setInt64(11, v);
  }

  @$pb.TagNumber(100)
  $core.bool hasMediaId() => $_has(11);
  @$pb.TagNumber(100)
  void clearMediaId() => clearField(100);
}

/// BackupSearchMetadata.kt
class BackupSearchMetadata extends $pb.GeneratedMessage {
  factory BackupSearchMetadata({
    $core.String? uploader,
    $core.String? extra,
    $core.String? indexedExtra,
    $core.int? extraVersion,
  }) {
    final $result = create();
    if (uploader != null) {
      $result.uploader = uploader;
    }
    if (extra != null) {
      $result.extra = extra;
    }
    if (indexedExtra != null) {
      $result.indexedExtra = indexedExtra;
    }
    if (extraVersion != null) {
      $result.extraVersion = extraVersion;
    }
    return $result;
  }
  BackupSearchMetadata._() : super();
  factory BackupSearchMetadata.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupSearchMetadata.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupSearchMetadata',
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'uploader')
    ..aQS(2, _omitFieldNames ? '' : 'extra')
    ..aOS(3, _omitFieldNames ? '' : 'indexedExtra', protoName: 'indexedExtra')
    ..a<$core.int>(4, _omitFieldNames ? '' : 'extraVersion', $pb.PbFieldType.Q3,
        protoName: 'extraVersion');

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupSearchMetadata clone() =>
      BackupSearchMetadata()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupSearchMetadata copyWith(void Function(BackupSearchMetadata) updates) =>
      super.copyWith((message) => updates(message as BackupSearchMetadata))
          as BackupSearchMetadata;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupSearchMetadata create() => BackupSearchMetadata._();
  BackupSearchMetadata createEmptyInstance() => create();
  static $pb.PbList<BackupSearchMetadata> createRepeated() =>
      $pb.PbList<BackupSearchMetadata>();
  @$core.pragma('dart2js:noInline')
  static BackupSearchMetadata getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupSearchMetadata>(create);
  static BackupSearchMetadata? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get uploader => $_getSZ(0);
  @$pb.TagNumber(1)
  set uploader($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasUploader() => $_has(0);
  @$pb.TagNumber(1)
  void clearUploader() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get extra => $_getSZ(1);
  @$pb.TagNumber(2)
  set extra($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasExtra() => $_has(1);
  @$pb.TagNumber(2)
  void clearExtra() => clearField(2);

  @$pb.TagNumber(3)
  $core.String get indexedExtra => $_getSZ(2);
  @$pb.TagNumber(3)
  set indexedExtra($core.String v) {
    $_setString(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasIndexedExtra() => $_has(2);
  @$pb.TagNumber(3)
  void clearIndexedExtra() => clearField(3);

  @$pb.TagNumber(4)
  $core.int get extraVersion => $_getIZ(3);
  @$pb.TagNumber(4)
  set extraVersion($core.int v) {
    $_setSignedInt32(3, v);
  }

  @$pb.TagNumber(4)
  $core.bool hasExtraVersion() => $_has(3);
  @$pb.TagNumber(4)
  void clearExtraVersion() => clearField(4);
}

/// BackupSearchTag.kt
class BackupSearchTag extends $pb.GeneratedMessage {
  factory BackupSearchTag({
    $core.String? namespace,
    $core.String? name,
    $core.int? type,
  }) {
    final $result = create();
    if (namespace != null) {
      $result.namespace = namespace;
    }
    if (name != null) {
      $result.name = name;
    }
    if (type != null) {
      $result.type = type;
    }
    return $result;
  }
  BackupSearchTag._() : super();
  factory BackupSearchTag.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupSearchTag.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupSearchTag',
      createEmptyInstance: create)
    ..aOS(1, _omitFieldNames ? '' : 'namespace')
    ..aQS(2, _omitFieldNames ? '' : 'name')
    ..a<$core.int>(3, _omitFieldNames ? '' : 'type', $pb.PbFieldType.Q3);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupSearchTag clone() => BackupSearchTag()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupSearchTag copyWith(void Function(BackupSearchTag) updates) =>
      super.copyWith((message) => updates(message as BackupSearchTag))
          as BackupSearchTag;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupSearchTag create() => BackupSearchTag._();
  BackupSearchTag createEmptyInstance() => create();
  static $pb.PbList<BackupSearchTag> createRepeated() =>
      $pb.PbList<BackupSearchTag>();
  @$core.pragma('dart2js:noInline')
  static BackupSearchTag getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupSearchTag>(create);
  static BackupSearchTag? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get namespace => $_getSZ(0);
  @$pb.TagNumber(1)
  set namespace($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasNamespace() => $_has(0);
  @$pb.TagNumber(1)
  void clearNamespace() => clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String v) {
    $_setString(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => clearField(2);

  @$pb.TagNumber(3)
  $core.int get type => $_getIZ(2);
  @$pb.TagNumber(3)
  set type($core.int v) {
    $_setSignedInt32(2, v);
  }

  @$pb.TagNumber(3)
  $core.bool hasType() => $_has(2);
  @$pb.TagNumber(3)
  void clearType() => clearField(3);
}

/// BackupSearchTitle.kt
class BackupSearchTitle extends $pb.GeneratedMessage {
  factory BackupSearchTitle({
    $core.String? title,
    $core.int? type,
  }) {
    final $result = create();
    if (title != null) {
      $result.title = title;
    }
    if (type != null) {
      $result.type = type;
    }
    return $result;
  }
  BackupSearchTitle._() : super();
  factory BackupSearchTitle.fromBuffer($core.List<$core.int> i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromBuffer(i, r);
  factory BackupSearchTitle.fromJson($core.String i,
          [$pb.ExtensionRegistry r = $pb.ExtensionRegistry.EMPTY]) =>
      create()..mergeFromJson(i, r);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BackupSearchTitle',
      createEmptyInstance: create)
    ..aQS(1, _omitFieldNames ? '' : 'title')
    ..a<$core.int>(2, _omitFieldNames ? '' : 'type', $pb.PbFieldType.Q3);

  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.deepCopy] instead. '
      'Will be removed in next major version')
  BackupSearchTitle clone() => BackupSearchTitle()..mergeFromMessage(this);
  @$core.Deprecated('Using this can add significant overhead to your binary. '
      'Use [GeneratedMessageGenericExtensions.rebuild] instead. '
      'Will be removed in next major version')
  BackupSearchTitle copyWith(void Function(BackupSearchTitle) updates) =>
      super.copyWith((message) => updates(message as BackupSearchTitle))
          as BackupSearchTitle;

  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  static BackupSearchTitle create() => BackupSearchTitle._();
  BackupSearchTitle createEmptyInstance() => create();
  static $pb.PbList<BackupSearchTitle> createRepeated() =>
      $pb.PbList<BackupSearchTitle>();
  @$core.pragma('dart2js:noInline')
  static BackupSearchTitle getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BackupSearchTitle>(create);
  static BackupSearchTitle? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get title => $_getSZ(0);
  @$pb.TagNumber(1)
  set title($core.String v) {
    $_setString(0, v);
  }

  @$pb.TagNumber(1)
  $core.bool hasTitle() => $_has(0);
  @$pb.TagNumber(1)
  void clearTitle() => clearField(1);

  @$pb.TagNumber(2)
  $core.int get type => $_getIZ(1);
  @$pb.TagNumber(2)
  set type($core.int v) {
    $_setSignedInt32(1, v);
  }

  @$pb.TagNumber(2)
  $core.bool hasType() => $_has(1);
  @$pb.TagNumber(2)
  void clearType() => clearField(2);
}

const _omitFieldNames = $core.bool.fromEnvironment('protobuf.omit_field_names');
const _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
