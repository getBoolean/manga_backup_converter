import javax.inject.Inject

// Android library for the `:source_runtime` service process and the Kotlin
// facades that Dart drives through JNIgen bindings (KTD17, KTD18, KTD23).
// Conventions follow the Flutter 3.50 Kotlin plugin template (AGP 9.3.1,
// Kotlin 2.4.20, android.builtInKotlin=false in the host app).

group = "dev.getboolean.sourceruntime"
version = "0.0.1"

buildscript {
    val kotlinVersion = "2.4.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.3.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

rootProject.allprojects {
    repositories {
        google()
        mavenCentral()
        // The Tachi source API (mihonapp/extensions-lib) and its injekt
        // dependency are only published on JitPack.
        maven {
            url = uri("https://jitpack.io")
            content { includeGroup("com.github.mihonapp") }
        }
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "dev.getboolean.sourceruntime"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        // Debug-only fixture asset folder: the pinned extension APKs and their
        // replay captures (fixtures/source_captures/tachi/<package>/) reach the
        // device only in debug builds (integration tests); release builds
        // never carry them.
        getByName("debug") {
            assets.srcDirs("../../../fixtures/source_captures/tachi", "../../../fixtures/source_captures/tachi-android")
        }
    }

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("consumer-rules.pro")
    }
}

// Debug-only Paperback fixtures (U12): the pinned bundles, catalogs and replay
// captures under fixtures/source_captures/paperback/ reach the device as
// assets at source_captures/paperback/ in debug builds only, for the
// integration tests. Release variants never get this directory.
abstract class PaperbackFixtureAssets : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val fixtures: DirectoryProperty

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @get:Inject
    abstract val fs: FileSystemOperations

    @TaskAction
    fun run() {
        fs.sync {
            from(fixtures)
            into(outputDir.dir("source_captures/paperback"))
        }
    }
}

val paperbackFixtureAssets = tasks.register<PaperbackFixtureAssets>("paperbackFixtureAssets") {
    fixtures.set(layout.projectDirectory.dir("../../../fixtures/source_captures/paperback"))
    outputDir.set(layout.buildDirectory.dir("generated/srtPaperbackFixtures"))
}

androidComponents {
    onVariants(selector().withBuildType("debug")) { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(paperbackFixtureAssets, PaperbackFixtureAssets::outputDir)
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// The Tachi source host (KTD17): the real Mihon source API, OkHttp, jsoup,
// kotlinx, Injekt, apksig and the Android worker platform, built from the
// shared desktop worker sources by tools/tachi-source-runner/android (included
// as ":tachi_source_host" by the app's android/settings.gradle.kts). It sits on
// the service process's parent class path, so extension DEX links against
// parent-owned host API types.
dependencies {
    // @Keep on the facade types that only Dart (JNIgen) references.
    implementation("androidx.annotation:annotation:1.10.0")
    implementation(project(":tachi_source_host"))
    implementation("androidx.webkit:webkit:1.14.0")
}
