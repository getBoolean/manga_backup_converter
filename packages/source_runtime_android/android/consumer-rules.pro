# Consumer R8 rules for apps that depend on source_runtime_android.

# --- Dart-only entry points -------------------------------------------------
# Only Dart (JNIgen bindings) references the facade types, by name and JNI
# signature, so R8 sees no callers. They carry @androidx.annotation.Keep; these
# rules repeat that so a missing annotation rule cannot strip them. The
# service is kept by its manifest entry.
-keep class dev.getboolean.sourceruntime.SourceRuntimeClient { public *; }
-keep interface dev.getboolean.sourceruntime.SourceRuntimeListener { *; }
-keep class dev.getboolean.sourceruntime.ArtifactStaging { public *; }
-keep class dev.getboolean.sourceruntime.AppWebViewProbe { public *; }
-keep interface dev.getboolean.sourceruntime.ProbeListener { *; }
-keep class dev.getboolean.sourceruntime.RuntimeDiagnostics { public *; }

# --- Host surface for extension DEX -----------------------------------------
# Extension APK DEX is loaded at run time in the :source_runtime process with
# the app's class loader as parent (KTD17). It links against the host's copies
# of these libraries by their original names and member signatures, which R8
# cannot see, so whole packages are kept unrenamed. The set follows the
# extension API's runtime closure (extensions-lib 1.6.0) and the external
# types the pinned extension references
# (docs/validation/source-runners/android/mangadex-v1.6.4-dex-external-types.txt).
-keep class eu.kanade.tachiyomi.** { *; }
-keep class kotlin.** { *; }
-keep class kotlinx.serialization.** { *; }
-keep class kotlinx.coroutines.** { *; }
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep class org.jsoup.** { *; }
-keep class rx.** { *; }
-keep class uy.kohesive.injekt.** { *; }
-keep class androidx.preference.** { *; }

# Extensions read generic signatures and annotations reflectively
# (kotlinx.serialization, injekt's type references).
-keepattributes Signature,InnerClasses,EnclosingMethod,*Annotation*

# Optional dependencies that some keep targets reference but the host does not
# ship (OkHttp's optional platforms, coroutines' debug agent).
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-dontwarn kotlinx.coroutines.debug.**
