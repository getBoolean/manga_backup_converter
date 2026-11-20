#!/usr/bin/env bash
# Stages the built runtime image and the U16 gate fixtures into
# packages/source_runtime_ios/runtime/ as flat package assets.
#
#   stage_runtime.sh iphonesimulator|iphoneos
#
# Requires build_runtime.sh (host, device/sim, package stages). Steps:
#   1. compile the gate fixtures (gate/src) with the host JDK built from the
#      pinned tree;
#   2. run the back-edge rewriter (mechanism A) over the host library, the
#      extension classes (except gate.ext.Unrewritten) and java.util.regex
#      from this configuration's java.base;
#   3. copy java.home as flat files plus layout.txt.

set -euo pipefail

sdk="${1:?usage: stage_runtime.sh iphonesimulator|iphoneos}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_root="$(cd "$here/.." && pwd)"
repo_root="$(cd "$ios_root/../../.." && pwd)"
build="$ios_root/build"
host_java="$build/src/mobile/build/macos-aarch64-release/jdk"
case "$sdk" in
  iphoneos) conf=ios-aarch64-zero-release ;;
  iphonesimulator) conf=iossim-aarch64-zero-release ;;
  *) echo "unknown sdk $sdk" >&2; exit 2 ;;
esac
image="$build/out/$sdk/java-home"
dest="$repo_root/packages/source_runtime_ios/runtime"
[[ -f "$image/lib/modules" ]] || { echo "run build_runtime.sh package first" >&2; exit 1; }
[[ -x "$host_java/bin/javac" ]] || { echo "run build_runtime.sh host first" >&2; exit 1; }

work="$build/gate"
rm -rf "$work" && mkdir -p "$work/classes/host" "$work/classes/ext" "$work/jars"
log() { printf '[stage_runtime] %s\n' "$*"; }

log "compiling gate fixtures"
"$host_java/bin/javac" --release 21 -d "$work/classes/host" \
  $(find "$ios_root/gate/src/host" -name '*.java')
"$host_java/bin/javac" --release 21 -cp "$work/classes/host" -d "$work/classes/ext" \
  $(find "$ios_root/gate/src/ext" -name '*.java')
"$host_java/bin/jar" --create --file "$work/jars/gate-host-plain.jar" -C "$work/classes/host" . 2>/dev/null ||
  (cd "$work/classes/host" && zip -qr "$work/jars/gate-host-plain.jar" .)
"$host_java/bin/jar" --create --file "$work/jars/gate-ext-plain.jar" -C "$work/classes/ext" . 2>/dev/null ||
  (cd "$work/classes/ext" && zip -qr "$work/jars/gate-ext-plain.jar" .)

rewrite() { "$host_java/bin/java" "$ios_root/rewriter/BackedgeRewriter.java" "$@"; }
log "rewriting back-edges (mechanism A)"
rewrite --out "$work/jars/gate-host-rewritten.jar" "$work/jars/gate-host-plain.jar" | tee "$work/rewrite-host.txt"
rewrite --out "$work/jars/gate-ext-rewritten.jar" --exclude gate/ext/Unrewritten \
  --classpath "$work/jars/gate-host-plain.jar" "$work/jars/gate-ext-plain.jar" | tee "$work/rewrite-ext.txt"
rewrite --out "$work/jars/java-base-regex-rewritten.jar" --include java/util/regex/ --only-rewritten \
  "$build/src/mobile/build/$conf/jdk/modules/java.base" | tee "$work/rewrite-regex.txt"

log "staging $sdk payload into $dest"
find "$dest" -mindepth 1 ! -name README.md ! -name .gitignore -delete
stamp="$(shasum -a 256 "$image/lib/modules" | cut -c1-12)-$sdk"
{
  printf 'stamp\t%s\n' "$stamp"
  (cd "$image" && find . -type f | sed 's#^\./##' | sort) | while read -r rel; do
    flat="home__${rel//\//__}"
    cp "$image/$rel" "$dest/$flat"
    printf 'home\t%s\t%s\n' "$flat" "$rel"
  done
  for jar in "$work/jars/"*.jar; do
    cp "$jar" "$dest/"
    printf 'fixture\t%s\n' "$(basename "$jar")"
  done
} >"$dest/layout.txt"
cat "$work"/rewrite-*.txt >"$dest/rewrite-summary.txt"
log "staged $(grep -c '^home' "$dest/layout.txt") java.home files and $(grep -c '^fixture' "$dest/layout.txt") fixtures (stamp $stamp)"
