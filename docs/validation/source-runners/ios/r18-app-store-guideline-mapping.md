# R18: App Store Review Guidelines mapping for iOS source runtimes (started in U16)

Status: draft, started by U16. U9, U10 and U15 complete it. Not legal advice,
and Apple has not reviewed it. The app ships by sideloading and then
TestFlight; App Store compliance is kept as a design constraint (Key
Decisions, KTD11).

## What runs

- **Tachi sources:** Java bytecode (repository JARs, or APKs converted on the
  device by dex2jar) interpreted by the bundled OpenJDK Zero interpreter.
  There is no JIT and no ahead-of-time compilation.
- **Paperback sources:** JavaScript interpreted by the bundled QuickJS (U10).
- **Aidoku sources:** WebAssembly interpreted by the bundled wasm3 (U18).
- **Browser use:** WKWebView only.

## Guideline 2.5.2: software must be self-contained; no downloaded executable code

| Claim | Evidence so far | Remaining |
| --- | --- | --- |
| Downloaded extensions are data run by the app's own interpreters. No downloaded native code is loaded. | The VM is statically linked; in a static VM `os::dll_load` returns the process handle instead of opening a file, so `System.loadLibrary` from an extension cannot map a library. JDK natives resolve only from the app's own framework (patch 0002). | U9: a gate test that an extension's `System.loadLibrary`/`System.load` fails without mapping anything; audit every remaining `dlopen` call site (the framework imports `dlopen`). |
| No JIT and no writable+executable memory. | Zero is interpreter-only (`java.vm.info=interpreted mode, static`). Patch 0006 commits the code cache read/write only. The framework imports no `pthread_jit_write_protect_np` or `MAP_JIT` path. No JIT entitlement is requested. | Physical-iPhone run under ordinary entitlements (U16 device stage). |
| Extensions do not change the app's primary purpose or create a store or storefront. | The app converts the user's own backups; extensions only search, fetch details and list chapters to map library entries. | U15 product review. |

## Guideline 4.7: mini apps, mini games, streaming games, chatbots, plug-ins and game emulators

| 4.7 expectation | Design |
| --- | --- |
| Software runs in an interpreter or WebKit, using only embedded runtimes. | Zero (Java bytecode), QuickJS (JS), wasm3 (WASM), WKWebView. |
| The native platform features exposed to plug-ins are limited and listed. | Initial list: HTTP through the app's networking, a WKWebView browser port (per-source non-persistent data store), per-source settings and cookies. No contacts, photos, location, camera, microphone or file-system access outside the source's sandboxed state. U9 and U10 finalise and enumerate this. |
| Age rating: content from extensions rated above the app's rating. | Open. Proposal: hide NSFW-rated extensions (`contentRating` 2) by default behind an explicit adult-content setting, and set the app's age rating to match the most permissive setting reachable. Decision needed before TestFlight external testing. |
| Precedent | Interpreted plug-ins under 4.7 (2024 guideline revision); Manatan is on the App Store, but whether its store build runs a JVM is unverified (Appendix › iOS JVM candidates). Exploded module directories reportedly failed App Store Connect validation (ios-tools#61), so the image is modular (`lib/modules`) with the module-path fix (patch 0001). |

## Privacy manifest

`tools/tachi-source-runner/ios/privacy/PrivacyInfo.xcprivacy` declares the
required-reason APIs that the linked runtime imports (checked with `nm -u` on
`libsourcejvm.a`):

- **File timestamp** (`stat`/`lstat`/`fstat`/`fstatat`, `utimes`/`utimensat`/`futimens`, `setattrlist`): `C617.1`, for files inside the app container (java.io/nio over the runtime image, caches and source state).
- **System boot time** (`mach_absolute_time`): `35F9.1`, for elapsed-time measurement (`System.nanoTime`, VM timers).
- **Disk space** (`statfs`/`fstatfs`/`statvfs`/`fstatvfs`): `E174.1`, for checking free space before writing (`File.getUsableSpace`, NIO `FileStore`).

No tracking, no collected data types. The manifest has to be merged into the
app's `ios/Runner/PrivacyInfo.xcprivacy` (owned outside U16) or bundled with
the runtime framework once the native-assets toolchain can attach resources.
Re-run the `nm -u` audit whenever the pin or patch set changes.

## Licensing (KTD11)

HotSpot is GPLv2 without the Classpath exception and is linked statically.
The runtime image ships `legal/LICENSE`, `ASSEMBLY_EXCEPTION`,
`ADDITIONAL_LICENSE_INFO` and the per-module third-party notices. Distribution
must also include a written offer of the corresponding source: the pinned
commit, `tools/tachi-source-runner/ios/` (patches, manifest, scripts), and the
dispatcher sources. The in-app notices screen is U15 work.
