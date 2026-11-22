"""U14: records and checks one built Android APK (Evidence Identity, Android).

    python3 -I scripts/android_package_check.py <app.apk> <out.json>
        [--allow-test-payload] [--expect <earlier out.json>]

    --allow-test-payload  a debug/test build: the plugin's debug-only fixture
                          assets (extension APKs, captures, fixture repository)
                          are expected and only recorded
    --expect FILE         compare the native library hashes with an earlier
                          record of the same APK (fails on any difference)
    --build-dir DIR       the Flutter build directory (build/): every library
                          in the APK must equal AGP's stripped output for the
                          variant (build/app/intermediates/stripped_native_libs/
                          <variant>); the unstripped build-hook outputs are
                          recorded beside them
    --variant NAME        release (default) or debug

Records the package identity (package, version, resolved min/target/compile
SDK), the APK signing identity (apksigner), every native library per ABI
(size, SHA-256, ELF class/machine) and the shipped notices, then fails
(exit 1) when:
  - minSdk is not the advertised 28 (KTD19), or targetSdk/compileSdk is
    below 36;
  - an advertised ABI (arm64-v8a, armeabi-v7a, x86_64) lacks a runtime
    library (QuickJS, wasm3, scraper), or a library's ELF machine does not
    match its ABI directory;
  - a native library or bundled host library has no notice in the APK;
  - the APK holds an extension artifact or repository configuration
    (nested .apk/.aix/.jar, Paperback bundles, capture files, repo.json,
    index*.json, fixture manifests, the test signer, the debug fixture asset
    folders) or names a known extension repository in its code, unless
    --allow-test-payload.
"""

import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import zipfile
import zlib

ADVERTISED_ABIS = ("arm64-v8a", "armeabi-v7a", "x86_64")
RUNTIME_LIBRARIES = ("libquickjs.so", "libwasm3.so", "libscraper_bridge.so")
ELF_MACHINES = {"arm64-v8a": 183, "armeabi-v7a": 40, "x86_64": 62}
MIN_SDK = 28
CURRENT_SDK = 36

# Each shipped native library and bundled host library, and a phrase its
# notice must contain in the APK's notices (Flutter's NOTICES.Z, or the
# Android host notices asset).
NATIVE_NOTICES = {
    "libapp.so": None,  # this application's code
    "libflutter.so": "flutter",
    "libquickjs.so": "QuickJS",
    "libwasm3.so": "Wasm3",
    "libscraper_bridge.so": "html5ever",
    "libzstd-kmp.so": "Zstandard",
    "libdartjni.so": "jni",
    "libdatastore_shared_counter.so": "AndroidX",
    "libsqlite3.so": "sqlite",
    "libirondash_engine_context_native.so": "irondash",
    "libsuper_native_extensions.so": "super_native_extensions",
}
HOST_NOTICES = {
    "OkHttp": "OkHttp",
    "Okio": "Okio",
    "jsoup": "jsoup",
    "RxJava": "RxJava",
    "Kotlin": "Kotlin",
    "kotlinx.coroutines": "kotlinx.coroutines",
    "kotlinx.serialization": "kotlinx.serialization",
    "Injekt": "Injekt",
    "apksig": "apksig",
    "AndroidX": "AndroidX",
    "Mihon source API": "Mihon",
    "zstd-kmp": "zstd-kmp",
}
HOST_NOTICES_ASSET = "assets/flutter_assets/packages/source_runtime_android/notices/android-host-notices.txt"

FORBIDDEN_NAMES = [
    (re.compile(r"\.(apk|aix|jar)$"), "extension artifact"),
    (re.compile(r"(^|/)tachiyomi-[^/]+$"), "Tachi extension artifact"),
    (re.compile(r"(^|/)(capture|captures)\.json$|(^|/)source_captures/"), "capture"),
    (re.compile(r"(^|/)(repo|index|index\.min)\.json$"), "repository configuration"),
    (re.compile(r"(^|/)(artifact|artifacts|versioning|fixtures|index-entry)\.json$"), "fixture/catalog manifest"),
    (re.compile(r"(^|/)test-signing\.p12$"), "test signer"),
    (re.compile(r"^assets/(all\.mangadex|en\.weebcentral|all\.mangafire|android-fixtures)/"), "debug fixture assets"),
    (re.compile(r"(^|/)source\.js$|(^|/)index\.js$"), "Paperback bundle"),
]
FORBIDDEN_STRINGS = [
    b"raw.githubusercontent.com/keiyoushi",
    b"keiyoushi/extensions",
    b"inkdex.github.io",
    b"aidoku-community",
    b"aidoku.invalid",
    b"fixtures.invalid",
]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def build_tool(name):
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk:
        sys.exit("ANDROID_HOME is not set")
    ext = ".bat" if os.name == "nt" and name == "apksigner" else (".exe" if os.name == "nt" else "")
    versions = sorted(
        glob.glob(os.path.join(sdk, "build-tools", "*", name + ext)),
        key=lambda p: [int(x) if x.isdigit() else 0 for x in re.split(r"[.-]", os.path.basename(os.path.dirname(p)))],
    )
    if not versions:
        sys.exit(f"{name} not found under {sdk}/build-tools")
    return versions[-1]


