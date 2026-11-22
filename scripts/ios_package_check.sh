#!/usr/bin/env bash
# U15: records and checks one built iOS app bundle (R18, Evidence Identity).
#
#   scripts/ios_package_check.sh <Runner.app> <out.json> [--allow-test-payload] [--debug-engine]
#
#   --allow-test-payload  a test build staged with `stage_runtime.sh --test`
#   --debug-engine        a debug build: Flutter's JIT engine may import
#                         sys_icache_invalidate (never allowed in release)
#
# Build inputs, for example:
#   flutter build ios --release --no-codesign            # iphoneos slice
#   flutter build ios --debug --simulator                # iphonesimulator slice
#
# For the app executable and every framework it records the slice identity
# (platform, architecture, minimum OS, SDK), size, SHA-256, linked libraries
# and the embedded code signature, then fails (exit 1) when:
#   - a binary's minimum OS is above the app's MinimumOSVersion, or the
#     project's IPHONEOS_DEPLOYMENT_TARGET differs from the runtime minimum
#     (15.0, U16), or a binary is not for the expected platform;
#   - a binary links a library from outside the bundle or the system;
#   - a binary imports a JIT or executable-memory API
#     (pthread_jit_write_protect_np, sys_icache_invalidate, vm_protect,
#     mach_vm_protect, MAP_JIT users), or `mprotect`/`mmap`/`dlopen` outside
#     the allow-list below (each entry is explained in
#     docs/validation/source-runners/ios/app-store-compliance.md);
#   - a required-reason API category imported by any binary is missing from
#     the app's PrivacyInfo.xcprivacy;
#   - the payload holds an extension artifact or repository configuration
#     (.aix, .apk, tachiyomi-*.jar, Paperback bundles, capture files,
#     repo.json/index*.json, test signer, gate fixtures) or names a known
#     repository host in the Dart snapshot or assets, unless
#     --allow-test-payload (a test build staged with --test);
#   - the GPL notices of the embedded runtime are absent;
#   - a shipped library has no entry with its full licence text in the
#     generated notices asset (packages/source_runtime_ios/notices/
#     third_party_notices.json, scripts/generate_notices.dart ios): every
#     Tachi host class path JAR in the runtime payload (by artifact and
#     version), the vendored code of each framework, and every Rust crate of
#     a Rust-based plugin framework (cargo metadata for the slice's
#     triple); frameworks of Dart packages need their notice in Flutter's
#     NOTICES.Z, and a framework without a rule fails.
set -euo pipefail

app="${1:?usage: ios_package_check.sh <Runner.app> <out.json> [--allow-test-payload]}"
out="${2:?usage: ios_package_check.sh <Runner.app> <out.json> [--allow-test-payload]}"
opts="${*:3}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

exec /usr/bin/python3 -I - "$app" "$out" "$repo" "$opts" <<'PY'
import hashlib, json, os, plistlib, re, subprocess, sys

app, out, repo = sys.argv[1], sys.argv[2], sys.argv[3]
opts = sys.argv[4].split()
allow_test = "--allow-test-payload" in opts
debug_engine = "--debug-engine" in opts
RUNTIME_MIN = "15.0"
problems = []

