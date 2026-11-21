#!/usr/bin/env bash
# Builds the synthetic Tachi fixture extensions for the U11 Android tests into
# real APKs of original DEX, signed with a test-only key, in the layout of a
# committed capture so tachi_plugin_loader's testing helpers can serve them:
#
#   fixtures/source_captures/tachi-android/android-fixtures/<package>/
#     index-entry.json, desktop-artifacts.json, <package>.apk
#   fixtures/source_captures/tachi-android/android-fixtures/fixtures.json
#
# Requirements: JAVA_HOME (JDK 21), ANDROID_SDK_ROOT with build-tools 36.0.0
# and platforms;android-36, python3. Run from anywhere:
#   tools/tachi-source-runner/android/fixtures/build_fixtures.sh
# The outputs are committed; rerun after editing kotlin/fixture/android/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
runner="$(cd "$here/../.." && pwd)"
repo="$(cd "$runner/../.." && pwd)"
sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:?set ANDROID_SDK_ROOT}}"
bt="$sdk/build-tools/36.0.0"
android_jar="$sdk/platforms/android-36/android.jar"
ext=""; case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ext=".bat";; esac
aapt2="$bt/aapt2"; [ -x "$aapt2.exe" ] && aapt2="$aapt2.exe"
zipalign="$bt/zipalign"; [ -x "$zipalign.exe" ] && zipalign="$zipalign.exe"
d8="$bt/d8$ext"
apksigner="$bt/apksigner$ext"
keystore="$here/test-signing.p12"
out="$repo/fixtures/source_captures/tachi-android/android-fixtures"
work="$runner/build/android-fx/work"

(cd "$runner" && ./gradlew androidFixtureJar --console=plain -q)
classpath="$(cd "$runner" && ./gradlew printRuntimeClasspath --console=plain -q | tail -1)"
fixture_jar="$runner/build/android-fx/android-fixtures.jar"

if [ ! -f "$keystore" ]; then
  "$JAVA_HOME/bin/keytool" -genkeypair -keystore "$keystore" -storetype PKCS12 -storepass fixture -keypass fixture \
    -alias fixture -keyalg RSA -keysize 2048 -validity 36500 -dname "CN=U11 Android fixture signer (test only)"
fi

rm -rf "$work" "$out"
mkdir -p "$work" "$out"

# name , manifest package , factory class , class prefixes (besides FixtureSource)
fixtures=(
  "busy,fixture.android.busy,fixture.android.BusyFactory,Busy"
  "prefs,fixture.android.prefs,fixture.android.PrefsFactory,Prefs"
  "big,fixture.android.big,fixture.android.BigFactory,Big"
  "dup,fixture.android.dup,fixture.android.DupFactory,Dup"
  "dup2,fixture.android.dup2,fixture.android.DupFactory,Dup"
  "cookies,fixture.android.cookies,fixture.android.CookiesFactory,Cookies"
)

python3 -I - "$fixture_jar" "$work" "${fixtures[@]}" <<'PY'
import sys, zipfile, os
jar, work, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
src = zipfile.ZipFile(jar)
for spec in specs:
    name, pkg, factory, prefix = spec.split(",")
    d = os.path.join(work, name); os.makedirs(d, exist_ok=True)
    with zipfile.ZipFile(os.path.join(d, 'classes.jar'), 'w') as z:
        for e in src.namelist():
            base = e.rsplit('/', 1)[-1]
            if e.startswith('fixture/android/') and (base.startswith('FixtureSource') or base.startswith(prefix)):
                z.writestr(e, src.read(e))
    with open(os.path.join(d, 'AndroidManifest.xml'), 'w', newline='\n') as m:
        m.write(f'''<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{pkg}"
    android:versionCode="1" android:versionName="1.6.1">
    <uses-feature android:name="tachiyomi.extension" />
    <application android:label="Tachiyomi: U11 {name} fixture" android:hasCode="true">
        <meta-data android:name="tachiyomi.extension.class" android:value="{factory}" />
        <meta-data android:name="tachiyomix.extensionLib" android:value="1.6" />
    </application>
</manifest>
''')
PY

lib_args=(--lib "$android_jar")
sep=':'; [ -n "$ext" ] && sep=';'
IFS="$sep" read -r -a cp_entries <<< "$classpath"
for e in "${cp_entries[@]}"; do [ -e "$e" ] && lib_args+=(--classpath "$e"); done

