import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    application
}

group = "mangabackup.tachi"
version = "0.1.0"

dependencyLocking {
    lockAllConfigurations()
}

java {
    sourceCompatibility = JavaVersion.VERSION_21
    targetCompatibility = JavaVersion.VERSION_21
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.JVM_21
        freeCompilerArgs.addAll("-Xcontext-parameters")
    }
}

// Fixture extensions used only by tests: compiled against the host API exactly
// like a real extension (compileOnly), then packaged into separate JARs.
val fixtureExt: SourceSet by sourceSets.creating {
    compileClasspath += sourceSets.main.get().output + sourceSets.main.get().compileClasspath
    kotlin.srcDir("src/fixtureCommon/kotlin")
}
// Second fixture compilation: fixture-b reuses class names from fixture-a.
val fixtureExtB: SourceSet by sourceSets.creating {
    compileClasspath += sourceSets.main.get().output + sourceSets.main.get().compileClasspath
    kotlin.srcDir("src/fixtureCommon/kotlin")
}

// Synthetic fixture extensions for the Android service tests (U11): compiled
// against the real android.jar first (so android.* resolves to the framework,
// not the desktop shims) and the host API, then dexed, packaged and signed by
// android/fixtures/build_fixtures.sh. Needs ANDROID_SDK_ROOT (or ANDROID_HOME);
// only the androidFixtureJar task resolves it.
val androidSdkRoot: String? = System.getenv("ANDROID_SDK_ROOT") ?: System.getenv("ANDROID_HOME")
val androidFixtureExt: SourceSet by sourceSets.creating {
    kotlin.srcDir("android/fixtures/kotlin")
    compileClasspath = files(androidSdkRoot?.let { "$it/platforms/android-36/android.jar" } ?: "missing-android-sdk/android.jar") +
        sourceSets.main.get().output + sourceSets.main.get().compileClasspath
}
tasks.register<Jar>("androidFixtureJar") {
    group = "verification"
    description = "Compiles the U11 Android fixture extensions (input to android/fixtures/build_fixtures.sh)."
    archiveFileName = "android-fixtures.jar"
    destinationDirectory = layout.buildDirectory.dir("android-fx")
    from(androidFixtureExt.output)
}

// Manual capture tool: records live site responses once. Never run by tests.
val capture: SourceSet by sourceSets.creating {
    compileClasspath += sourceSets.main.get().output + sourceSets.main.get().compileClasspath
    runtimeClasspath += sourceSets.main.get().output + sourceSets.main.get().runtimeClasspath
}

// Benchmark harness (KTD25). Runs the worker against replayed captures.
val benchmark: SourceSet by sourceSets.creating {
    kotlin.srcDir("benchmark/src")
    compileClasspath += sourceSets.main.get().output + sourceSets.main.get().compileClasspath
    runtimeClasspath += sourceSets.main.get().output + sourceSets.main.get().runtimeClasspath
}

dependencies {
    implementation(libs.kotlin.stdlib)
    implementation(libs.kotlin.reflect)
    implementation(libs.coroutines.core)
    implementation(libs.serialization.json)
    implementation(libs.serialization.json.okio)
    implementation(libs.serialization.protobuf)
    implementation(libs.okhttp)
    implementation(libs.okhttp.brotli)
    implementation(libs.okhttp.zstd)
    implementation(libs.zstd.kmp.okio)
    implementation(libs.okhttp.tls)
    implementation(libs.mockwebserver)
    implementation(libs.jsoup)
    implementation(libs.injekt)
    implementation(libs.rxjava)
    implementation(libs.apksig)
    implementation(libs.dex2jar)

    testImplementation(platform(libs.junit.bom))
    testImplementation(libs.junit.jupiter)
    testRuntimeOnly(libs.junit.launcher)
    testImplementation(libs.bouncycastle.pkix)
    testImplementation(sourceSets.main.get().output)
}

application {
    mainClass = "mangabackup.tachi.MainKt"
    applicationName = "tachi-source-runner"
}

