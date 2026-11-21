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
-keep class dev.getboolean.sourceruntime.tachi.TachiWorkerConnection { public *; }
-keep interface dev.getboolean.sourceruntime.tachi.TachiWorkerListener { *; }

# The extension host surface (Mihon source API, Kotlin, OkHttp, jsoup, ...)
# is kept by the :tachi_source_host module's own consumer rules.
