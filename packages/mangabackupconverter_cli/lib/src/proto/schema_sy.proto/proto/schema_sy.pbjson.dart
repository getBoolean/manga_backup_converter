//
//  Generated code. Do not modify.
//  source: proto/schema_sy.proto
//
// @dart = 2.12

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_final_fields
// ignore_for_file: unnecessary_import, unnecessary_this, unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use updateStrategyDescriptor instead')
const UpdateStrategy$json = {
  '1': 'UpdateStrategy',
  '2': [
    {'1': 'ALWAYS_UPDATE', '2': 0},
    {'1': 'ONLY_FETCH_ONCE', '2': 1},
  ],
};

/// Descriptor for `UpdateStrategy`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List updateStrategyDescriptor =
    $convert.base64Decode('Cg5VcGRhdGVTdHJhdGVneRIRCg1BTFdBWVNfVVBEQVRFEAASEwoPT05MWV9GRVRDSF9PTkNFEA'
        'E=');

@$core.Deprecated('Use preferenceValueDescriptor instead')
const PreferenceValue$json = {
  '1': 'PreferenceValue',
  '2': [
    {'1': 'type', '3': 1, '4': 2, '5': 9, '10': 'type'},
    {'1': 'truevalue', '3': 2, '4': 2, '5': 12, '10': 'truevalue'},
  ],
};

/// Descriptor for `PreferenceValue`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List preferenceValueDescriptor =
    $convert.base64Decode('Cg9QcmVmZXJlbmNlVmFsdWUSEgoEdHlwZRgBIAIoCVIEdHlwZRIcCgl0cnVldmFsdWUYAiACKA'
        'xSCXRydWV2YWx1ZQ==');

@$core.Deprecated('Use backupDescriptor instead')
const Backup$json = {
  '1': 'Backup',
  '2': [
    {'1': 'backupManga', '3': 1, '4': 3, '5': 11, '6': '.BackupManga', '10': 'backupManga'},
    {'1': 'backupCategories', '3': 2, '4': 3, '5': 11, '6': '.BackupCategory', '10': 'backupCategories'},
    {'1': 'backupSources', '3': 101, '4': 3, '5': 11, '6': '.BackupSource', '10': 'backupSources'},
    {'1': 'backupPreferences', '3': 104, '4': 3, '5': 11, '6': '.BackupPreference', '10': 'backupPreferences'},
    {
      '1': 'backupSourcePreferences',
      '3': 105,
      '4': 3,
      '5': 11,
      '6': '.BackupSourcePreferences',
      '10': 'backupSourcePreferences'
    },
    {
      '1': 'backupExtensionStores',
      '3': 106,
      '4': 3,
      '5': 11,
      '6': '.BackupExtensionStore',
      '10': 'backupExtensionStores'
    },
    {'1': 'backupSavedSearches', '3': 600, '4': 3, '5': 11, '6': '.BackupSavedSearch', '10': 'backupSavedSearches'},
    {'1': 'backupFeeds', '3': 601, '4': 3, '5': 11, '6': '.BackupFeed', '10': 'backupFeeds'},
  ],
};

/// Descriptor for `Backup`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupDescriptor =
    $convert.base64Decode('CgZCYWNrdXASLgoLYmFja3VwTWFuZ2EYASADKAsyDC5CYWNrdXBNYW5nYVILYmFja3VwTWFuZ2'
        'ESOwoQYmFja3VwQ2F0ZWdvcmllcxgCIAMoCzIPLkJhY2t1cENhdGVnb3J5UhBiYWNrdXBDYXRl'
        'Z29yaWVzEjMKDWJhY2t1cFNvdXJjZXMYZSADKAsyDS5CYWNrdXBTb3VyY2VSDWJhY2t1cFNvdX'
        'JjZXMSPwoRYmFja3VwUHJlZmVyZW5jZXMYaCADKAsyES5CYWNrdXBQcmVmZXJlbmNlUhFiYWNr'
        'dXBQcmVmZXJlbmNlcxJSChdiYWNrdXBTb3VyY2VQcmVmZXJlbmNlcxhpIAMoCzIYLkJhY2t1cF'
        'NvdXJjZVByZWZlcmVuY2VzUhdiYWNrdXBTb3VyY2VQcmVmZXJlbmNlcxJLChViYWNrdXBFeHRl'
        'bnNpb25TdG9yZXMYaiADKAsyFS5CYWNrdXBFeHRlbnNpb25TdG9yZVIVYmFja3VwRXh0ZW5zaW'
        '9uU3RvcmVzEkUKE2JhY2t1cFNhdmVkU2VhcmNoZXMY2AQgAygLMhIuQmFja3VwU2F2ZWRTZWFy'
        'Y2hSE2JhY2t1cFNhdmVkU2VhcmNoZXMSLgoLYmFja3VwRmVlZHMY2QQgAygLMgsuQmFja3VwRm'
        'VlZFILYmFja3VwRmVlZHM=');

