import 'dart:io';

import 'package:source_runtime/source_runtime.dart';

/// Replay client over `fixtures/source_captures/aidoku/<source>/`.
///
/// Tests never reach a server: a request without a committed capture fails
/// and is recorded in [ReplayHttpClient.misses]. Re-record with
/// `dart run tool/capture_source_fixtures.dart aidoku <source> --min-interval-ms=<n>`.
ReplayHttpClient aidokuReplayClient(String source) {
  final Directory? dir = findCaptureDir('aidoku', source);
  if (dir == null) {
    throw StateError('Missing committed captures: fixtures/source_captures/aidoku/$source');
  }
  return ReplayHttpClient(loadCaptureSet(dir));
}
