/// Backend-neutral source and browser contracts (KTD3, KTD12, KTD15, KTD20).
///
/// Web-safe: this library and everything it imports avoid `dart:io`,
/// subprocesses, and concrete engines. Desktop supervision lives in
/// `package:source_runtime/source_runtime.dart`.
library;

export 'src/contracts/background_gate.dart';
export 'src/contracts/browser_port.dart';
export 'src/contracts/cancellation.dart';
export 'src/contracts/identity.dart';
export 'src/contracts/outcome.dart';
export 'src/contracts/source.dart';
