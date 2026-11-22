# Licence texts and the notices mechanism

One mechanism produces the full licence texts of every third-party library the products ship, for the
desktop CLI package, the Android APK and the iOS app: `notices.dart` in this directory.

| Kind | Source of the text |
| --- | --- |
| Rust crates | `cargo metadata --locked --filter-platform <triple>`; each crate's published licence files, else the canonical text of each licence in its SPDX expression (files here; `MIT.txt` with the crate's authors as `{{holders}}`); this repository's crates get its `LICENSE.md`, a plugin's own crates its package licence |
| Maven artifacts | what Gradle resolved for the shipped configuration (`license-inputs.gradle`, an init script run through the build's wrapper): the licence and notice files inside the JAR/AAR, else the canonical text of a POM-declared licence that names no holder (`Apache-2.0.txt`), else an override in `components.json` |
| Vendored native code | the files listed under `vendored` in `components.json` |

Everything fails closed: a component without a text, or a holder-naming licence (MIT, BSD) with no licence file and no
override, is an error. Overrides point at upstream licence files committed under `texts/` with their source URL and
SHA-256 in `components.json` (`upstream`); `texts/` is byte-exact (`-text`), and the generator checks the digests.

Uses:

- `scripts/package_cli.dart` (desktop package): `licenses/rust/<tree>/<crate>-<version>/` and `<tree>-crates.txt`.
- `scripts/generate_notices.dart android|ios [--check]`: the app notices assets
  `packages/source_runtime_android/notices/third_party_notices.json` and
  `packages/source_runtime_ios/notices/third_party_notices.json`, from `components.json` `targets`. Regenerate and
  commit after a dependency change; CI checks the Android asset is current. Needs `android/gradlew` (created by
  `flutter build apk`) or the Tachi worker's wrapper, a JDK, and cargo; Gradle and cargo may download POMs and crate
  sources on the first run.
- `scripts/android_package_check.py` and `scripts/ios_package_check.sh` fail when a shipped library has no entry with
  a full text; they derive what ships from the APK/app bundle, the lockfile and cargo, not from the asset.

`Apache-2.0.txt` and `MPL-2.0.txt` are the unmodified texts, copied from the `html5ever` and `cssparser` crates.