// KTD25: the runtime manifest carries the handshake deadline the supervisor needs before the worker
// speaks. It is written by the worker's own code from the committed sizing rule, and installed at the
// root of the distribution beside lib/.
val runtimeManifest by tasks.registering(JavaExec::class) {
    group = "distribution"
    description = "Writes tachi-runtime.json (handshake deadline from the committed sizing rule)."
    val out = layout.buildDirectory.file("runtime-manifest/tachi-runtime.json")
    classpath = sourceSets.main.get().runtimeClasspath
    mainClass = "mangabackup.tachi.host.RuntimeManifest"
    inputs.file("src/main/resources/tachi-worker-sizing.json")
    outputs.file(out)
    argumentProviders += CommandLineArgumentProvider { listOf(out.get().asFile.absolutePath) }
}

distributions {
    main {
        contents {
            from(runtimeManifest)
        }
    }
}

val repoRoot: File = rootDir.parentFile.parentFile
val fixtureJarsDir = layout.buildDirectory.dir("fx")

// Each fixture package is its own JAR so tests can load them into separate
// class loaders. `fixture-a` and `fixture-b` deliberately share class names.
val fixturePackages = listOf("a", "b", "multi", "busy", "webview", "legacy", "prefs")
val fixtureJarTasks = fixturePackages.map { name ->
    tasks.register<Jar>("fixtureJar_$name") {
        archiveFileName = "fixture-$name.jar"
        destinationDirectory = fixtureJarsDir
        val shared = name == "a" || name == "b"
        from(if (name == "b") fixtureExtB.output else fixtureExt.output) {
            include("fixture/$name/**")
            if (shared) {
                include("fixture/shared/**")
                include("fixture/common/**")
            }
        }
        from(file("src/fixtureExt/manifests/$name")) {
            include("AndroidManifest.xml")
            include("assets/**")
        }
    }
}

tasks.test {
    useJUnitPlatform()
    dependsOn(fixtureJarTasks)
    systemProperty("tachi.fixtures", File(repoRoot, "fixtures/source_captures/tachi").absolutePath)
    systemProperty("tachi.fixtureJars", fixtureJarsDir.get().asFile.absolutePath)
    systemProperty("tachi.workerClasspath", sourceSets.main.get().runtimeClasspath.asPath)
    systemProperty("tachi.javaHome", System.getProperty("java.home"))
    (project.findProperty("transcriptDir") as String?)?.let { systemProperty("tachi.transcriptDir", it) }
    maxHeapSize = "1g"
    testLogging {
        events("failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        showStandardStreams = false
    }
}

tasks.register<JavaExec>("capture") {
    group = "verification"
    description = "Manual one-time capture of qualification source responses (never run by tests)."
    classpath = capture.runtimeClasspath
    mainClass = "mangabackup.tachi.capture.CaptureToolKt"
    workingDir = repoRoot
    args = (project.findProperty("captureArgs") as String?)?.split(' ')?.filter { it.isNotBlank() } ?: emptyList()
}

tasks.register<JavaExec>("benchmark") {
    group = "verification"
    description = "Runs the KTD25 worker benchmark against replayed captures and writes results."
    classpath = benchmark.runtimeClasspath
    mainClass = "mangabackup.tachi.benchmark.BenchmarkKt"
    workingDir = repoRoot
    dependsOn(fixtureJarTasks, tasks.named("installDist"))
    systemProperty("tachi.fixtureJars", fixtureJarsDir.get().asFile.absolutePath)
    systemProperty("tachi.workerClasspath", sourceSets.main.get().runtimeClasspath.asPath)
    // Start-up is measured on the installed distribution, launched the way the supervisor launches it.
    systemProperty("tachi.installDir", layout.buildDirectory.dir("install/tachi-source-runner").get().asFile.absolutePath)
    args = (project.findProperty("benchmarkArgs") as String?)?.split(' ')?.filter { it.isNotBlank() } ?: emptyList()
}

// Resolves every configuration so `--write-locks` covers the whole graph.
tasks.register("resolveAll") {
    notCompatibleWithConfigurationCache("resolves configurations at execution time")
    doLast {
        configurations.filter { it.isCanBeResolved }.forEach { it.resolve() }
    }
}

tasks.register("printRuntimeClasspath") {
    val cp = sourceSets.main.get().runtimeClasspath
    doLast { println(cp.asPath) }
}
