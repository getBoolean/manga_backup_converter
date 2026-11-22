# Third-party code and dependencies

## Extracted source (attributed in each file header)

| Source | Revision | Licence | Where |
|---|---|---|---|
| Mihon `source-api` (eu.kanade.tachiyomi.source.*, util.JsoupExtensions) | mihonapp/mihon `f64d82b94218b42410c36e6c85da818574865a28` | Apache-2.0 | `src/main/kotlin/host/tachiyomi/source/`, `util/` |
| Mihon `core/common` network (HttpException, OkHttpExtensions, Requests, Progress*, RateLimit/SpecificHostRateLimit/UncaughtException/UserAgent interceptors) | same | Apache-2.0 | `src/main/kotlin/host/tachiyomi/network/` |
| keiyoushi `extensions-lib` ABI dump (`library.api`, test resource only) | keiyoushi/extensions-lib `42255ee` | Apache-2.0 | `src/test/resources/abi/extensions-lib-1.6.api` |

Local changes in extracted files are marked `desktop host:`. The Android API shims under
`src/main/java/android*/` are original implementations of the public Android API surface the
qualification extensions use (names and signatures follow AOSP, Apache-2.0); no AOSP code is copied.
Suwayomi AndroidCompat was not used and its source was not inspected (a deviation from U3 step 1's
tracing step). It was set aside because it is not published to a Maven repository, while the qualification
extensions' actual Android surface (traced from their bytecode with jdeps/javap and enforced by
`AbiConformanceTest`/`LinkChecker`) is small enough to implement directly. A later unit may still compare
it against these shims.

## Runtime dependencies (versions locked in `gradle.lockfile`)

| Artifact | Version | Licence |
|---|---|---|
| org.jetbrains.kotlin:kotlin-stdlib, kotlin-reflect | 2.4.10 | Apache-2.0 |
| org.jetbrains.kotlinx:kotlinx-coroutines-core | 1.11.0 | Apache-2.0 |
| org.jetbrains.kotlinx:kotlinx-serialization-json / -json-okio / -protobuf | 1.11.0 | Apache-2.0 |
| com.squareup.okhttp3:okhttp, okhttp-brotli, okhttp-zstd, okhttp-tls, mockwebserver3 | 5.4.0 | Apache-2.0 |
| com.squareup.okio:okio | 3.17.0 | Apache-2.0 |
| com.squareup.zstd:zstd-kmp-okio | 0.4.0 | Apache-2.0 (bundles zstd, BSD-3-Clause) |
| org.brotli:dec | 0.1.2 | MIT |
| org.jsoup:jsoup | 1.22.2 | MIT |
| com.github.mihonapp:injekt (JitPack) | 91edab2317 | MIT |
| uy.kohesive.injekt:injekt-core / injekt-api | 1.16.1 | MIT |
| io.reactivex:rxjava | 1.3.8 | Apache-2.0 |
| com.android.tools.build:apksig | 9.5.1 | Apache-2.0 (declared in the POM) |
| de.femtopedia.dex2jar:dex-translator, dex-reader, dex-reader-api, dex-ir, d2j-base-cmd, d2j-external | 2.4.39 | Apache-2.0 (licence declared in each POM) |
| (bundled in d2j-external) AOSP dx/dex classes and a partial copy of ASM | — | Apache-2.0 / BSD-3-Clause |
| org.ow2.asm:asm, asm-tree (dex-translator dependency) | 9.11.1 | BSD-3-Clause |

Test only: JUnit 5.13.4 (EPL-2.0), Bouncy Castle 1.82 (MIT).

`androidFixtureExt` (U11 synthetic Android fixture extensions) compiles against the Android SDK's
`android.jar` (platform 36, from the local SDK, not redistributed) plus the main classpath above; its
locked Gradle configurations add no new artifacts.

## Android host module (`android/`, U11)

Built inside the Flutter app's Gradle project (`:tachi_source_host`) and shipped in the app's
`:source_runtime` process. It reuses the shared sources listed in `android/build.gradle.kts` and
adds these artifacts. The app's release closure is recorded in
`docs/validation/source-runners/android/u11-dependency-closure-releaseRuntimeClasspath.txt`.

| Artifact | Version | Licence |
|---|---|---|
| org.jetbrains.kotlin:kotlin-reflect, kotlin-serialization (compiler plugin) | 2.4.20 | Apache-2.0 |
| org.jetbrains.kotlinx:kotlinx-coroutines-core / -android | 1.11.0 | Apache-2.0 |
| org.jetbrains.kotlinx:kotlinx-serialization-json / -json-okio / -protobuf | 1.11.0 | Apache-2.0 |
| com.squareup.okhttp3:okhttp, okhttp-brotli, okhttp-zstd (debug: okhttp-tls, mockwebserver3) | 5.4.0 | Apache-2.0 |
| com.squareup.zstd:zstd-kmp-okio, zstd-kmp (Android variants) | 0.4.0 | Apache-2.0 (declared in the POM) |
| (native, in zstd-kmp-android) `jni/<abi>/libzstd-kmp.so` for arm64-v8a, armeabi-v7a, x86, x86_64 | statically links zstd 1.5.8 | zstd: BSD-3-Clause (dual-licensed BSD-3-Clause OR GPL-2.0 upstream; used under BSD-3-Clause). The AAR ships no licence file; the text is facebook/zstd's `LICENSE` |
| org.brotli:dec | 0.1.2 | MIT |
| org.jsoup:jsoup | 1.22.2 | MIT |
| com.github.mihonapp:injekt (JitPack) | 91edab2317 | MIT |
| io.reactivex:rxjava | 1.3.8 | Apache-2.0 |
| com.android.tools.build:apksig | 9.5.1 | Apache-2.0 (declared in the POM) |
| androidx.preference:preference (pulls androidx.appcompat, fragment, core and related AndroidX libraries) | 1.2.1 | Apache-2.0 |
| androidx.webkit:webkit | 1.14.0 | Apache-2.0 |
| androidx.annotation:annotation | 1.10.0 | Apache-2.0 |

The host does not bundle dex2jar, ASM or the desktop Android API shims: extensions run as their
original DEX on ART against the real framework.