@$core.Deprecated('Use backupCategoryDescriptor instead')
const BackupCategory$json = {
  '1': 'BackupCategory',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'order', '3': 2, '4': 1, '5': 3, '10': 'order'},
    {'1': 'id', '3': 3, '4': 1, '5': 3, '10': 'id'},
    {'1': 'flags', '3': 100, '4': 1, '5': 3, '10': 'flags'},
    {'1': 'version', '3': 601, '4': 1, '5': 3, '10': 'version'},
    {'1': 'uid', '3': 602, '4': 1, '5': 3, '10': 'uid'},
    {'1': 'lastModifiedAt', '3': 603, '4': 1, '5': 3, '10': 'lastModifiedAt'},
  ],
};

/// Descriptor for `BackupCategory`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupCategoryDescriptor =
    $convert.base64Decode('Cg5CYWNrdXBDYXRlZ29yeRISCgRuYW1lGAEgASgJUgRuYW1lEhQKBW9yZGVyGAIgASgDUgVvcm'
        'RlchIOCgJpZBgDIAEoA1ICaWQSFAoFZmxhZ3MYZCABKANSBWZsYWdzEhkKB3ZlcnNpb24Y2QQg'
        'ASgDUgd2ZXJzaW9uEhEKA3VpZBjaBCABKANSA3VpZBInCg5sYXN0TW9kaWZpZWRBdBjbBCABKA'
        'NSDmxhc3RNb2RpZmllZEF0');

@$core.Deprecated('Use backupChapterDescriptor instead')
const BackupChapter$json = {
  '1': 'BackupChapter',
  '2': [
    {'1': 'url', '3': 1, '4': 1, '5': 9, '10': 'url'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'scanlator', '3': 3, '4': 1, '5': 9, '10': 'scanlator'},
    {'1': 'read', '3': 4, '4': 1, '5': 8, '10': 'read'},
    {'1': 'bookmark', '3': 5, '4': 1, '5': 8, '10': 'bookmark'},
    {'1': 'lastPageRead', '3': 6, '4': 1, '5': 3, '10': 'lastPageRead'},
    {'1': 'dateFetch', '3': 7, '4': 1, '5': 3, '10': 'dateFetch'},
    {'1': 'dateUpload', '3': 8, '4': 1, '5': 3, '10': 'dateUpload'},
    {'1': 'chapterNumber', '3': 9, '4': 1, '5': 2, '10': 'chapterNumber'},
    {'1': 'sourceOrder', '3': 10, '4': 1, '5': 3, '10': 'sourceOrder'},
    {'1': 'lastModifiedAt', '3': 11, '4': 1, '5': 3, '10': 'lastModifiedAt'},
    {'1': 'version', '3': 12, '4': 1, '5': 3, '10': 'version'},
    {'1': 'memo', '3': 13, '4': 1, '5': 12, '10': 'memo'},
  ],
};

/// Descriptor for `BackupChapter`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupChapterDescriptor =
    $convert.base64Decode('Cg1CYWNrdXBDaGFwdGVyEhAKA3VybBgBIAEoCVIDdXJsEhIKBG5hbWUYAiABKAlSBG5hbWUSHA'
        'oJc2NhbmxhdG9yGAMgASgJUglzY2FubGF0b3ISEgoEcmVhZBgEIAEoCFIEcmVhZBIaCghib29r'
        'bWFyaxgFIAEoCFIIYm9va21hcmsSIgoMbGFzdFBhZ2VSZWFkGAYgASgDUgxsYXN0UGFnZVJlYW'
        'QSHAoJZGF0ZUZldGNoGAcgASgDUglkYXRlRmV0Y2gSHgoKZGF0ZVVwbG9hZBgIIAEoA1IKZGF0'
        'ZVVwbG9hZBIkCg1jaGFwdGVyTnVtYmVyGAkgASgCUg1jaGFwdGVyTnVtYmVyEiAKC3NvdXJjZU'
        '9yZGVyGAogASgDUgtzb3VyY2VPcmRlchImCg5sYXN0TW9kaWZpZWRBdBgLIAEoA1IObGFzdE1v'
        'ZGlmaWVkQXQSGAoHdmVyc2lvbhgMIAEoA1IHdmVyc2lvbhISCgRtZW1vGA0gASgMUgRtZW1v');

