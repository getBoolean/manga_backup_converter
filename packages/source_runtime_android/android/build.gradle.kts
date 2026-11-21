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
        // The U17 gate's pinned extension APK reaches the device only in
        // debug builds (integration tests); release builds never carry it.
        getByName("debug") {
            assets.srcDirs("../../../fixtures/source_captures/tachi")
        }
    }

    defaultConfig {
        minSdk = 24
        consumerProguardFiles("consumer-rules.pro")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

// Pinned Tachi source API: mihonapp/extensions-lib 1.6.0, the API that the
// pinned extension (extensionLib 1.6) compiles against. It is a compile-time
// stub library: its method bodies throw "Stub!". It sits on the service
// process's parent class path so extension DEX links against parent-owned
// host API types (KTD17). U11 replaces the stub bodies with a real host.
//
// The AAR also carries stub copies of androidx.preference and android.content
// classes, which collide with the real androidx.preference that the app
// already ships (shared_preferences_android). Only the eu.kanade.tachiyomi
// classes are repackaged; the real libraries provide the rest.
val sourceApiVersion = "1.6.0"
val sourceApiAar: Configuration by configurations.creating {
    isTransitive = false
}

val sourceApiJar = tasks.register<Jar>("sourceApiJar") {
    archiveFileName.set("tachi-source-api-$sourceApiVersion.jar")
    destinationDirectory.set(layout.buildDirectory.dir("source-api"))
    from({
        sourceApiAar.files.map { aar ->
            zipTree(zipTree(aar).matching { include("classes.jar") }.singleFile)
        }
    }) {
        include("eu/kanade/tachiyomi/**")
    }
}

dependencies {
    // @Keep on the facade types that only Dart (JNIgen) references.
    implementation("androidx.annotation:annotation:1.10.0")
    sourceApiAar("com.github.mihonapp:extensions-lib:$sourceApiVersion@aar")
    implementation(files(sourceApiJar))
    // Runtime closure declared by extensions-lib 1.6.0's POM.
    implementation("com.squareup.okhttp3:okhttp:5.4.0")
    implementation("io.reactivex:rxjava:1.3.8")
    implementation("io.reactivex:rxandroid:1.2.1")
    implementation("org.jsoup:jsoup:1.22.2")
    implementation("com.github.mihonapp:injekt:91edab2317")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("androidx.preference:preference:1.2.1")
}
