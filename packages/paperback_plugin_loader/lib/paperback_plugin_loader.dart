/// Paperback source host (KTD2, KTD6): per-source QuickJS runtimes with an
/// asynchronous promise bridge and resource limits, and the protocol 1.1
/// desktop worker. The versioned Paperback API adapters arrive in U6.
library;

export 'src/runtime/http_host.dart';
export 'src/runtime/limit_sizing.dart';
export 'src/runtime/promise_bridge.dart' show AsyncHostFunction, HostCallError, PromiseBridge;
export 'src/runtime/quickjs_runtime.dart';
export 'src/runtime/runtime_limits.dart';
export 'src/runtime/settings_scopes.dart';
export 'src/runtime/worker.dart';
