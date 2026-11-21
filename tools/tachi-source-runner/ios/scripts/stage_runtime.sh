#!/usr/bin/env bash
# Stages the iOS source runtime payload into packages/source_runtime_ios/
# runtime/ as flat package assets plus layout.txt.
#
#   stage_runtime.sh iphonesimulator|iphoneos [--gate] [--test]
#
# Default (shipping) payload:
#   - java.home: the modular image from build_runtime.sh, with the U9
#     java.base bake (rewritten class-library packages, native-load guard);
#   - the Tachi host class path: the shared worker's JARs from
#     `./gradlew installDist`, with the host libraries that loop over site data
#     back-edge rewritten (HOST_REWRITES below), plus the iOS host
#     (ios/host/src), compiled for the mobile class library.
#   The replay server JARs (mockwebserver3, okhttp-tls) are left out: the
#   shipping runtime has no loopback server.
#
# --gate adds the U16 gate fixtures (gate/src) for integration_test/
#   ios_runtime_gate_test.dart.
# --test adds what integration_test/source_runners_ios_tachi_test.dart (U9)
#   and source_runners_ios_test.dart (U15) need: the
#   replay JARs, the committed captures and artifacts under fixtures/
#   source_captures/tachi, and the busy/webview fixture extensions signed with
#   a throwaway test key (its fingerprint in test-signer.txt).
# The product never provides extensions or repositories: the default payload
# holds no extension artifact, capture or repository reference. Never ship a
# --gate or --test payload; BundledRuntime refuses one in release builds.

set -euo pipefail

sdk="${1:?usage: stage_runtime.sh iphonesimulator|iphoneos [--gate] [--test]}"
shift
gate=0
test=0
for a in "$@"; do
  case "$a" in
    --gate) gate=1 ;;
    --test) test=1 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_root="$(cd "$here/.." && pwd)"
runner="$(cd "$ios_root/.." && pwd)"
repo_root="$(cd "$runner/../.." && pwd)"
build="$ios_root/build"
host_java="$build/src/mobile/build/macos-aarch64-release/jdk"
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
case "$sdk" in
  iphoneos) conf=ios-aarch64-zero-release ;;
  iphonesimulator) conf=iossim-aarch64-zero-release ;;
  *) echo "unknown sdk $sdk" >&2; exit 2 ;;
esac
image="$build/out/$sdk/java-home"
dest="$repo_root/packages/source_runtime_ios/runtime"
worker_lib="$runner/build/install/tachi-source-runner/lib"
[[ -f "$image/lib/modules" ]] || { echo "run build_runtime.sh package first" >&2; exit 1; }
[[ -x "$host_java/bin/javac" ]] || { echo "run build_runtime.sh host first" >&2; exit 1; }
[[ -d "$worker_lib" ]] || { echo "run ./gradlew installDist in tools/tachi-source-runner first" >&2; exit 1; }

# Host libraries rewritten at build time (U9): JAR name prefix and the class
# prefixes rewritten in it. jsoup parses site HTML, kotlinx-serialization-json
# parses site JSON, kotlin.text scans site strings. Coroutines, OkHttp, Okio and
# the worker itself are not rewritten: their loops are bounded by host state
# and many hold locks shared across operations; their waits end through
# cancellation instead.
HOST_REWRITES=(
  "jsoup-:org/jsoup/"
  "kotlinx-serialization-json-jvm-:kotlinx/serialization/json/"
  "kotlin-stdlib-:kotlin/text/"
)
TEST_ONLY_JARS=(mockwebserver3- okhttp-tls-)

work="$build/stage/$sdk"
rm -rf "$work" && mkdir -p "$work/host-classes" "$work/classpath" "$work/jars"
log() { printf '[stage_runtime] %s\n' "$*"; }

worker_cp="$(ls "$worker_lib"/*.jar | paste -sd: -)"
log "compiling the iOS host"
"$host_java/bin/javac" --release 26 -cp "$worker_cp" -d "$work/host-classes" \
  $(find "$ios_root/host/src" -name '*.java')
(cd "$work/host-classes" && zip -qrX "$work/classpath/ios-host.jar" .)
rewrite() { "$host_java/bin/java" -cp "$work/host-classes" mangabackup.tachi.ios.BackedgeRewriter "$@"; }