def run(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()

def vers(v):
    return tuple(int(x) for x in v.split("."))

info = plistlib.load(open(os.path.join(app, "Info.plist"), "rb"))
app_min = info.get("MinimumOSVersion")
exe = os.path.join(app, info["CFBundleExecutable"])
pbx = open(os.path.join(repo, "ios/Runner.xcodeproj/project.pbxproj")).read()
project_targets = sorted(set(re.findall(r"IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);", pbx)))
if project_targets != [RUNTIME_MIN]:
    problems.append(f"project deployment targets {project_targets} != runtime minimum {RUNTIME_MIN}")
if app_min is None or vers(app_min) != vers(RUNTIME_MIN):
    problems.append(f"MinimumOSVersion {app_min} != runtime minimum {RUNTIME_MIN}")

binaries = [("Runner", exe)]
fw = os.path.join(app, "Frameworks")
for name in sorted(os.listdir(fw)) if os.path.isdir(fw) else []:
    p = os.path.join(fw, name)
    if name.endswith(".framework"):
        plist = os.path.join(p, "Info.plist")
        exe_name = plistlib.load(open(plist, "rb")).get("CFBundleExecutable", name[:-10]) if os.path.exists(plist) else name[:-10]
        binaries.append((name, os.path.join(p, exe_name)))
    elif name.endswith(".dylib"):
        binaries.append((name, p))

JIT = {"_pthread_jit_write_protect_np", "_sys_icache_invalidate", "_vm_protect", "_mach_vm_protect",
       "_pthread_jit_write_with_callback_np", "_mach_vm_remap", "_vm_remap"}
# JIT-list imports whose call sites are traced in app-store-compliance.md.
JIT_EXPLAINED = {
    "source_runtime_ios.framework": {"_vm_remap", "_vm_protect"},  # libffi trampoline table, unreachable
    # The stock release Flutter engine (Dart VM virtual memory; AOT on iOS
    # never generates code). Every App Store Flutter app ships it.
    "Flutter.framework": {"_vm_remap"},
}
if debug_engine:
    JIT_EXPLAINED["Flutter.framework"] |= {"_sys_icache_invalidate"}  # Dart JIT, debug engine only
# Imports allowed only where the compliance note explains them.
PLUGINS = {"Runner", "sqlite3.framework", "super_native_extensions.framework"}  # existing app plugins
ALLOWED = {
    "_mmap": {"source_runtime_ios.framework", "App.framework", "Flutter.framework"} | PLUGINS,
    "_mprotect": {"source_runtime_ios.framework", "App.framework", "Flutter.framework"},
    "_dlopen": {"source_runtime_ios.framework", "Flutter.framework"} | PLUGINS,
}
REQUIRED_REASON = {
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"_stat", "_lstat", "_fstat", "_fstatat", "_stat64", "_lstat64",
        "_fstat64", "_getattrlist", "_getattrlistbulk", "_fgetattrlist", "_getattrlistat", "_setattrlist", "_utimes",
        "_futimes", "_utimensat", "_futimens"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"_mach_absolute_time"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"_statfs", "_fstatfs", "_statvfs", "_fstatvfs", "_getattrlist"},
    "NSPrivacyAccessedAPICategoryActiveKeyboards": set(),
    "NSPrivacyAccessedAPICategoryUserDefaults": set(),
}
SYSTEM = ("/usr/lib/", "/System/Library/")
records, categories_needed = [], {}
platform_expected = None
for label, path in binaries:
    build = run("vtool", "-show-build", path)
    plat = re.search(r"platform (\w+)", build)
    minos = re.search(r"minos ([0-9.]+)", build)
    sdk = re.search(r"sdk ([0-9.]+)", build)
    archs = run("lipo", "-archs", path).split()
    sig = subprocess.run(["codesign", "-dv", "--verbose=2", path], capture_output=True, text=True).stderr
    signature = ("unsigned" if "not signed" in sig else
                 "adhoc" if "Signature=adhoc" in sig else
                 (re.search(r"Authority=(.*)", sig).group(1) if re.search(r"Authority=(.*)", sig) else "signed"))
    # Indented lines only: headers name the binary (one per architecture).
    links = sorted({l.strip().split(" (")[0] for l in run("otool", "-L", path).splitlines()
                    if l[:1].isspace() and l.strip()})
    undefined = set(run("nm", "-u", path).split())
    rec = {
        "binary": label, "sha256": sha256(path), "bytes": os.path.getsize(path),
        "platform": plat.group(1) if plat else None, "minos": minos.group(1) if minos else None,
        "sdk": sdk.group(1) if sdk else None, "archs": archs, "signature": signature, "links": links,
        "jitImports": sorted(undefined & JIT),
        "jitImportsExplained": sorted(undefined & JIT & JIT_EXPLAINED.get(label, set())),
        "restrictedImports": sorted(s for s in ALLOWED if s in undefined),
    }
    records.append(rec)
    if platform_expected is None:
        platform_expected = rec["platform"]
    elif rec["platform"] != platform_expected:
        problems.append(f"{label}: platform {rec['platform']} != app {platform_expected}")
    if rec["minos"] and app_min and vers(rec["minos"]) > vers(app_min):
        problems.append(f"{label}: minos {rec['minos']} > MinimumOSVersion {app_min}")
    unexplained = sorted(set(rec["jitImports"]) - JIT_EXPLAINED.get(label, set()))
    if unexplained:
        problems.append(f"{label}: imports JIT/executable-memory APIs {unexplained}")
    for s in rec["restrictedImports"]:
        if label not in ALLOWED[s]:
            problems.append(f"{label}: imports {s[1:]} (not on the explained allow-list)")
    for l in links:
        if not (l.startswith(SYSTEM) or l.startswith("@rpath/") or l.startswith("@executable_path/")):
            problems.append(f"{label}: links outside the bundle/system: {l}")
    for cat, syms in REQUIRED_REASON.items():
        hit = sorted(undefined & syms)
        if hit:
            categories_needed.setdefault(cat, {})[label] = hit

