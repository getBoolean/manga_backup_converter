# Golden wire vectors

JSON written by the Dart tests from the Dart encoders, which are the source of
truth for every cross-language format, and read back by the other
implementations' tests. Never edit these files by hand: regenerate them and
commit the result.

| File | Written by | Checked by |
|---|---|---|
| `worker_protocol.json` | `packages/source_runtime/test/wire_vectors_test.dart` (`ProtocolFrame` and `protocol_payloads.dart` `toJson`) | `tools/tachi-source-runner/src/test/kotlin/WireVectorsTest.kt`: each frame parses, each payload decodes into the worker's type named by `payloadType` and re-encodes to the same JSON |
| `capture.json` | the same Dart test (`CaptureKey.canonicalUrl`, `parseSetCookieHeader`, `CaptureManifest.toJson`) | the same Kotlin test, against `CaptureFormat.kt`; known divergences are listed there |
| `constants.json` | the same Dart test | the Kotlin test (frame limit, protocol version and minor, recorded response headers, capture format, the `WorkerOperation` and `HostBrowserOperation` tables) and the Rust helper (`hostBrowserMaxForwardedBodyBytes`) |
| `helper_protocol.json` | `packages/desktop_webview/test/helper_wire_test.dart`: the requests `DesktopBrowserPort` writes to a scripted helper, and the events it reads | `packages/desktop_webview/helper/src/wire.rs` tests: each command decodes into `Command` and re-encodes; each event round-trips through `Event`; the helper's frame limit and protocol version |

Helper events flow Rust to Dart and have no Dart `toJson`: the Dart test owns
their JSON, checks that `DesktopBrowserPort` reads each one as intended, and the
Rust test checks that `Event` produces exactly that JSON.

**Comparison rule:** an absent key and a `null` value are the same (Dart's
`toJson` writes `null` fields; other encoders may leave them out). Key order
does not matter.

**Regenerate:**

```bash
UPDATE_WIRE_VECTORS=1 flutter test packages/source_runtime/test/wire_vectors_test.dart
UPDATE_WIRE_VECTORS=1 flutter test packages/desktop_webview/test/helper_wire_test.dart
```

Without the variable the Dart tests fail when a committed file no longer
matches what the encoders write.
