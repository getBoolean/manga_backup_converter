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
Suwayomi AndroidCompat was evaluated and not used: it is not published to any Maven repository and its
build needs Google's `android.jar`, so the needed classes are implemented here instead.

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
| com.android.tools.build:apksig | 9.5.1 | Apache-2.0 |
| de.femtopedia.dex2jar:dex-translator (+ dex-reader, dex-ir, d2j-external, ASM) | 2.4.39 | Apache-2.0 (ASM: BSD-3-Clause) |

Test only: JUnit 5.13.4 (EPL-2.0), Bouncy Castle 1.82 (MIT).