privacy_path = os.path.join(app, "PrivacyInfo.xcprivacy")
declared = set()
if os.path.exists(privacy_path):
    pm = plistlib.load(open(privacy_path, "rb"))
    declared = {d["NSPrivacyAccessedAPIType"] for d in pm.get("NSPrivacyAccessedAPITypes", [])}
else:
    problems.append("Runner.app has no PrivacyInfo.xcprivacy")
def own_manifest(label):
    # A framework may ship its own manifest (Flutter.framework does).
    pm_path = os.path.join(fw, label, "PrivacyInfo.xcprivacy")
    if label == "Runner" or not os.path.exists(pm_path):
        return set()
    pm = plistlib.load(open(pm_path, "rb"))
    return {d["NSPrivacyAccessedAPIType"] for d in pm.get("NSPrivacyAccessedAPITypes", [])}
for cat, users in categories_needed.items():
    missing = sorted(u for u in users if cat not in declared and cat not in own_manifest(u))
    if missing:
        problems.append(f"privacy manifest lacks {cat} (imported by {missing})")

# Payload: no extension artifact or repository configuration.
PATTERNS = [r"\.aix$", r"\.apk$", r"tachiyomi-.*\.jar$", r"(^|/|__)index\.js$", r"capture\.json$", r"scenario\.json$",
            r"(^|/|__)repo\.json$", r"(^|/|__)index(\.min)?\.json$", r"index-entry\.json$", r"versioning\.json$",
            r"artifacts\.json$", r"test-signer\.txt$", r"(^|/|__)gate(__|/)", r"testdata", r"aidoku_fixture"]
payload_hits = []
for root, _, files in os.walk(app):
    for f in files:
        rel = os.path.relpath(os.path.join(root, f), app)
        if any(re.search(p, rel) for p in PATTERNS):
            payload_hits.append(rel)
layout = os.path.join(app, "Frameworks/App.framework/flutter_assets/packages/source_runtime_ios/runtime/layout.txt")
layout_kinds = []
if os.path.exists(layout):
    layout_kinds = sorted({l.split("\t")[0] for l in open(layout) if l.strip() and not l.startswith("#")})
    if {"test", "gate", "fixture"} & set(layout_kinds):
        payload_hits.append(f"layout.txt lists {sorted({'test','gate','fixture'} & set(layout_kinds))} entries")
REPO_HOSTS = [b"raw.githubusercontent.com/keiyoushi", b"keiyoushi/extensions", b"inkdex.github.io", b"aidoku.invalid",
              b"aidoku-community", b"paperback-community"]
