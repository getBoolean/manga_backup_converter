/// Desktop source runtime infrastructure (KTD3, KTD4, KTD9).
///
/// Re-exports the backend-neutral contracts and adds `dart:io` backends:
/// the worker protocol, the supervisor with injected process launch, the
/// conversion-scoped owner, the artifact cache, the browser reverse bridge,
/// redaction, and capture record/replay. Composition roots select this
/// explicitly; contract consumers import `source_contracts.dart` only.
library;

export 'source_contracts.dart';
export 'src/backends/artifact_cache.dart';
export 'src/backends/browser_reverse_bridge.dart';
export 'src/backends/protocol.dart';
export 'src/backends/redaction.dart';
export 'src/backends/worker_process.dart';
export 'src/backends/worker_source_session.dart';
export 'src/backends/worker_supervisor.dart';
export 'src/capture/capture_format.dart';
export 'src/capture/capture_http.dart';