log "rewriting host libraries"
: >"$work/rewrite-summary.txt"
for jar in "$worker_lib"/*.jar; do
  name="$(basename "$jar")"
  test_only=0
  for t in "${TEST_ONLY_JARS[@]}"; do
    if [[ "$name" == "$t"* ]]; then test_only=1; fi
  done
  if ((test_only && !test)); then continue; fi
  include=""
  for r in "${HOST_REWRITES[@]}"; do
    [[ "$name" == "${r%%:*}"* ]] && include="${r#*:}"
  done
  if [[ -n "$include" ]]; then
    rewrite --out "$work/classpath/$name" --include "$include" --classpath "$worker_cp" "$jar" |
      sed "s#->.*#($name)#" | tee -a "$work/rewrite-summary.txt"
  else
    cp "$jar" "$work/classpath/$name"
  fi
done

if ((gate)); then
  log "compiling and rewriting the U16 gate fixtures"
  mkdir -p "$work/gate/host" "$work/gate/ext"
  "$host_java/bin/javac" --release 21 -d "$work/gate/host" $(find "$ios_root/gate/src/host" -name '*.java')
  "$host_java/bin/javac" --release 21 -cp "$work/gate/host" -d "$work/gate/ext" $(find "$ios_root/gate/src/ext" -name '*.java')
  (cd "$work/gate/host" && zip -qrX "$work/jars/gate-host-plain.jar" .)
  (cd "$work/gate/ext" && zip -qrX "$work/jars/gate-ext-plain.jar" .)
  rewrite --out "$work/jars/gate-host-rewritten.jar" "$work/jars/gate-host-plain.jar" | tee -a "$work/rewrite-summary.txt"
  rewrite --out "$work/jars/gate-ext-rewritten.jar" --exclude gate/ext/Unrewritten \
    --classpath "$work/jars/gate-host-plain.jar" "$work/jars/gate-ext-plain.jar" | tee -a "$work/rewrite-summary.txt"
  # The image already carries the rewritten java.util.regex; the gate keeps
  # its --patch-module run for comparison with U16's receipts.
  rewrite --out "$work/jars/java-base-regex-rewritten.jar" --target java.base --include java/util/regex/ \
    --only-rewritten "$build/src/mobile/build/$conf/jdk/modules/java.base" | tee -a "$work/rewrite-summary.txt"
fi

if ((test)); then
  fx="$runner/build/fx"
  for f in busy webview; do
    [[ -f "$fx/fixture-$f.jar" ]] || { echo "run ./gradlew fixtureJar_busy fixtureJar_webview first" >&2; exit 1; }
  done
  signing_home="${SIGNING_JAVA_HOME:-$(/usr/libexec/java_home -v 21 2>/dev/null || /usr/libexec/java_home -v 25)}"
  [[ -x "$signing_home/bin/jarsigner" ]] || { echo "jarsigner not found under $signing_home" >&2; exit 1; }
  log "signing fixture extensions with a throwaway test key"
  ks="$work/test-signer.p12"
  "$signing_home/bin/keytool" -genkeypair -keystore "$ks" -storetype PKCS12 -storepass testpass -keypass testpass \
    -alias fixture -keyalg RSA -keysize 2048 -validity 3650 -dname "CN=U9 fixture signer (test only)" >/dev/null 2>&1
  for f in busy webview; do
    cp "$fx/fixture-$f.jar" "$work/jars/fixture-$f-signed.jar"
    "$signing_home/bin/jarsigner" -keystore "$ks" -storepass testpass -digestalg SHA-256 -sigalg SHA256withRSA \
      "$work/jars/fixture-$f-signed.jar" fixture >/dev/null
  done
  "$signing_home/bin/keytool" -exportcert -keystore "$ks" -storepass testpass -alias fixture -file "$work/test-signer.der" >/dev/null 2>&1
  shasum -a 256 "$work/test-signer.der" | cut -c1-64 >"$work/jars/test-signer.txt"
fi

log "staging $sdk payload into $dest"
find "$dest" -mindepth 1 ! -name README.md ! -name .gitignore -delete
stamp="$(cat "$image/lib/modules" "$work/classpath/"*.jar | shasum -a 256 | cut -c1-12)-$sdk"
{
  printf 'stamp\t%s\n' "$stamp"
  (cd "$image" && find . -type f | sed 's#^\./##' | sort) | while read -r rel; do
    flat="home__${rel//\//__}"
    cp "$image/$rel" "$dest/$flat"
    printf 'home\t%s\t%s\n' "$flat" "$rel"
  done
  # Class path order: the iOS host, then the shared worker, then libraries.
  for jar in "$work/classpath/ios-host.jar" "$work/classpath/tachi-source-runner-"*.jar; do
    cp "$jar" "$dest/cp__$(basename "$jar")"
    printf 'classpath\t%s\n' "cp__$(basename "$jar")"
  done
  for jar in "$work/classpath/"*.jar; do
    case "$(basename "$jar")" in ios-host.jar|tachi-source-runner-*) continue ;; esac
    cp "$jar" "$dest/cp__$(basename "$jar")"
    printf 'classpath\t%s\n' "cp__$(basename "$jar")"
  done
  for f in "$work/jars/"*; do
    [[ -f "$f" ]] || continue
    cp "$f" "$dest/"
    printf 'fixture\t%s\n' "$(basename "$f")"
  done
  if ((test)); then
    (cd "$repo_root/fixtures/source_captures/tachi" && find . -type f | sed 's#^\./##' | sort) | while read -r rel; do
      flat="data__${rel//\//__}"
      cp "$repo_root/fixtures/source_captures/tachi/$rel" "$dest/$flat"
      printf 'data\t%s\t%s\n' "$flat" "$rel"
    done
  fi
} >"$dest/layout.txt"
cp "$work/rewrite-summary.txt" "$dest/rewrite-summary.txt"
if ((!gate && !test)); then
  if grep -qE '^(fixture|data)'$'\t' "$dest/layout.txt"; then
    echo "shipping payload contains fixtures or test data" >&2; exit 1
  fi
fi
log "staged $(grep -c '^home' "$dest/layout.txt") java.home files, $(grep -c '^classpath' "$dest/layout.txt") class path JARs," \
  "$(grep -c '^fixture' "$dest/layout.txt") fixtures, $(grep -c '^data' "$dest/layout.txt") test data files (stamp $stamp)"