host_hits = []
for root, _, files in os.walk(app):
    for f in files:
        p = os.path.join(root, f)
        try:
            data = open(p, "rb").read()
        except OSError:
            continue
        for h in REPO_HOSTS:
            if h in data:
                host_hits.append(f"{os.path.relpath(p, app)}: {h.decode()}")
if (payload_hits or host_hits) and not allow_test:
    problems.extend(f"payload: {x}" for x in payload_hits + host_hits)

legal = os.path.join(app, "Frameworks/App.framework/flutter_assets/packages/source_runtime_ios/runtime")
gpl_notices = sorted(f for f in os.listdir(legal) if f.startswith("home__legal__")) if os.path.isdir(legal) else []
for need in ("home__legal__LICENSE", "home__legal__ASSEMBLY_EXCEPTION", "home__legal__ADDITIONAL_LICENSE_INFO"):
    if need not in gpl_notices:
        problems.append(f"GPL notice {need} missing from the runtime payload")

# Third-party notices: the expected set comes from what the bundle ships.
import zlib
assets = os.path.join(app, "Frameworks/App.framework/flutter_assets")
notices_text = ""
if os.path.exists(os.path.join(assets, "NOTICES.Z")):
    notices_text = zlib.decompress(open(os.path.join(assets, "NOTICES.Z"), "rb").read(), zlib.MAX_WBITS | 32).decode("utf-8", "replace")
else:
    problems.append("Flutter NOTICES.Z missing")
notices_path = os.path.join(assets, "packages/source_runtime_ios/notices/third_party_notices.json")
notices = json.load(open(notices_path, encoding="utf-8")) if os.path.exists(notices_path) else None
if notices is None:
    problems.append("packages/source_runtime_ios/notices/third_party_notices.json missing (generated third-party notices)")
with_text = set()
for c in (notices or {}).get("components", []):
    keys, texts = c.get("texts", []), notices.get("texts") or {}
    # Every named text exists and at least one is a full licence.
    if keys and all(k in texts for k in keys) and any(len(texts[k].strip()) >= 200 for k in keys):
        with_text.add(c["id"])
    else:
        problems.append(f"notices: {c.get('id')} has no full licence text")
expected = {}
# Tachi host class path: <artifact>-<version>.jar from the worker's installDist
# (ios-host.jar and tachi-source-runner-*.jar are this repository's code).
jar_names = {}
for cid in with_text:
    if cid.startswith("maven:"):
        _, g, a, v = cid.split(":")
        jar_names[f"{a}-{v}.jar"] = cid
classpath = [l.split("\t")[1] for l in open(layout) if l.startswith("classpath\t")] if os.path.exists(layout) else []
for flat in classpath:
    jar = flat[len("cp__"):]
    if jar == "ios-host.jar" or jar.startswith("tachi-source-runner-"):
        continue
    if jar not in jar_names:
        problems.append(f"no notices entry with text for class path JAR {jar}")
if classpath:
    expected["vendored:mihon-source-api"] = "tachi-source-runner JAR (extracted Mihon source API)"
