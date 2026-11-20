# iOS Tachi source runtime: OpenJDK mobile + Zero (U16, KTD11)

Reproducible build of the embedded, interpreter-only JVM for iPhoneOS and the
iOS simulator, plus the U16 gate fixtures. Outputs go to `build/`
(git-ignored); evidence is in `docs/validation/source-runners/ios/`.

All scripts here are original work. `openjdk-mobile/ios-tools` (AGPL-3.0)
and TachiyomiAZ iOS (GPL-3.0) were read for reference only; nothing is copied
from them.

## Inputs (`manifest.env`)

| Input | Pin |
| --- | --- |
| openjdk/mobile | `ad8bb1b065bf230d193a1dfd0ebd39a8b1fedf53` (JDK 26 line; HEAD fails to link, ios-tools#81) |
| libffi | 3.8.1 release tarball, SHA-256 `81e879c0…57ee40` (matches GitHub's asset digest) |
| Boot JDK | 25 (the pin accepts 24–26) |
| iOS deployment target | 15.0 |
| Runtime modules | `java.base,java.logging,java.xml,jdk.unsupported` |

### Patch set (`patches/`, applied in order by `build_runtime.sh fetch`)

| Patch | Origin and licence | Purpose |
| --- | --- | --- |
| 0001 JDK-8374535 module image path | openjdk/mobile PR 43 (closed unmerged, reviewed), GPLv2 | Modular image (`lib/modules`) loads on iOS; needed for App Store validation |
| 0002 java.home + static native lookup | original, GPLv2 | `java.home` from `JAVA_HOME`; natives resolved via `RTLD_DEFAULT` from the app framework |
| 0003 platform props `macos` | original, GPLv2 | `jdk.internal.util.OperatingSystem` has no IOS constant |
| 0004 Zero back-edge safepoint poll | original, GPLv2 | GC and handshake liveness during call-free loops (KTD11 mechanism B infrastructure) |
| 0005 java.base deadline check | original, GPLv2 + Classpath exception | `jdk.internal.misc.SourceRunnerDeadline` / `SourceRunnerDeadlineError` (mechanism A) |
| 0006 no executable memory | original, GPLv2 | Commit the code cache read/write on iOS; no RWX mappings |

## Prerequisites (macOS, Apple silicon)

- Xcode (tested: 27.2, 27B52) with iPhoneOS and iPhoneSimulator SDKs. The
  script uses only Xcode's clang: it resets `PATH` so user toolchains
  (swiftly, Homebrew LLVM) are not picked up.
- `brew install autoconf make` (installed for this run: autoconf 2.73, GNU
  make 4.4.1).
- A JDK 25 visible to `/usr/libexec/java_home -v 25` (tested: Temurin 25.0.2).
- About 6 GB of disk under `build/`. On an 8-core M-series machine a full
  build takes about 10 minutes.

## Build

```bash
tools/tachi-source-runner/ios/scripts/build_runtime.sh            # all stages
tools/tachi-source-runner/ios/scripts/build_runtime.sh fetch device sim package   # after a patch change
```

Stages: `fetch` (clone the pin, reset, apply patches), `libffi`, `host`
(macOS tools from the same tree: java, javac, jmod, jlink, jimage), `device`,
`sim`, `package`. Outputs per SDK, under `build/out/<iphoneos|iphonesimulator>/`:

- `lib/libsourcejvm.a`: libjvm (Zero) plus libjava, libjimage, libnet,
  libnio, libzip, libverify and libffi, combined.
- `java-home/`: modular image (`lib/modules` from `jmod` + `jlink`),
  `conf/`, `lib/security/`, `lib/tzdb.dat`, and `legal/` (GPL and
  third-party notices).
- `include/`: JNI headers.
- `build/out/outputs.json`: identity (pin, patch hashes, Xcode, boot JDK)
  and artifact SHA-256s. A copy is committed in the validation directory.

The build uses `--with-source-date=<pin commit time>`, `--with-build-user=srt`
and `--with-version-opt=sourcerunner.r<RUNTIME_BUILD_REVISION>`, so no
user or host names end up in version strings.

## Stage into the app

```bash
tools/tachi-source-runner/ios/scripts/stage_runtime.sh iphonesimulator   # or iphoneos for device builds
```

This compiles the gate fixtures (`gate/src`) with the host JDK, runs the
back-edge rewriter (`rewriter/BackedgeRewriter.java`, which uses only
`java.lang.classfile`) over the host library, the extension classes and
`java.util.regex`, and copies everything as flat package assets into
`packages/source_runtime_ios/runtime/` (git-ignored except the README).
`packages/source_runtime_ios/hook/build.dart` links `libsourcejvm.a` into the
`source_runtime_ios` framework whenever the archive exists. Without it, the
dispatcher is built with `SRT_HAS_JVM=0` and reports "not linked".

## Running the gate (simulator)

```bash
flutter test integration_test/ios_runtime_gate_test.dart -d <simulator-udid> \
  --dart-define=SRT_MECHANISM=injected --dart-define=SRT_BACKEDGE_POLL=on      # selected configuration
# measurement runs: SRT_MECHANISM=injected SRT_BACKEDGE_POLL=off; SRT_MECHANISM=stopThread
```

The test prints `SRT_GATE_REPORT {json}` and sets `binding.reportData`. On
this machine, hooks that call `clang` fail when swiftly's clang is first on
`PATH`, so prefix the command with
`env PATH=<flutter-bin>:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
The root app also needs the swiftsoup hook fix described in the validation
README before iOS builds succeed with Xcode 27.

## Distribution-signed build and App Store Connect validation (not done; needs the user)

Uploading for validation is outward-facing and needs the user's explicit
go-ahead. Prerequisites: Apple Developer team ID, an Apple Distribution
certificate in the keychain, an App Store provisioning profile for
`dev.getboolean.mangabackupconverter`, and an App Store Connect app record.

1. `build_runtime.sh` and `stage_runtime.sh iphoneos`. For a shipping build,
   bake the rewritten class-library packages into the image instead of using
   `--patch-module`, and leave the gate fixtures out.
2. Merge `privacy/PrivacyInfo.xcprivacy` into `ios/Runner/PrivacyInfo.xcprivacy`.
3. `flutter build ipa --release --export-method app-store` with signing
   configured (team set in Xcode, or `--export-options-plist` naming the
   team, profile and certificate).
4. Validate only: `xcrun altool --validate-app -f build/ios/ipa/*.ipa -t ios
   --apiKey <key> --apiIssuer <issuer>`, or Xcode Organizer › Validate App.
   Record the result as an R18 receipt.

Checked without signing: `flutter build ios --release --no-codesign` links;
the `source_runtime_ios` framework is arm64, minos 15.0, 7.2 MB, exports 483
`Java_*` natives, and imports no JIT APIs.

## Moving the pin (security updates)

The JDK 26 line gets no upstream security fixes, so fixes must be ported here.

1. Watch OpenJDK vulnerability advisories (CPU release notes) and the
   openjdk/mobile branch. Assess each CVE against Zero/ARM64/iOS and the
   linked modules; for example, Java4Shell (CVE-2026-114938) needs x86-64
   AVX-512 intrinsics and does not apply.
2. When a fix applies: either backport it as a new numbered patch with an
   upstream `Source:` header, or move `OPENJDK_MOBILE_COMMIT` to a newer
   commit, rebase each patch (`git apply --3way`), and treat link failures as
   pin/patch problems first (ios-tools#81).
3. Bump `RUNTIME_BUILD_REVISION`, rebuild, re-run the gate (simulator, then
   device), re-run the `nm -u` privacy audit, and commit the new
   `outputs.json` receipt.
4. Rewritten and converted JAR caches key on the runtime version and rewrite
   version (KTD5), so a pin change invalidates them automatically.