@$core.Deprecated('Use backupExtensionStoreDescriptor instead')
const BackupExtensionStore$json = {
  '1': 'BackupExtensionStore',
  '2': [
    {'1': 'indexUrl', '3': 1, '4': 1, '5': 9, '10': 'indexUrl'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'badgeLabel', '3': 3, '4': 1, '5': 9, '10': 'badgeLabel'},
    {'1': 'signingKey', '3': 5, '4': 1, '5': 9, '10': 'signingKey'},
    {'1': 'contactWebsite', '3': 4, '4': 1, '5': 9, '10': 'contactWebsite'},
    {'1': 'contactDiscord', '3': 6, '4': 1, '5': 9, '10': 'contactDiscord'},
    {'1': 'isLegacy', '3': 7, '4': 1, '5': 8, '10': 'isLegacy'},
    {'1': 'extensionListUrl', '3': 8, '4': 1, '5': 9, '10': 'extensionListUrl'},
  ],
};

/// Descriptor for `BackupExtensionStore`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupExtensionStoreDescriptor =
    $convert.base64Decode('ChRCYWNrdXBFeHRlbnNpb25TdG9yZRIaCghpbmRleFVybBgBIAEoCVIIaW5kZXhVcmwSEgoEbm'
        'FtZRgCIAEoCVIEbmFtZRIeCgpiYWRnZUxhYmVsGAMgASgJUgpiYWRnZUxhYmVsEh4KCnNpZ25p'
        'bmdLZXkYBSABKAlSCnNpZ25pbmdLZXkSJgoOY29udGFjdFdlYnNpdGUYBCABKAlSDmNvbnRhY3'
        'RXZWJzaXRlEiYKDmNvbnRhY3REaXNjb3JkGAYgASgJUg5jb250YWN0RGlzY29yZBIaCghpc0xl'
        'Z2FjeRgHIAEoCFIIaXNMZWdhY3kSKgoQZXh0ZW5zaW9uTGlzdFVybBgIIAEoCVIQZXh0ZW5zaW'
        '9uTGlzdFVybA==');

@$core.Deprecated('Use backupFeedDescriptor instead')
const BackupFeed$json = {
  '1': 'BackupFeed',
  '2': [
    {'1': 'source', '3': 1, '4': 1, '5': 3, '10': 'source'},
    {'1': 'global', '3': 2, '4': 1, '5': 8, '10': 'global'},
    {'1': 'savedSearchName', '3': 3, '4': 1, '5': 9, '10': 'savedSearchName'},
  ],
};

/// Descriptor for `BackupFeed`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupFeedDescriptor =
    $convert.base64Decode('CgpCYWNrdXBGZWVkEhYKBnNvdXJjZRgBIAEoA1IGc291cmNlEhYKBmdsb2JhbBgCIAEoCFIGZ2'
        'xvYmFsEigKD3NhdmVkU2VhcmNoTmFtZRgDIAEoCVIPc2F2ZWRTZWFyY2hOYW1l');

@$core.Deprecated('Use backupFlatMetadataDescriptor instead')
const BackupFlatMetadata$json = {
  '1': 'BackupFlatMetadata',
  '2': [
    {'1': 'searchMetadata', '3': 1, '4': 1, '5': 11, '6': '.BackupSearchMetadata', '10': 'searchMetadata'},
    {'1': 'searchTags', '3': 2, '4': 3, '5': 11, '6': '.BackupSearchTag', '10': 'searchTags'},
    {'1': 'searchTitles', '3': 3, '4': 3, '5': 11, '6': '.BackupSearchTitle', '10': 'searchTitles'},
  ],
};

/// Descriptor for `BackupFlatMetadata`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupFlatMetadataDescriptor =
    $convert.base64Decode('ChJCYWNrdXBGbGF0TWV0YWRhdGESPQoOc2VhcmNoTWV0YWRhdGEYASABKAsyFS5CYWNrdXBTZW'
        'FyY2hNZXRhZGF0YVIOc2VhcmNoTWV0YWRhdGESMAoKc2VhcmNoVGFncxgCIAMoCzIQLkJhY2t1'
        'cFNlYXJjaFRhZ1IKc2VhcmNoVGFncxI2CgxzZWFyY2hUaXRsZXMYAyADKAsyEi5CYWNrdXBTZW'
        'FyY2hUaXRsZVIMc2VhcmNoVGl0bGVz');

@$core.Deprecated('Use backupHistoryDescriptor instead')
const BackupHistory$json = {
  '1': 'BackupHistory',
  '2': [
    {'1': 'url', '3': 1, '4': 1, '5': 9, '10': 'url'},
    {'1': 'lastRead', '3': 2, '4': 1, '5': 3, '10': 'lastRead'},
    {'1': 'readDuration', '3': 3, '4': 1, '5': 3, '10': 'readDuration'},
  ],
};

/// Descriptor for `BackupHistory`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupHistoryDescriptor =
    $convert.base64Decode('Cg1CYWNrdXBIaXN0b3J5EhAKA3VybBgBIAEoCVIDdXJsEhoKCGxhc3RSZWFkGAIgASgDUghsYX'
        'N0UmVhZBIiCgxyZWFkRHVyYXRpb24YAyABKANSDHJlYWREdXJhdGlvbg==');

