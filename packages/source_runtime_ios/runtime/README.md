# Runtime payload (staged, not committed)

`tools/tachi-source-runner/ios/scripts/stage_runtime.sh` copies the built
modular runtime image and the U16 gate fixtures into this directory as flat
files plus `layout.txt`, which maps each flat file to its path under
`java.home`. Flutter bundles them as package assets; at start-up the Dart side
recreates `java.home` with symbolic links into the app bundle.

Only this README is committed. Without a staged payload the runtime reports
that it is not available; nothing pretends to succeed.
