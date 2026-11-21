# Consumer R8 rules for the Android Tachi source host (U11; KTD17).
#
# Extension APK DEX is loaded at run time in the :source_runtime process with
# the app's class loader as parent. It links against the host's copies of
# these libraries by their original names and member signatures, which R8
# cannot see, so whole packages are kept unrenamed and unshrunk. The set is the
# app-provided bundle keiyoushi extensions compile against (extensionLib 1.6:
# Mihon source API, Kotlin, kotlinx coroutines/serialization, OkHttp, Okio,
# jsoup, RxJava, Injekt, androidx.preference) plus androidx.webkit, which
# extensions drive through WebViewCompat. Verified against the external types
# of the three qualification APKs' DEX
# (docs/validation/source-runners/android/u11-extension-external-types.txt).

# Mihon source API and network surface (eu.kanade.tachiyomi.*), and the
# Mihon/Tachiyomi helper packages extensions import.
-keep class eu.kanade.tachiyomi.** { *; }
-keep class tachiyomi.** { *; }
-keep class mihon.** { *; }
-keep class dev.mihon.** { *; }

# Libraries extensions link against.
-keep class kotlin.** { *; }
-keep class kotlinx.** { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class org.jsoup.** { *; }
-keep class rx.** { *; }
-keep class uy.kohesive.** { *; }
-keep class androidx.preference.** { *; }
-keep class androidx.webkit.** { *; }
-keep class org.brotli.** { *; }
-keep class com.squareup.zstd.** { *; }

# The host's worker platform is reached reflectively (debug hooks) and from
# the service; keep it whole so stack-based package resolution sees real names.
-keep class mangabackup.tachi.** { *; }

# Extensions and kotlinx.serialization read generic signatures, annotations
# and Kotlin metadata reflectively.
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*,SourceFile,LineNumberTable

# Optional dependencies some kept classes reference but the host does not ship.
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-dontwarn kotlinx.coroutines.debug.**
-dontwarn java.lang.management.**
-dontwarn javax.naming.**
-dontwarn org.slf4j.**
-dontwarn com.google.errorprone.annotations.**
-dontwarn org.jetbrains.annotations.**