@$core.Deprecated('Use backupMangaDescriptor instead')
const BackupManga$json = {
  '1': 'BackupManga',
  '2': [
    {'1': 'source', '3': 1, '4': 1, '5': 3, '10': 'source'},
    {'1': 'url', '3': 2, '4': 1, '5': 9, '10': 'url'},
    {'1': 'title', '3': 3, '4': 1, '5': 9, '10': 'title'},
    {'1': 'artist', '3': 4, '4': 1, '5': 9, '10': 'artist'},
    {'1': 'author', '3': 5, '4': 1, '5': 9, '10': 'author'},
    {'1': 'description', '3': 6, '4': 1, '5': 9, '10': 'description'},
    {'1': 'genre', '3': 7, '4': 3, '5': 9, '10': 'genre'},
    {'1': 'status', '3': 8, '4': 1, '5': 5, '10': 'status'},
    {'1': 'thumbnailUrl', '3': 9, '4': 1, '5': 9, '10': 'thumbnailUrl'},
    {'1': 'dateAdded', '3': 13, '4': 1, '5': 3, '10': 'dateAdded'},
    {'1': 'viewer', '3': 14, '4': 1, '5': 5, '10': 'viewer'},
    {'1': 'chapters', '3': 16, '4': 3, '5': 11, '6': '.BackupChapter', '10': 'chapters'},
    {'1': 'categories', '3': 17, '4': 3, '5': 3, '10': 'categories'},
    {'1': 'tracking', '3': 18, '4': 3, '5': 11, '6': '.BackupTracking', '10': 'tracking'},
    {'1': 'favorite', '3': 100, '4': 1, '5': 8, '10': 'favorite'},
    {'1': 'chapterFlags', '3': 101, '4': 1, '5': 5, '10': 'chapterFlags'},
    {'1': 'viewer_flags', '3': 103, '4': 1, '5': 5, '10': 'viewerFlags'},
    {'1': 'history', '3': 104, '4': 3, '5': 11, '6': '.BackupHistory', '10': 'history'},
    {'1': 'updateStrategy', '3': 105, '4': 1, '5': 14, '6': '.UpdateStrategy', '10': 'updateStrategy'},
    {'1': 'lastModifiedAt', '3': 106, '4': 1, '5': 3, '10': 'lastModifiedAt'},
    {'1': 'favoriteModifiedAt', '3': 107, '4': 1, '5': 3, '10': 'favoriteModifiedAt'},
    {'1': 'excludedScanlators', '3': 108, '4': 3, '5': 9, '10': 'excludedScanlators'},
    {'1': 'version', '3': 109, '4': 1, '5': 3, '10': 'version'},
    {'1': 'notes', '3': 110, '4': 1, '5': 9, '10': 'notes'},
    {'1': 'initialized', '3': 111, '4': 1, '5': 8, '10': 'initialized'},
    {'1': 'memo', '3': 112, '4': 1, '5': 12, '10': 'memo'},
    {'1': 'nextUpdate', '3': 113, '4': 1, '5': 3, '10': 'nextUpdate'},
    {'1': 'mergedEntries', '3': 600, '4': 3, '5': 11, '6': '.BackupMergedEntry', '10': 'mergedEntries'},
    {'1': 'flatMetadata', '3': 601, '4': 1, '5': 11, '6': '.BackupFlatMetadata', '10': 'flatMetadata'},
    {'1': 'customStatus', '3': 602, '4': 1, '5': 5, '10': 'customStatus'},
    {'1': 'customThumbnailUrl', '3': 603, '4': 1, '5': 9, '10': 'customThumbnailUrl'},
    {'1': 'mergeSettings', '3': 604, '4': 1, '5': 11, '6': '.BackupMergeSettings', '10': 'mergeSettings'},
    {'1': 'customTitle', '3': 800, '4': 1, '5': 9, '10': 'customTitle'},
    {'1': 'customArtist', '3': 801, '4': 1, '5': 9, '10': 'customArtist'},
    {'1': 'customAuthor', '3': 802, '4': 1, '5': 9, '10': 'customAuthor'},
    {'1': 'customDescription', '3': 804, '4': 1, '5': 9, '10': 'customDescription'},
    {'1': 'customGenre', '3': 805, '4': 3, '5': 9, '10': 'customGenre'},
  ],
};

