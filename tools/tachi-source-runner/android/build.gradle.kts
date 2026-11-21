// Android source host for the `:source_runtime` service (plan U11; KTD17).
//
// It shares the platform-neutral half of the desktop Tachi worker in
// ../src/main (protocol worker, Mihon source API extraction, per-package
// environment, in-memory SharedPreferences, settings codec, cookie jar,
// source operations, APK signature verification) and adds the Android
// platform in src/main/kotlin: original APK DEX on ART, real android.webkit.
//
// Excluded from the Android graph by construction (they are never copied in):
// the desktop android.* / androidx.* stubs (src/main/java/android*), the KTD20
// webkit translation shim (src/main/kotlin/webkit), JVM launch code (root/),
// dex2jar and its fixes (extensions/ApkConverter, DeterministicDex2jar,
// FrameComputer, LinkChecker, d2j/), the JVM child-first class loader, and iOS
// rewriting (../ios). The replay transport is debug-only.
//
// Included from the Flutter app's android/settings.gradle.kts as
// ":tachi_source_host"; source_runtime_android depends on it.

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("org.jetbrains.kotlin:kotlin-serialization:2.4.20")
    }
}

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}
apply(plugin = "org.jetbrains.kotlin.plugin.serialization")

group = "mangabackup.tachi"
version = "0.1.0"

val shared: File = projectDir.resolve("../src/main")

/** Shared sources compiled into every variant (paths relative to ../src/main). */
val sharedMain = listOf(
    "kotlin/extensions/ArtifactException.kt",
    "kotlin/extensions/ArtifactVerifier.kt",
    "kotlin/extensions/Digests.kt",
    "kotlin/extensions/ExtensionManifest.kt",
    "kotlin/extensions/ExtensionPackage.kt",
    "kotlin/extensions/SourceOperations.kt",
    "kotlin/host/HostExceptions.kt",
    "kotlin/host/HostInjekt.kt",
    "kotlin/host/HostSettings.kt",
    "kotlin/host/InMemorySharedPreferences.kt",
    "kotlin/host/PackageCookieJar.kt",
    "kotlin/host/PackageEnvironment.kt",
    "kotlin/host/Sizing.kt",
    "kotlin/host/tachiyomi/**",
    "kotlin/protocol/PackageRuntime.kt",
    "kotlin/protocol/Payloads.kt",
    "kotlin/protocol/QueuePipe.kt",
    "kotlin/protocol/Wire.kt",
    "kotlin/protocol/Worker.kt",
    "kotlin/protocol/WorkerOptions.kt",
    "kotlin/protocol/WorkerPlatform.kt",
    "java/mangabackup/tachi/shim/HostFailures.java",
    "java/mangabackup/tachi/shim/UnsupportedHostApi.java",
)

/** Shared sources for debug builds only: the capture replay transport (tests never contact a server). */
val sharedDebug = listOf(
    "kotlin/host/replay/**",
)

/** Plain directories (the Android source-set API refuses providers); the sync tasks fill them before compilation. */
fun sharedOut(path: String): File = layout.buildDirectory.dir("shared-host/$path").get().asFile

val syncSharedMain = tasks.register<Sync>("syncSharedHostMain") {
    from(shared) { include(sharedMain) }
    into(layout.buildDirectory.dir("shared-host/main"))
}
val syncSharedDebug = tasks.register<Sync>("syncSharedHostDebug") {
    from(shared) { include(sharedDebug) }
    into(layout.buildDirectory.dir("shared-host/debug"))
}

android {
    namespace = "mangabackup.tachi.android"
    compileSdk = 36

    defaultConfig {
        // The app's minSdk (KTD19). The closure's own floor is recorded in
        // docs/validation/source-runners/android/.
        minSdk = 28
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin", sharedOut("main/kotlin"), sharedOut("main/java"))
        }
        getByName("debug") {
            java.srcDirs("src/debug/kotlin", sharedOut("debug/kotlin"))
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
        freeCompilerArgs.addAll("-Xcontext-parameters")
    }
}

tasks.named("preBuild") { dependsOn(syncSharedMain, syncSharedDebug) }
tasks.matching { it.name.startsWith("compile") || it.name.contains("Lint", ignoreCase = true) || it.name.startsWith("extract") }
    .configureEach { dependsOn(syncSharedMain, syncSharedDebug) }

// Versions follow ../gradle/libs.versions.toml: the app-provided bundle that
// keiyoushi extensions compile against (extensionLib 1.6). Raise together.
dependencies {
    val coroutines = "1.11.0"
    val serialization = "1.11.0"
    val okhttp = "5.4.0"

    implementation("org.jetbrains.kotlin:kotlin-reflect:2.4.20")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:$coroutines")
    // Dispatchers.Main on the service process's real main looper.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:$coroutines")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:$serialization")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json-okio:$serialization")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-protobuf:$serialization")
    implementation("com.squareup.okhttp3:okhttp:$okhttp")
    implementation("com.squareup.okhttp3:okhttp-brotli:$okhttp")
    implementation("com.squareup.okhttp3:okhttp-zstd:$okhttp")
    implementation("com.squareup.zstd:zstd-kmp-okio:0.4.0")
    implementation("org.jsoup:jsoup:1.22.2")
    implementation("com.github.mihonapp:injekt:91edab2317")
    implementation("io.reactivex:rxjava:1.3.8")
    // APK v1-v4 signature verification and the binary manifest parser (pure Java).
    implementation("com.android.tools.build:apksig:9.5.1")
    implementation("androidx.preference:preference:1.2.1")
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("androidx.annotation:annotation:1.10.0")

    // Capture replay for debug builds (tests): a loopback MockWebServer with a held certificate.
    debugImplementation("com.squareup.okhttp3:okhttp-tls:$okhttp")
    debugImplementation("com.squareup.okhttp3:mockwebserver3:$okhttp")
}
