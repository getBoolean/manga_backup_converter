/// Test support for the Aidoku host: hand-built `.aix` packages that
/// exercise the isolate boundary (traps, isolate death) and host semantics
/// (response headers, rate limiting) without fixtures or network access.
///
/// Used by this package's tests and by the device integration tests.
library;

export 'src/testing/synthetic_aix.dart';