/// Descriptor for `BackupManga`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupMangaDescriptor =
    $convert.base64Decode('CgtCYWNrdXBNYW5nYRIWCgZzb3VyY2UYASABKANSBnNvdXJjZRIQCgN1cmwYAiABKAlSA3VybB'
        'IUCgV0aXRsZRgDIAEoCVIFdGl0bGUSFgoGYXJ0aXN0GAQgASgJUgZhcnRpc3QSFgoGYXV0aG9y'
        'GAUgASgJUgZhdXRob3ISIAoLZGVzY3JpcHRpb24YBiABKAlSC2Rlc2NyaXB0aW9uEhQKBWdlbn'
        'JlGAcgAygJUgVnZW5yZRIWCgZzdGF0dXMYCCABKAVSBnN0YXR1cxIiCgx0aHVtYm5haWxVcmwY'
        'CSABKAlSDHRodW1ibmFpbFVybBIcCglkYXRlQWRkZWQYDSABKANSCWRhdGVBZGRlZBIWCgZ2aW'
        'V3ZXIYDiABKAVSBnZpZXdlchIqCghjaGFwdGVycxgQIAMoCzIOLkJhY2t1cENoYXB0ZXJSCGNo'
        'YXB0ZXJzEh4KCmNhdGVnb3JpZXMYESADKANSCmNhdGVnb3JpZXMSKwoIdHJhY2tpbmcYEiADKA'
        'syDy5CYWNrdXBUcmFja2luZ1IIdHJhY2tpbmcSGgoIZmF2b3JpdGUYZCABKAhSCGZhdm9yaXRl'
        'EiIKDGNoYXB0ZXJGbGFncxhlIAEoBVIMY2hhcHRlckZsYWdzEiEKDHZpZXdlcl9mbGFncxhnIA'
        'EoBVILdmlld2VyRmxhZ3MSKAoHaGlzdG9yeRhoIAMoCzIOLkJhY2t1cEhpc3RvcnlSB2hpc3Rv'
        'cnkSNwoOdXBkYXRlU3RyYXRlZ3kYaSABKA4yDy5VcGRhdGVTdHJhdGVneVIOdXBkYXRlU3RyYX'
        'RlZ3kSJgoObGFzdE1vZGlmaWVkQXQYaiABKANSDmxhc3RNb2RpZmllZEF0Ei4KEmZhdm9yaXRl'
        'TW9kaWZpZWRBdBhrIAEoA1ISZmF2b3JpdGVNb2RpZmllZEF0Ei4KEmV4Y2x1ZGVkU2NhbmxhdG'
        '9ycxhsIAMoCVISZXhjbHVkZWRTY2FubGF0b3JzEhgKB3ZlcnNpb24YbSABKANSB3ZlcnNpb24S'
        'FAoFbm90ZXMYbiABKAlSBW5vdGVzEiAKC2luaXRpYWxpemVkGG8gASgIUgtpbml0aWFsaXplZB'
        'ISCgRtZW1vGHAgASgMUgRtZW1vEh4KCm5leHRVcGRhdGUYcSABKANSCm5leHRVcGRhdGUSOQoN'
        'bWVyZ2VkRW50cmllcxjYBCADKAsyEi5CYWNrdXBNZXJnZWRFbnRyeVINbWVyZ2VkRW50cmllcx'
        'I4CgxmbGF0TWV0YWRhdGEY2QQgASgLMhMuQmFja3VwRmxhdE1ldGFkYXRhUgxmbGF0TWV0YWRh'
        'dGESIwoMY3VzdG9tU3RhdHVzGNoEIAEoBVIMY3VzdG9tU3RhdHVzEi8KEmN1c3RvbVRodW1ibm'
        'FpbFVybBjbBCABKAlSEmN1c3RvbVRodW1ibmFpbFVybBI7Cg1tZXJnZVNldHRpbmdzGNwEIAEo'
        'CzIULkJhY2t1cE1lcmdlU2V0dGluZ3NSDW1lcmdlU2V0dGluZ3MSIQoLY3VzdG9tVGl0bGUYoA'
        'YgASgJUgtjdXN0b21UaXRsZRIjCgxjdXN0b21BcnRpc3QYoQYgASgJUgxjdXN0b21BcnRpc3QS'
        'IwoMY3VzdG9tQXV0aG9yGKIGIAEoCVIMY3VzdG9tQXV0aG9yEi0KEWN1c3RvbURlc2NyaXB0aW'
        '9uGKQGIAEoCVIRY3VzdG9tRGVzY3JpcHRpb24SIQoLY3VzdG9tR2VucmUYpQYgAygJUgtjdXN0'
        'b21HZW5yZQ==');

@$core.Deprecated('Use backupMergedEntryDescriptor instead')
const BackupMergedEntry$json = {
  '1': 'BackupMergedEntry',
  '2': [
    {'1': 'isInfoManga', '3': 1, '4': 1, '5': 8, '10': 'isInfoManga'},
    {'1': 'fetchChapterUpdates', '3': 2, '4': 1, '5': 8, '10': 'fetchChapterUpdates'},
    {'1': 'chapterSortMode', '3': 3, '4': 1, '5': 5, '10': 'chapterSortMode'},
    {'1': 'chapterPriority', '3': 4, '4': 1, '5': 5, '10': 'chapterPriority'},
    {'1': 'downloadChapters', '3': 5, '4': 1, '5': 8, '10': 'downloadChapters'},
    {'1': 'mangaUrl', '3': 7, '4': 1, '5': 9, '10': 'mangaUrl'},
    {'1': 'mangaSourceId', '3': 8, '4': 1, '5': 3, '10': 'mangaSourceId'},
  ],
};

