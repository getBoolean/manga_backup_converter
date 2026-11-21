/// Tachi extensions for the conversion pipeline (U4; KTD3, KTD5).
///
/// - Catalogs: `repo.json` → live `index.json` (never `index.min.json`),
///   repository package IDs kept apart from runtime source IDs.
/// - Artifacts: JAR when published, APK otherwise, with per-repository and
///   per-package overrides; downloads are admitted to the content-addressed
///   cache and verified by the worker's `artifact.prepare` against the
///   approved repository fingerprint.
/// - Runtime: package-level loading over the conversion's single JVM worker;
///   a package's sessions share one hosted copy, unloaded when the last
///   session closes.
library;

export 'src/artifact_store.dart';
export 'src/catalog.dart';
export 'src/desktop_worker.dart';
export 'src/tachi_runtime.dart';
