# Facade classes reached from Dart through JNIgen bindings, and the pinned
# source API types that extension DEX links against through the parent class
# loader, must keep their names.
-keep class dev.getboolean.sourceruntime.** { *; }
-keep class eu.kanade.tachiyomi.** { *; }
# Not yet covered (U11): extension DEX also references OkHttp, Okio, Kotlin,
# kotlinx (serialization, coroutines), jsoup, injekt and androidx.preference
# types (docs/validation/source-runners/android/
# mangadex-v1.6.4-dex-external-types.txt). R8 renames or strips them in
# release builds, so a release-profile host needs keep rules for that surface.