/// Descriptor for `BackupMergedEntry`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupMergedEntryDescriptor =
    $convert.base64Decode('ChFCYWNrdXBNZXJnZWRFbnRyeRIgCgtpc0luZm9NYW5nYRgBIAEoCFILaXNJbmZvTWFuZ2ESMA'
        'oTZmV0Y2hDaGFwdGVyVXBkYXRlcxgCIAEoCFITZmV0Y2hDaGFwdGVyVXBkYXRlcxIoCg9jaGFw'
        'dGVyU29ydE1vZGUYAyABKAVSD2NoYXB0ZXJTb3J0TW9kZRIoCg9jaGFwdGVyUHJpb3JpdHkYBC'
        'ABKAVSD2NoYXB0ZXJQcmlvcml0eRIqChBkb3dubG9hZENoYXB0ZXJzGAUgASgIUhBkb3dubG9h'
        'ZENoYXB0ZXJzEhoKCG1hbmdhVXJsGAcgASgJUghtYW5nYVVybBIkCg1tYW5nYVNvdXJjZUlkGA'
        'ggASgDUg1tYW5nYVNvdXJjZUlk');

@$core.Deprecated('Use backupMergeSettingsDescriptor instead')
const BackupMergeSettings$json = {
  '1': 'BackupMergeSettings',
  '2': [
    {'1': 'chapterSortMode', '3': 1, '4': 1, '5': 5, '10': 'chapterSortMode'},
    {'1': 'infoMangaUrl', '3': 2, '4': 1, '5': 9, '10': 'infoMangaUrl'},
    {'1': 'infoMangaSourceId', '3': 3, '4': 1, '5': 3, '10': 'infoMangaSourceId'},
  ],
};

/// Descriptor for `BackupMergeSettings`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupMergeSettingsDescriptor =
    $convert.base64Decode('ChNCYWNrdXBNZXJnZVNldHRpbmdzEigKD2NoYXB0ZXJTb3J0TW9kZRgBIAEoBVIPY2hhcHRlcl'
        'NvcnRNb2RlEiIKDGluZm9NYW5nYVVybBgCIAEoCVIMaW5mb01hbmdhVXJsEiwKEWluZm9NYW5n'
        'YVNvdXJjZUlkGAMgASgDUhFpbmZvTWFuZ2FTb3VyY2VJZA==');

@$core.Deprecated('Use backupPreferenceDescriptor instead')
const BackupPreference$json = {
  '1': 'BackupPreference',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'value', '3': 2, '4': 2, '5': 11, '6': '.PreferenceValue', '10': 'value'},
  ],
};

/// Descriptor for `BackupPreference`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupPreferenceDescriptor =
    $convert.base64Decode('ChBCYWNrdXBQcmVmZXJlbmNlEhAKA2tleRgBIAEoCVIDa2V5EiYKBXZhbHVlGAIgAigLMhAuUH'
        'JlZmVyZW5jZVZhbHVlUgV2YWx1ZQ==');

@$core.Deprecated('Use backupSourcePreferencesDescriptor instead')
const BackupSourcePreferences$json = {
  '1': 'BackupSourcePreferences',
  '2': [
    {'1': 'sourceKey', '3': 1, '4': 1, '5': 9, '10': 'sourceKey'},
    {'1': 'prefs', '3': 2, '4': 3, '5': 11, '6': '.BackupPreference', '10': 'prefs'},
  ],
};

/// Descriptor for `BackupSourcePreferences`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupSourcePreferencesDescriptor =
    $convert.base64Decode('ChdCYWNrdXBTb3VyY2VQcmVmZXJlbmNlcxIcCglzb3VyY2VLZXkYASABKAlSCXNvdXJjZUtleR'
        'InCgVwcmVmcxgCIAMoCzIRLkJhY2t1cFByZWZlcmVuY2VSBXByZWZz');

@$core.Deprecated('Use intPreferenceValueDescriptor instead')
const IntPreferenceValue$json = {
  '1': 'IntPreferenceValue',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 5, '10': 'value'},
  ],
};

/// Descriptor for `IntPreferenceValue`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List intPreferenceValueDescriptor =
    $convert.base64Decode('ChJJbnRQcmVmZXJlbmNlVmFsdWUSFAoFdmFsdWUYASABKAVSBXZhbHVl');

@$core.Deprecated('Use longPreferenceValueDescriptor instead')
const LongPreferenceValue$json = {
  '1': 'LongPreferenceValue',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 3, '10': 'value'},
  ],
};

