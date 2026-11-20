#!/usr/bin/env bash
# Builds the OpenJDK mobile Zero runtime for iPhoneOS and the iOS simulator
# from the inputs recorded in ../manifest.env and ../patches/.
#
#   build_runtime.sh [stage...]
#
# Stages (default: all, in this order):
#   fetch     clone the pinned openjdk/mobile commit, reset it, apply patches
#   libffi    build libffi for iphoneos and iphonesimulator from the tarball
#   host      build a macOS JDK image from the same tree (jmod/jlink/jimage)
#   device    build the ios-aarch64 Zero static libraries and Java modules
#   sim       build the iossim-aarch64 Zero static libraries and Java modules
#   package   combine static archives, link the modular runtime images,
#             copy headers, and write build/out/outputs.json
#
# All outputs stay under ../build/ (git-ignored). Original work for this
# repository; it does not reuse openjdk-mobile/ios-tools code.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios_root="$(cd "$here/.." && pwd)"
# shellcheck source=../manifest.env
source "$ios_root/manifest.env"

build="$ios_root/build"
src="$build/src/mobile"
out="$build/out"
logs="$build/logs"
jobs="${JOBS:-$(sysctl -n hw.ncpu)}"
mkdir -p "$build" "$out" "$logs"

# Use only Xcode's toolchain: drop user toolchains (swiftly, Homebrew LLVM)
# from PATH and name the compilers explicitly.
export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
xcode_cc="$(xcrun -f clang)"
xcode_cxx="$(xcrun -f clang++)"

log() { printf '[build_runtime %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

require_tools() {
  local missing=()
  for t in git curl autoconf gmake xcrun xcodebuild libtool lipo shasum zip; do
    command -v "$t" >/dev/null || missing+=("$t")
  done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]} (brew install autoconf make)"
}

boot_jdk() {
  local home
  home="$(/usr/libexec/java_home -v "$BOOT_JDK_FEATURE" 2>/dev/null)" ||
    die "boot JDK $BOOT_JDK_FEATURE not found (/usr/libexec/java_home -v $BOOT_JDK_FEATURE)"
  printf '%s' "$home"
}

gnu_make() {
  gmake "$@"
}

