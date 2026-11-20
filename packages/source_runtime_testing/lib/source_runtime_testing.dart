/// Test support for source runtimes: the fake `BrowserPort` and the reusable
/// `BrowserPort` contract suite every platform implementation runs.
///
/// Depends on `package:test` and `package:checks`, so it lives outside
/// `source_runtime` and is consumed only as a dev dependency.
library;

export 'src/browser_port_contract.dart';
export 'src/fake_browser_port.dart';