def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=True).stdout


def elf_identity(data):
    if data[:4] != b"\x7fELF":
        return None
    bits = {1: 32, 2: 64}.get(data[4])
    machine = int.from_bytes(data[18:20], "little")
    return {"class": bits, "machine": machine}


def main(argv):
    apk, out = argv[1], argv[2]
    opts = argv[3:]
    allow_test = "--allow-test-payload" in opts
    expect = opts[opts.index("--expect") + 1] if "--expect" in opts else None
    build_dir = opts[opts.index("--build-dir") + 1] if "--build-dir" in opts else None
    variant = opts[opts.index("--variant") + 1] if "--variant" in opts else "release"
    problems = []

    badging = run(build_tool("aapt2"), "dump", "badging", apk)

    def badge(pattern):
        m = re.search(pattern, badging)
        return m.group(1) if m else None

    identity = {
        "package": badge(r"package: name='([^']+)'"),
        "versionCode": badge(r"versionCode='([^']*)'"),
        "versionName": badge(r"versionName='([^']*)'"),
        "minSdk": int(badge(r"(?:sdkVersion|minSdkVersion):'(\d+)'") or 0),
        "targetSdk": int(badge(r"targetSdkVersion:'(\d+)'") or 0),
        "compileSdk": int(badge(r"compileSdkVersion='(\d+)'") or 0),
        "nativeCode": re.findall(r"'([^']+)'", badge(r"native-code:(.*)") or ""),
    }
    if identity["minSdk"] != MIN_SDK:
        problems.append(f"minSdk {identity['minSdk']} != advertised {MIN_SDK}")
    for key in ("targetSdk", "compileSdk"):
        if identity[key] < CURRENT_SDK:
            problems.append(f"{key} {identity[key]} < {CURRENT_SDK}")

    signing_text = subprocess.run(
        [build_tool("apksigner"), "verify", "--verbose", "--print-certs", apk],
        capture_output=True, text=True,
    )
    signing = {
        "verified": signing_text.returncode == 0,
        "schemes": sorted(set(re.findall(r"Verified using (v[\d.]+ scheme[^:]*): true", signing_text.stdout))),
        "signers": [
            {"dn": dn, "sha256": digest}
            for dn, digest in zip(
                re.findall(r"Signer #\d+ certificate DN: (.+)", signing_text.stdout),
                re.findall(r"Signer #\d+ certificate SHA-256 digest: ([0-9a-f]+)", signing_text.stdout),
            )
        ],
    }
    if not signing["verified"]:
        problems.append("apksigner verify failed")

    libraries = []
    notices_text = ""
    host_notices = ""
    payload = []
    forbidden_hits = []
    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        for name in names:
            if name.endswith("/"):
                continue
            for rx, kind in FORBIDDEN_NAMES:
                if rx.search(name):
                    payload.append({"path": name, "kind": kind})
                    break
            if name.startswith("lib/") and name.endswith(".so"):
                abi, lib = name.split("/")[1], name.split("/")[-1]
                data = z.read(name)
                elf = elf_identity(data)
                libraries.append({"path": name, "abi": abi, "bytes": len(data), "sha256": sha256(data), "elf": elf})
                if elf is None or ELF_MACHINES.get(abi) not in (None, elf["machine"]):
                    problems.append(f"{name}: ELF machine {elf} does not match {abi}")
                if lib not in NATIVE_NOTICES:
                    problems.append(f"{name}: no notice rule for this native library")
            if name.endswith(".dex") or name.endswith("libapp.so"):
                data = z.read(name)
                for needle in FORBIDDEN_STRINGS:
                    if needle in data:
                        forbidden_hits.append({"path": name, "string": needle.decode()})
        if "assets/flutter_assets/NOTICES.Z" in names:
            notices_text = zlib.decompress(z.read("assets/flutter_assets/NOTICES.Z"), zlib.MAX_WBITS | 32).decode("utf-8", "replace")
        else:
            problems.append("assets/flutter_assets/NOTICES.Z missing")
        if HOST_NOTICES_ASSET in names:
            host_notices = z.read(HOST_NOTICES_ASSET).decode("utf-8", "replace")
        else:
            problems.append(f"{HOST_NOTICES_ASSET} missing (notices of the bundled Android host libraries)")

    for abi in ADVERTISED_ABIS:
        for lib in RUNTIME_LIBRARIES:
            if not any(l["path"] == f"lib/{abi}/{lib}" for l in libraries):
                problems.append(f"lib/{abi}/{lib} missing")

    all_notices = notices_text + "\n" + host_notices
    notice_report = {}
    for lib in sorted({l["path"].split("/")[-1] for l in libraries}):
        phrase = NATIVE_NOTICES.get(lib)
        if phrase is None:
            continue
        found = phrase.lower() in all_notices.lower()
        notice_report[lib] = found
        if not found:
            problems.append(f"no notice for {lib} (expected '{phrase}')")
    for name, phrase in HOST_NOTICES.items():
        found = phrase.lower() in host_notices.lower()
        notice_report[name] = found
        if not found:
            problems.append(f"no notice for bundled host library {name} (expected '{phrase}' in {HOST_NOTICES_ASSET})")

    if (payload or forbidden_hits) and not allow_test:
        for p in payload:
            problems.append(f"release payload holds {p['kind']}: {p['path']}")
        for h in forbidden_hits:
            problems.append(f"{h['path']} names a repository: {h['string']}")

    if expect:
        earlier = {l["path"]: l["sha256"] for l in json.load(open(expect))["nativeLibraries"]}
        now = {l["path"]: l["sha256"] for l in libraries}
        if earlier != now:
            changed = sorted(set(earlier.items()) ^ set(now.items()))
            problems.append(f"native library hashes differ from {expect}: {changed}")

    build_outputs = None
    if build_dir:
        def libs_under(root):
            found = {}
            for path in glob.glob(os.path.join(root, "**", "lib", "*", "*.so"), recursive=True):
                parts = path.replace(os.sep, "/").split("/")
                with open(path, "rb") as f:
                    found["lib/" + parts[-2] + "/" + parts[-1]] = sha256(f.read())
            return found
        stripped = libs_under(os.path.join(build_dir, "app", "intermediates", "stripped_native_libs", variant))
        hooks = libs_under(os.path.join(build_dir, "app", "intermediates", "flutter", variant, "native_assets"))
        mismatched = [l["path"] for l in libraries if stripped.get(l["path"]) != l["sha256"]]
        if not stripped:
            problems.append(f"no stripped native libraries under {build_dir} for {variant}")
        for path in mismatched:
            problems.append(f"{path}: APK bytes differ from the build's stripped output")
        build_outputs = {
            "variant": variant,
            "matchedStripped": len(libraries) - len(mismatched),
            "hookOutputsUnstripped": [{"path": k, "sha256": v} for k, v in sorted(hooks.items())],
        }

    with open(apk, "rb") as f:
        apk_sha = sha256(f.read())
    record = {
        "apk": os.path.basename(apk),
        "apkSha256": apk_sha,
        "apkBytes": os.path.getsize(apk),
        "identity": identity,
        "signing": signing,
        "nativeLibraries": libraries,
        "buildOutputs": build_outputs,
        "notices": notice_report,
        "noticesBytes": len(notices_text),
        "hostNoticesBytes": len(host_notices),
        "testPayload": {"allowed": allow_test, "entries": len(payload), "kinds": sorted({p["kind"] for p in payload}), "repositoryStrings": forbidden_hits},
        "problems": problems,
        "pass": not problems,
    }
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
    for p in problems:
        print(f"FAIL {p}", file=sys.stderr)
    print(f"{'PASS' if not problems else 'FAIL'} {apk} -> {out}")
    return 0 if not problems else 1


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv))