/// Descriptor for `LongPreferenceValue`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List longPreferenceValueDescriptor =
    $convert.base64Decode('ChNMb25nUHJlZmVyZW5jZVZhbHVlEhQKBXZhbHVlGAEgASgDUgV2YWx1ZQ==');

@$core.Deprecated('Use floatPreferenceValueDescriptor instead')
const FloatPreferenceValue$json = {
  '1': 'FloatPreferenceValue',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 2, '10': 'value'},
  ],
};

/// Descriptor for `FloatPreferenceValue`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List floatPreferenceValueDescriptor =
    $convert.base64Decode('ChRGbG9hdFByZWZlcmVuY2VWYWx1ZRIUCgV2YWx1ZRgBIAEoAlIFdmFsdWU=');

@$core.Deprecated('Use stringPreferenceValueDescriptor instead')
const StringPreferenceValue$json = {
  '1': 'StringPreferenceValue',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 9, '10': 'value'},
  ],
};

/// Descriptor for `StringPreferenceValue`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List stringPreferenceValueDescriptor =
    $convert.base64Decode('ChVTdHJpbmdQcmVmZXJlbmNlVmFsdWUSFAoFdmFsdWUYASABKAlSBXZhbHVl');

@$core.Deprecated('Use booleanPreferenceValueDescriptor instead')
const BooleanPreferenceValue$json = {
  '1': 'BooleanPreferenceValue',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 8, '10': 'value'},
  ],
};

/// Descriptor for `BooleanPreferenceValue`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List booleanPreferenceValueDescriptor =
    $convert.base64Decode('ChZCb29sZWFuUHJlZmVyZW5jZVZhbHVlEhQKBXZhbHVlGAEgASgIUgV2YWx1ZQ==');

@$core.Deprecated('Use stringSetPreferenceValueDescriptor instead')
const StringSetPreferenceValue$json = {
  '1': 'StringSetPreferenceValue',
  '2': [
    {'1': 'value', '3': 1, '4': 3, '5': 9, '10': 'value'},
  ],
};

/// Descriptor for `StringSetPreferenceValue`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List stringSetPreferenceValueDescriptor =
    $convert.base64Decode('ChhTdHJpbmdTZXRQcmVmZXJlbmNlVmFsdWUSFAoFdmFsdWUYASADKAlSBXZhbHVl');

@$core.Deprecated('Use backupSavedSearchDescriptor instead')
const BackupSavedSearch$json = {
  '1': 'BackupSavedSearch',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'query', '3': 2, '4': 1, '5': 9, '10': 'query'},
    {'1': 'filterList', '3': 3, '4': 1, '5': 9, '10': 'filterList'},
    {'1': 'source', '3': 4, '4': 1, '5': 3, '10': 'source'},
  ],
};

/// Descriptor for `BackupSavedSearch`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupSavedSearchDescriptor =
    $convert.base64Decode('ChFCYWNrdXBTYXZlZFNlYXJjaBISCgRuYW1lGAEgASgJUgRuYW1lEhQKBXF1ZXJ5GAIgASgJUg'
        'VxdWVyeRIeCgpmaWx0ZXJMaXN0GAMgASgJUgpmaWx0ZXJMaXN0EhYKBnNvdXJjZRgEIAEoA1IG'
        'c291cmNl');

@$core.Deprecated('Use backupSourceDescriptor instead')
const BackupSource$json = {
  '1': 'BackupSource',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'sourceId', '3': 2, '4': 1, '5': 3, '10': 'sourceId'},
  ],
};

/// Descriptor for `BackupSource`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupSourceDescriptor =
    $convert.base64Decode('CgxCYWNrdXBTb3VyY2USEgoEbmFtZRgBIAEoCVIEbmFtZRIaCghzb3VyY2VJZBgCIAEoA1IIc2'
        '91cmNlSWQ=');

@$core.Deprecated('Use backupTrackingDescriptor instead')
const BackupTracking$json = {
  '1': 'BackupTracking',
  '2': [
    {'1': 'syncId', '3': 1, '4': 1, '5': 5, '10': 'syncId'},
    {'1': 'libraryId', '3': 2, '4': 1, '5': 3, '10': 'libraryId'},
    {'1': 'mediaIdInt', '3': 3, '4': 1, '5': 5, '10': 'mediaIdInt'},
    {'1': 'trackingUrl', '3': 4, '4': 1, '5': 9, '10': 'trackingUrl'},
    {'1': 'title', '3': 5, '4': 1, '5': 9, '10': 'title'},
    {'1': 'lastChapterRead', '3': 6, '4': 1, '5': 2, '10': 'lastChapterRead'},
    {'1': 'totalChapters', '3': 7, '4': 1, '5': 5, '10': 'totalChapters'},
    {'1': 'score', '3': 8, '4': 1, '5': 2, '10': 'score'},
    {'1': 'status', '3': 9, '4': 1, '5': 5, '10': 'status'},
    {'1': 'startedReadingDate', '3': 10, '4': 1, '5': 3, '10': 'startedReadingDate'},
    {'1': 'finishedReadingDate', '3': 11, '4': 1, '5': 3, '10': 'finishedReadingDate'},
    {'1': 'private', '3': 12, '4': 1, '5': 8, '10': 'private'},
    {'1': 'mediaId', '3': 100, '4': 1, '5': 3, '10': 'mediaId'},
  ],
};

