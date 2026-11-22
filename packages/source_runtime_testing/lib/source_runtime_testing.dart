/// Test support for source runtimes: the fake `BrowserPort`, the reusable
/// `BrowserPort` contract suite every platform implementation runs, and the
/// evidence-publication check for qualification receipts.
///
/// Depends on `package:test` and `package:checks`, so it lives outside
/// `source_runtime` and is consumed only as a dev dependency.
library;

export 'src/browser_port_contract.dart';
export 'src/evidence_check.dart';
export 'src/fake_browser_port.dart';