# Frameworks: vendored components, NOTICES.Z phrases, Rust trees.
FRAMEWORK_NOTICES = {
    "Runner": {}, "App.framework": {},  # this application's code
    "Flutter.framework": {"flutter": "flutter"},
    "source_runtime_ios.framework": {"components": ["vendored:libffi", "vendored:zstd"]},  # + GPL notices above
    "quickjs.framework": {"components": ["vendored:quickjs-ng"]},
    "wasm3.framework": {"components": ["vendored:wasm3"]},
    "SwiftSoupWrapper.framework": {"components": ["vendored:swiftsoup", "vendored:swift-atomics", "vendored:lrucache"]},
    "CocoaAsyncSocket.framework": {"components": ["vendored:cocoaasyncsocket"]},
    "objective_c.framework": {"flutter": "objective_c"},
    "sqlite3.framework": {"flutter": "sqlite"},
    "device_info_plus.framework": {"flutter": "device_info_plus"},
    "patrol.framework": {"flutter": "patrol"},
    "irondash_engine_context.framework": {"flutter": "irondash"},
    "super_native_extensions.framework": {"flutter": "super_native_extensions", "rust": ("super_native_extensions", "rust/Cargo.toml")},
}
TRIPLES = {"IOS": "aarch64-apple-ios", "IOSSIMULATOR": "aarch64-apple-ios-sim"}
def pub_root(name):
    import urllib.parse, urllib.request
    for pkg in json.load(open(os.path.join(repo, ".dart_tool/package_config.json")))["packages"]:
        if pkg["name"] == name:
            u = urllib.parse.urlparse(pkg["rootUri"])
            return urllib.request.url2pathname(u.path) if u.scheme == "file" else os.path.normpath(os.path.join(repo, ".dart_tool", pkg["rootUri"]))
    raise RuntimeError(f"{name} not in .dart_tool/package_config.json")
notice_report = {}
for label, _ in binaries:
    rule = FRAMEWORK_NOTICES.get(label)
    if rule is None:
        problems.append(f"{label}: no notice rule for this framework")
        continue
    ok = True
    if "flutter" in rule and rule["flutter"].lower() not in notices_text.lower():
        problems.append(f"no NOTICES.Z notice for {label} (expected '{rule['flutter']}')"); ok = False
    for cid in rule.get("components", []):
        if cid not in with_text:
            problems.append(f"no notices entry with text for {label} ({cid})"); ok = False
    if "rust" in rule:
        manifest = os.path.join(pub_root(rule["rust"][0]), rule["rust"][1])
        r = subprocess.run(["cargo", "metadata", "--locked", "--format-version", "1", "--filter-platform",
                            TRIPLES.get(platform_expected, "aarch64-apple-ios"), "--manifest-path", manifest],
                           capture_output=True, text=True)
        if r.returncode != 0:
            problems.append(f"cannot list the Rust crates of {label}: {r.stderr.strip()[:300]}"); ok = False
        else:
            meta = json.loads(r.stdout)
            nodes = {n["id"] for n in meta["resolve"]["nodes"]}
            for p in meta["packages"]:
                if p["id"] in nodes:
                    expected.setdefault(f"crate:{p['name']}@{p['version']}", label)
    notice_report[label] = ok
missing_notices = sorted(i for i in expected if i not in with_text)
problems.extend(f"no notices entry with text for {i} (shipped: {expected[i]})" for i in missing_notices)

ent = subprocess.run(["codesign", "-d", "--entitlements", ":-", exe], capture_output=True, text=True).stdout
result = {
    "app": os.path.basename(app),
    "bundleId": info.get("CFBundleIdentifier"),
    "version": f"{info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})",
    "minimumOSVersion": app_min, "runtimeMinimum": RUNTIME_MIN, "projectDeploymentTargets": project_targets,
    "platform": platform_expected, "entitlements": ent.strip() or None,
    "binaries": records,
    "requiredReasonApis": {k: v for k, v in categories_needed.items()}, "privacyManifestDeclares": sorted(declared),
    "payloadTestOnlyFiles": payload_hits, "payloadRepositoryReferences": host_hits,
    "runtimeLayoutKinds": layout_kinds, "gplNotices": gpl_notices,
    "thirdPartyNotices": {"components": len((notices or {}).get("components", [])), "withText": len(with_text),
                          "classPathJars": len(classpath), "frameworks": notice_report, "missing": missing_notices},
    "testPayloadAllowed": allow_test, "debugEngine": debug_engine, "problems": problems, "pass": not problems,
}
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
json.dump(result, open(out, "w"), indent=2)
print(json.dumps({"pass": result["pass"], "problems": problems}, indent=2))
sys.exit(0 if result["pass"] else 1)
PY