/// Descriptor for `BackupTracking`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupTrackingDescriptor =
    $convert.base64Decode('Cg5CYWNrdXBUcmFja2luZxIWCgZzeW5jSWQYASABKAVSBnN5bmNJZBIcCglsaWJyYXJ5SWQYAi'
        'ABKANSCWxpYnJhcnlJZBIeCgptZWRpYUlkSW50GAMgASgFUgptZWRpYUlkSW50EiAKC3RyYWNr'
        'aW5nVXJsGAQgASgJUgt0cmFja2luZ1VybBIUCgV0aXRsZRgFIAEoCVIFdGl0bGUSKAoPbGFzdE'
        'NoYXB0ZXJSZWFkGAYgASgCUg9sYXN0Q2hhcHRlclJlYWQSJAoNdG90YWxDaGFwdGVycxgHIAEo'
        'BVINdG90YWxDaGFwdGVycxIUCgVzY29yZRgIIAEoAlIFc2NvcmUSFgoGc3RhdHVzGAkgASgFUg'
        'ZzdGF0dXMSLgoSc3RhcnRlZFJlYWRpbmdEYXRlGAogASgDUhJzdGFydGVkUmVhZGluZ0RhdGUS'
        'MAoTZmluaXNoZWRSZWFkaW5nRGF0ZRgLIAEoA1ITZmluaXNoZWRSZWFkaW5nRGF0ZRIYCgdwcm'
        'l2YXRlGAwgASgIUgdwcml2YXRlEhgKB21lZGlhSWQYZCABKANSB21lZGlhSWQ=');

@$core.Deprecated('Use backupSearchMetadataDescriptor instead')
const BackupSearchMetadata$json = {
  '1': 'BackupSearchMetadata',
  '2': [
    {'1': 'uploader', '3': 1, '4': 1, '5': 9, '10': 'uploader'},
    {'1': 'extra', '3': 2, '4': 1, '5': 9, '10': 'extra'},
    {'1': 'indexedExtra', '3': 3, '4': 1, '5': 9, '10': 'indexedExtra'},
    {'1': 'extraVersion', '3': 4, '4': 1, '5': 5, '10': 'extraVersion'},
  ],
};

/// Descriptor for `BackupSearchMetadata`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupSearchMetadataDescriptor =
    $convert.base64Decode('ChRCYWNrdXBTZWFyY2hNZXRhZGF0YRIaCgh1cGxvYWRlchgBIAEoCVIIdXBsb2FkZXISFAoFZX'
        'h0cmEYAiABKAlSBWV4dHJhEiIKDGluZGV4ZWRFeHRyYRgDIAEoCVIMaW5kZXhlZEV4dHJhEiIK'
        'DGV4dHJhVmVyc2lvbhgEIAEoBVIMZXh0cmFWZXJzaW9u');

@$core.Deprecated('Use backupSearchTagDescriptor instead')
const BackupSearchTag$json = {
  '1': 'BackupSearchTag',
  '2': [
    {'1': 'namespace', '3': 1, '4': 1, '5': 9, '10': 'namespace'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'type', '3': 3, '4': 1, '5': 5, '10': 'type'},
  ],
};

/// Descriptor for `BackupSearchTag`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupSearchTagDescriptor =
    $convert.base64Decode('Cg9CYWNrdXBTZWFyY2hUYWcSHAoJbmFtZXNwYWNlGAEgASgJUgluYW1lc3BhY2USEgoEbmFtZR'
        'gCIAEoCVIEbmFtZRISCgR0eXBlGAMgASgFUgR0eXBl');

@$core.Deprecated('Use backupSearchTitleDescriptor instead')
const BackupSearchTitle$json = {
  '1': 'BackupSearchTitle',
  '2': [
    {'1': 'title', '3': 1, '4': 1, '5': 9, '10': 'title'},
    {'1': 'type', '3': 2, '4': 1, '5': 5, '10': 'type'},
  ],
};

/// Descriptor for `BackupSearchTitle`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List backupSearchTitleDescriptor =
    $convert.base64Decode('ChFCYWNrdXBTZWFyY2hUaXRsZRIUCgV0aXRsZRgBIAEoCVIFdGl0bGUSEgoEdHlwZRgCIAEoBV'
        'IEdHlwZQ==');
