# JNI headers

`jni.h`, `jni_md.h` and `jvmti.h` are copied unmodified from the pinned runtime
build (openjdk/mobile `ad8bb1b0`, configuration `ios-aarch64-zero-release`,
`support/modules_include/java.base/`). They are licensed under GPLv2 with the
Classpath exception, as stated in each file header. Refresh them when the
runtime pin changes, then rerun `dart run tool/ffigen.dart`.
