plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android Gradle plugin.
    // It applies the Kotlin Gradle plugin itself (android.builtInKotlin=false).
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.getboolean.mangabackupconverter"
    compileSdk = flutter.compileSdkVersion
    // Pinned: the scraper, wasm3 and quickjs build hooks cross-compile with this NDK.
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.getboolean.mangabackupconverter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // 28 for all features (KTD19, user decision on U17's evidence): the
        // `:source_runtime` process needs WebView.setDataDirectorySuffix, which
        // does not exist below API 28. Flutter 3.50 itself needs 24.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// Every resolved configuration of the app (including the plugin projects'
// transitive artifacts it packages) is pinned in app/gradle.lockfile (U14
// build records). Regenerate after a dependency change with
//   cd android && ./gradlew :app:dependencies --write-locks
//
// Flutter's engine artifacts (io.flutter:*) are left out: the Flutter SDK
// pins them, and the Flutter tool resolves only the ABIs of each build
// (`flutter test` builds one), which a lock of all ABIs would reject.
dependencyLocking {
    lockAllConfigurations()
    ignoredDependencies.add("io.flutter:*")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