for spec in "${fixtures[@]}"; do
  IFS=',' read -r name pkg factory prefix <<< "$spec"
  d="$work/$name"
  "$d8" --release --min-api 28 "${lib_args[@]}" --output "$d" "$d/classes.jar"
  "$aapt2" link --manifest "$d/AndroidManifest.xml" -I "$android_jar" --min-sdk-version 28 --target-sdk-version 36 -o "$d/base.apk"
  python3 -I -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"a"); z.write(sys.argv[2],"classes.dex"); z.close()' "$d/base.apk" "$d/classes.dex"
  "$zipalign" -f -p 4 "$d/base.apk" "$d/aligned.apk"
  mkdir -p "$out/$pkg"
  "$apksigner" sign --ks "$keystore" --ks-pass pass:fixture --key-pass pass:fixture --min-sdk-version 28 \
    --v1-signing-enabled false --v2-signing-enabled true --out "$out/$pkg/$pkg.apk" "$d/aligned.apk"
  rm -f "$out/$pkg/$pkg.apk.idsig"
done

python3 -I - "$out" "$keystore" "${fixtures[@]}" <<'PY'
import sys, json, hashlib, os, subprocess
out, keystore, specs = sys.argv[1], sys.argv[2], sys.argv[3:]
names = {'busy': ['Android Busy'], 'prefs': ['Android Prefs'], 'big': ['Android Big'], 'dup': ['Android Dup'],
         'dup2': ['Android Dup'], 'cookies': ['Android Cookies A', 'Android Cookies B']}
def source_id(name, lang='en', version=1):
    b = hashlib.md5(f'{name.lower()}/{lang}/{version}'.encode()).digest()
    return str(int.from_bytes(b[:8], 'big') & 0x7FFFFFFFFFFFFFFF)
# The signer: SHA-256 of the certificate in the APK signing block, read back with keytool.
cert = subprocess.run([os.path.join(os.environ['JAVA_HOME'], 'bin', 'keytool'), '-exportcert', '-keystore', keystore,
                       '-storepass', 'fixture', '-alias', 'fixture'], capture_output=True, check=True).stdout
fingerprint = hashlib.sha256(cert).hexdigest()
base = 'https://fixtures.invalid/u11/repo'
summary = {'format': 1, 'notes': 'Synthetic U11 fixture extensions (test-only signer); built by '
           'tools/tachi-source-runner/android/fixtures/build_fixtures.sh. No network.',
           'repository': base, 'signingKeyFingerprint': fingerprint, 'packages': {}}
for spec in specs:
    name, pkg, factory, prefix = spec.split(",")
    d = os.path.join(out, pkg)
    apk = os.path.join(d, f'{pkg}.apk')
    sha = hashlib.sha256(open(apk, 'rb').read()).hexdigest()
    sources = [{'id': source_id(n), 'name': n, 'language': 'en', 'homeUrl': 'https://fixture.test'} for n in names[name]]
    entry = {'name': f'U11 {name}', 'packageName': pkg,
             'resources': {'apkUrl': f'{base}/apk/{pkg}.apk'},
             'extensionLib': '1.6', 'versionCode': '1', 'versionName': '1.6.1',
             'contentWarning': 'CONTENT_WARNING_SAFE', 'sources': sources}
    json.dump(entry, open(os.path.join(d, 'index-entry.json'), 'w', newline='\n'), indent=2)
    artifacts = {'format': 1, 'artifacts': [
        {'kind': 'apk', 'path': f'{pkg}.apk', 'sourceUrl': f'{base}/apk/{pkg}.apk', 'sha256': sha},
        {'kind': 'jar', 'path': 'absent.jar', 'sourceUrl': f'{base}/absent/{pkg}.jar', 'sha256': ''},
    ]}
    json.dump(artifacts, open(os.path.join(d, 'desktop-artifacts.json'), 'w', newline='\n'), indent=2)
    summary['packages'][pkg] = {'fixture': name, 'sha256': sha, 'sources': sources}
json.dump(summary, open(os.path.join(out, 'fixtures.json'), 'w', newline='\n'), indent=2)
print('signer', fingerprint)
PY

# The busy fixture re-signed with a second, throwaway key generated per build
# (never committed): same code, a signer the fixture repository does not trust
# (the re-signing rejection case).
other="$work/other-signing.p12"
"$JAVA_HOME/bin/keytool" -genkeypair -keystore "$other" -storetype PKCS12 -storepass untrusted -keypass untrusted \
  -alias other -keyalg RSA -keysize 2048 -validity 3650 -dname "CN=U11 untrusted re-signer (test only)"
mkdir -p "$out/resigned"
"$apksigner" sign --ks "$other" --ks-pass pass:untrusted --key-pass pass:untrusted --min-sdk-version 28 \
  --v1-signing-enabled false --v2-signing-enabled true \
  --out "$out/resigned/fixture.android.busy-resigned.apk" "$out/fixture.android.busy/fixture.android.busy.apk"
rm -f "$out/resigned/"*.idsig