stage_fetch() {
  if [[ ! -d "$src/.git" ]]; then
    mkdir -p "$(dirname "$src")"
    git init -q "$src"
    git -C "$src" remote add origin "$OPENJDK_MOBILE_REPO"
  fi
  if ! git -C "$src" cat-file -e "$OPENJDK_MOBILE_COMMIT^{commit}" 2>/dev/null; then
    log "fetching openjdk/mobile $OPENJDK_MOBILE_COMMIT"
    git -C "$src" fetch -q --depth=1 origin "$OPENJDK_MOBILE_COMMIT"
  fi
  git -C "$src" checkout -q --detach "$OPENJDK_MOBILE_COMMIT"
  git -C "$src" reset -q --hard "$OPENJDK_MOBILE_COMMIT"
  git -C "$src" clean -q -fdx -e build/
  [[ "$(git -C "$src" rev-parse HEAD)" == "$OPENJDK_MOBILE_COMMIT" ]] ||
    die "checkout is not at $OPENJDK_MOBILE_COMMIT"
  local p
  for p in "$ios_root"/patches/*.patch; do
    log "applying $(basename "$p")"
    git -C "$src" apply --whitespace=nowarn "$p"
  done
  # Source files added by this repository (not patches to existing files).
  if [[ -d "$ios_root/overlay" ]]; then
    (cd "$ios_root/overlay" && find . -type f) | while read -r f; do
      mkdir -p "$src/$(dirname "$f")"
      cp "$ios_root/overlay/$f" "$src/$f"
    done
  fi
}

stage_libffi() {
  local tarball="$build/downloads/libffi-$LIBFFI_VERSION.tar.gz"
  mkdir -p "$build/downloads"
  if [[ ! -f "$tarball" ]] || [[ "$(sha256 "$tarball")" != "$LIBFFI_SHA256" ]]; then
    log "downloading libffi $LIBFFI_VERSION"
    curl -fsSL -o "$tarball" "$LIBFFI_URL"
  fi
  [[ "$(sha256 "$tarball")" == "$LIBFFI_SHA256" ]] || die "libffi checksum mismatch"
  local sdk triple
  for sdk in iphoneos iphonesimulator; do
    if [[ "$sdk" == iphoneos ]]; then
      triple="arm64-apple-ios$IOS_DEPLOYMENT_TARGET"
    else
      triple="arm64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator"
    fi
    local work="$build/libffi/$sdk/src" prefix="$build/libffi/$sdk"
    rm -rf "$work" && mkdir -p "$work"
    tar -xzf "$tarball" -C "$work" --strip-components=1
    local sysroot cc
    sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
    cc="$(xcrun --sdk "$sdk" -f clang)"
    log "building libffi for $sdk ($triple)"
    (
      cd "$work"
      ./configure --host=aarch64-apple-darwin --prefix="$prefix" \
        --disable-shared --enable-static --disable-docs \
        CC="$cc -target $triple -isysroot $sysroot" \
        CFLAGS="-O2" >"$logs/libffi-$sdk-configure.log" 2>&1
      make -j"$jobs" install >"$logs/libffi-$sdk-make.log" 2>&1
    ) || die "libffi $sdk build failed; see $logs/libffi-$sdk-*.log"
    [[ -f "$prefix/lib/libffi.a" ]] || die "libffi.a missing for $sdk"
  done
}

configure_and_make() {
  local conf="$1"; shift
  local -a configure_args=("$@")
  local jdk
  jdk="$(boot_jdk)"
  log "configuring $conf"
  (
    cd "$src"
    bash configure CC="$xcode_cc" CXX="$xcode_cxx" \
      --with-conf-name="$conf" --with-boot-jdk="$jdk" \
      --disable-warnings-as-errors --with-jobs="$jobs" \
      --with-build-user=srt --with-version-opt="sourcerunner.r$RUNTIME_BUILD_REVISION" \
      --with-source-date="$(git -C "$src" log -1 --format=%ct)" \
      ${configure_args[@]+"${configure_args[@]}"} >"$logs/$conf-configure.log" 2>&1
  ) || die "configure $conf failed; see $logs/$conf-configure.log"
}

# Host tools only: the exploded image with java, javac (source launcher),
# jmod, jlink and jimage. java.desktop is never built, so the Metal compiler
# (not installed with Xcode 27 by default) is not needed; configure only
# requires the variables to be set.
host_targets="java.base java.base-launchers jdk.compiler jdk.compiler-launchers jdk.jlink jdk.jlink-launchers jdk.zipfs"

stage_host() {
  configure_and_make macos-aarch64-release METAL=/usr/bin/false METALLIB=/usr/bin/false
  log "building macos-aarch64-release ($host_targets)"
  # shellcheck disable=SC2086
  (cd "$src" && gnu_make CONF=macos-aarch64-release $host_targets >"$logs/macos-aarch64-release-make.log" 2>&1) ||
    die "host build failed; see $logs/macos-aarch64-release-make.log"
}

ios_targets="static-libs-image java.base-java java.base-copy java.logging-java java.xml-java jdk.unsupported-java"

stage_ios() {
  local kind="$1" sdk conf extra
  local macsdk
  macsdk="$(xcrun --sdk macosx --show-sdk-path)"
  if [[ "$kind" == device ]]; then
    sdk=iphoneos
    conf=ios-aarch64-zero-release
    extra="-target arm64-apple-ios$IOS_DEPLOYMENT_TARGET"
  else
    sdk=iphonesimulator
    conf=iossim-aarch64-zero-release
    extra="-target arm64-apple-ios$IOS_DEPLOYMENT_TARGET-simulator"
  fi
  local ffi="$build/libffi/$sdk"
  [[ -f "$ffi/lib/libffi.a" ]] || die "run the libffi stage first"
  configure_and_make "$conf" \
    --openjdk-target=aarch64-macos-ios \
    --with-jvm-variants=zero \
    --with-sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)" \
    --with-libffi-include="$ffi/include" \
    --with-libffi-lib="$ffi/lib" \
    --with-extra-cflags="$extra" \
    --with-extra-cxxflags="$extra" \
    --with-extra-ldflags="$extra" \
    --with-cups-include="$macsdk/usr/include"
  log "building $conf ($ios_targets)"
  # shellcheck disable=SC2086
  (cd "$src" && gnu_make CONF="$conf" $ios_targets >"$logs/$conf-make.log" 2>&1) ||
    die "$conf build failed; see $logs/$conf-make.log"
}

# Native archives that make up the embedded runtime, relative to
# images/static-libs/lib.
runtime_archives=(zero/libjvm.a libjava.a libjimage.a libnet.a libnio.a libzip.a libverify.a)

stage_package() {
  local host_java="$src/build/macos-aarch64-release/jdk"
  [[ -x "$host_java/bin/jlink" ]] || die "run the host stage first"
  local version
  version="$("$host_java/bin/java" -XshowSettings:properties -version 2>&1 | awk -F' = ' '/java.runtime.version/ {print $2; exit}')"
  [[ -n "$version" ]] || die "cannot read java.base version"
  local kind conf sdk platform
  rm -rf "$out" && mkdir -p "$out"
  for kind in device sim; do
    if [[ "$kind" == device ]]; then conf=ios-aarch64-zero-release sdk=iphoneos platform=IOS
    else conf=iossim-aarch64-zero-release sdk=iphonesimulator platform=IOSSIMULATOR; fi
    local b="$src/build/$conf" dest="$out/$sdk"
    mkdir -p "$dest/lib" "$dest/include"
    local -a archives=()
    local a
    for a in "${runtime_archives[@]}"; do
      [[ -f "$b/images/static-libs/lib/$a" ]] || die "$conf is missing $a"
      archives+=("$b/images/static-libs/lib/$a")
    done
    archives+=("$build/libffi/$sdk/lib/libffi.a")
    log "combining $sdk static archives"
    libtool -static -no_warning_for_no_symbols -o "$dest/lib/libsourcejvm.a" "${archives[@]}"
    # Check the platform recorded in an object (catches a device/simulator mix).
    local probe
    probe="$(mktemp -d)"
    (cd "$probe" && ar -x "$dest/lib/libsourcejvm.a" jni.o && xcrun vtool -show-build jni.o) >"$dest/build-version.txt" 2>/dev/null || true
    rm -rf "$probe"
    grep -q "platform $platform" "$dest/build-version.txt" || die "$sdk archive does not target $platform"
    cp -R "$b/jdk/include/." "$dest/include/"
    [[ -d "$dest/include/ios" ]] && cp "$dest/include/ios/"* "$dest/include/"

    # Modular runtime image (lib/modules) from this configuration's classes.
    local jmods="$build/jmods-$conf" image="$dest/java-home"
    rm -rf "$jmods" "$image" && mkdir -p "$jmods"
    local m modules_dir="$b/jdk/modules"
    IFS=',' read -r -a mods <<<"$RUNTIME_MODULES"
    for m in "${mods[@]}"; do
      [[ "$m" == java.base ]] && continue
      [[ -f "$modules_dir/$m/module-info.class" ]] || die "$conf did not build $m"
      "$host_java/bin/jmod" create --class-path "$modules_dir/$m" \
        --module-version "$version" --target-platform macos-aarch64 "$jmods/$m.jmod"
    done
    local others
    others="$(printf '%s\n' "${mods[@]}" | grep -v '^java.base$' | sed 's/\./\\./g' | paste -sd'|' -)"
    "$host_java/bin/jmod" create --class-path "$modules_dir/java.base" \
      --module-version "$version" --target-platform macos-aarch64 \
      --module-path "$jmods" --hash-modules "^($others)\$" "$jmods/java.base.jmod"
    "$host_java/bin/jlink" --module-path "$jmods" --add-modules "$RUNTIME_MODULES" \
      --strip-debug --no-header-files --no-man-pages --output "$image"
    "$host_java/bin/jimage" verify "$image/lib/modules" >/dev/null
    # Platform-neutral runtime data read from java.home.
    rm -rf "$image/bin" "$image/lib/"*.dylib "$image/lib/server" "$image/lib/jspawnhelper" 2>/dev/null || true
    # The iOS configurations build only net.properties under conf/; the
    # security configuration, CA certificates and tzdb come from the host
    # build of the same tree (platform-neutral data).
    mkdir -p "$image/conf" "$image/lib/security" "$image/legal"
    cp -RL "$host_java/conf/." "$image/conf/"
    cp -R "$b/jdk/conf/." "$image/conf/"
    cp -RL "$host_java/lib/security/." "$image/lib/security/"
    cp -L "$host_java/lib/tzdb.dat" "$image/lib/tzdb.dat"
    # GPL notices (KTD11 licensing): top-level licence files and the
    # third-party notices of every linked module.
    cp "$src/LICENSE" "$src/ASSEMBLY_EXCEPTION" "$src/ADDITIONAL_LICENSE_INFO" "$image/legal/"
    for m in "${mods[@]}"; do
      if [[ -d "$src/src/$m/share/legal" ]]; then
        mkdir -p "$image/legal/$m"
        cp "$src/src/$m/share/legal/"* "$image/legal/$m/"
      fi
    done
    [[ -f "$image/conf/security/java.security" ]] || die "java.security missing from $image"
  done
  write_outputs "$version"
}

write_outputs() {
  local version="$1"
  local f="$out/outputs.json"
  {
    printf '{\n'
    printf '  "openjdk_mobile_commit": "%s",\n' "$OPENJDK_MOBILE_COMMIT"
    printf '  "java_base_version": "%s",\n' "$version"
    printf '  "runtime_build_revision": "%s",\n' "$RUNTIME_BUILD_REVISION"
    printf '  "ios_deployment_target": "%s",\n' "$IOS_DEPLOYMENT_TARGET"
    printf '  "libffi": {"version": "%s", "sha256": "%s"},\n' "$LIBFFI_VERSION" "$LIBFFI_SHA256"
    printf '  "xcode": "%s",\n' "$(xcodebuild -version | paste -sd' ' -)"
    printf '  "boot_jdk": "%s",\n' "$("$(boot_jdk)/bin/java" -version 2>&1 | head -1 | tr -d '"')"
    printf '  "patches": {\n'
    local first=1 p
    for p in "$ios_root"/patches/*.patch; do
      ((first)) || printf ',\n'
      first=0
      printf '    "%s": "%s"' "$(basename "$p")" "$(sha256 "$p")"
    done
    printf '\n  },\n  "artifacts": {\n'
    first=1
    local a
    for a in iphoneos/lib/libsourcejvm.a iphonesimulator/lib/libsourcejvm.a \
      iphoneos/java-home/lib/modules iphonesimulator/java-home/lib/modules; do
      ((first)) || printf ',\n'
      first=0
      printf '    "%s": {"sha256": "%s", "bytes": %s}' "$a" "$(sha256 "$out/$a")" "$(stat -f %z "$out/$a")"
    done
    printf '\n  }\n}\n'
  } >"$f"
  log "wrote $f"
}

main() {
  require_tools
  local -a stages=("$@")
  ((${#stages[@]})) || stages=(fetch libffi host device sim package)
  local s
  for s in "${stages[@]}"; do
    case "$s" in
      fetch) stage_fetch ;;
      libffi) stage_libffi ;;
      host) stage_host ;;
      device) stage_ios device ;;
      sim) stage_ios sim ;;
      package) stage_package ;;
      *) die "unknown stage $s" ;;
    esac
  done
  log "done: ${stages[*]}"
}

main "$@"
