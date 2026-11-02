import 'package:dart_mappable/dart_mappable.dart';
import 'package:mangabackupconverter_cli/src/proto/schema_mihon.proto/proto/schema_mihon.pb.dart' as mihon;
import 'package:mangabackupconverter_cli/src/proto/schema_sy.proto/proto/schema_sy.pb.dart' as sy;

part 'tachi_backup_extension_repo.mapper.dart';

@MappableClass()
class TachiBackupExtensionRepo with TachiBackupExtensionRepoMappable {
  final String name;
  final String baseUrl;
  final String shortName;
  final String website;
  final String signingKeyFingerprint;

  const TachiBackupExtensionRepo({
    required this.name,
    required this.baseUrl,
    required this.shortName,
    required this.website,
    required this.signingKeyFingerprint,
  });

  /// Mihon renamed `BackupExtensionRepos` to `BackupExtensionStore`; field
  /// numbers are unchanged, so older backups decode into the same fields.
  factory TachiBackupExtensionRepo.fromMihon(mihon.BackupExtensionStore backupExtensionStore) {
    return TachiBackupExtensionRepo(
      name: backupExtensionStore.name,
      baseUrl: backupExtensionStore.indexUrl,
      shortName: backupExtensionStore.badgeLabel,
      website: backupExtensionStore.contactWebsite,
      signingKeyFingerprint: backupExtensionStore.signingKey,
    );
  }

  /// See [TachiBackupExtensionRepo.fromMihon]; SY followed the same rename.
  factory TachiBackupExtensionRepo.fromSy(sy.BackupExtensionStore backupExtensionStore) {
    return TachiBackupExtensionRepo(
      name: backupExtensionStore.name,
      baseUrl: backupExtensionStore.indexUrl,
      shortName: backupExtensionStore.badgeLabel,
      website: backupExtensionStore.contactWebsite,
      signingKeyFingerprint: backupExtensionStore.signingKey,
    );
  }

  static const TachiBackupExtensionRepo Function(Map<String, dynamic> map) fromMap =
      TachiBackupExtensionRepoMapper.fromMap;
  static const TachiBackupExtensionRepo Function(String json) fromJson = TachiBackupExtensionRepoMapper.fromJson;
}
