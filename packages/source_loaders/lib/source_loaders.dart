/// `PluginLoader` adapters over the Aidoku, Paperback and Tachi source
/// providers (KTD15), shared by every composition root. The roots inject the
/// concrete backends; nothing here names an extension or a repository.
library;

export 'src/aidoku_loader.dart';
export 'src/bytes_artifact.dart';
export 'src/paperback_loader.dart';
export 'src/provider_plugin_loader.dart';
export 'src/tachi_loader.dart';
