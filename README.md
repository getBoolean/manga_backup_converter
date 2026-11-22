# Manga Backup Converter <!-- omit in toc -->

[![latest release](https://img.shields.io/github/release/getBoolean/manga_backup_converter.svg?maxAge=3600&label=download)](https://github.com/getBoolean/manga_backup_converter/releases)
[![coverage](https://img.shields.io/codecov/c/github/getBoolean/manga_backup_converter)](https://app.codecov.io/gh/getBoolean/manga_backup_converter)

Convert manga backup files between formats. Available as a standalone CLI with a Flutter app planned.

**[Download latest release](https://github.com/getBoolean/manga_backup_converter/releases/latest)**

## Supported Formats

| App | Extension |
|-----|-----------|
| [Aidoku](https://aidoku.app/) | `.aib` |
| [Paperback](https://paperback.moe/) | `.pas4` |
| [Mihon](https://mihon.app/) and forks (TachiyomiSY, TachiyomiJ2K, Yokai, Neko) | `.tachibk`, `.proto.gz` |
| [Tachimanga](https://tachimanga.app/) | `.tmb` |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | `.backup` |

## Feature Support

| Format | Import | Direct conversion | Export via plugin migration | Merge |
|--------|:------:|:------------------:|:--------------------------:|:-----:|
| Aidoku | :white_check_mark: | — | :white_check_mark: | :white_check_mark: |
| Paperback | :white_check_mark: | — | :x: | :x: |
| Tachi | :white_check_mark: | :arrow_right: Tachimanga | :x: | :x: |
| Tachimanga | :white_check_mark: | :arrow_right: Tachi | :x: | :x: |
| Mangayomi | :white_check_mark: | — | :x: | :x: |

- **Direct conversion** preserves data 1:1 between Tachi and Tachimanga without needing plugins.
- **Plugin migration** uses Aidoku source extensions to search and match manga, then builds a backup in the target format. Currently only Aidoku is supported as a target.
- **Merge** combines two Aidoku backups into one, deduplicating manga entries.

## CLI Usage

### Convert

Convert a backup to another format. Runs interactively when a terminal is available, prompting for any missing options.

```sh
mangabackuputil convert -b <backup-file> -f <output-format> [-o <output-path>] [-r <repo-url>...]
```

| Option | Description |
|--------|-------------|
| `-b, --backup` | Path to the backup file |
| `-f, --output-format` | Target format (`aidoku`, `paperback`, `mihon`, `sy`, `j2k`, `yokai`, `neko`, `tachimanga`, `mangayomi`) |
| `-i, --input-format` | Override auto-detected input format |
| `-r, --repos` | Extension repo URLs for plugin-based migration |
| `-o, --output` | Output file path (default: `<input>_converted.<ext>`) |
| `-l, --log-file` | Log file path for interactive mode |
| `-v, --verbose` | Show additional output |
| `--webview-helper` | Desktop WebView helper manifest (defaults to the packaged runtime) |
| `--tachi-runtime` | Tachi worker runtime manifest (defaults to the packaged runtime) |

#### Desktop package and prerequisites

Release packages (`mangabackupconverter-cli-windows.zip`, the Windows installer, and the Linux/macOS archives) carry
everything the source runners need: the Tachi JVM worker with a bundled Amazon Corretto 21 runtime (at or above the
21.0.13.1 security floor), the Paperback worker (the CLI executable itself), and the desktop WebView helper. No system
Java, Dart, Gradle or Rust is needed. Keep the package's `bin/`, `lib/` and `runtime/` directories together.

The WebView helper uses the platform's WebView, which is not bundled:

- **Windows:** Microsoft Edge WebView2 Runtime (preinstalled on Windows 11).
- **Linux:** WebKitGTK 4.1 (`libwebkit2gtk-4.1-0`) and a graphical session.
- **macOS:** the system WKWebView.

Interactive runs may open the helper's window when a source needs a person to solve a challenge; unattended runs
never open a window and report the source as needing interaction. Repositories, extensions and settings are always
your own: the CLI ships none. Build a package yourself with `dart run scripts/package_cli.dart` (see
[docs/source-runners.md](docs/source-runners.md#desktop-packaging-u8)).

### Merge

Merge two Aidoku backups into one.

```sh
mangabackuputil merge -f <backup-file> -m <other-backup> [-o <output-folder>]
```

| Option | Description |
|--------|-------------|
| `-f, --backup` | First Aidoku backup file |
| `-m, --other` | Second Aidoku backup to merge with |
| `-o, --output` | Output folder (default: current directory) |
| `-v, --verbose` | Show additional output |

## Platforms

- Windows, macOS, Linux (standalone CLI). Packaged with its runtime on Windows; the macOS and Linux packages are built in CI but not yet qualified
- Flutter app planned (iOS, Android, macOS, Windows, Linux, Web)

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md)

## License

See [LICENSE.md](./LICENSE.md)
