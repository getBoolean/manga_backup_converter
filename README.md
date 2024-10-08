# Manga Backup Converter <!-- omit in toc -->

[![latest release](https://img.shields.io/github/release/getBoolean/manga_backup_converter.svg?maxAge=3600&label=download)](https://github.com/getBoolean/manga_backup_converter/releases)
[![coverage](https://img.shields.io/codecov/c/github/getBoolean/manga_backup_converter)](https://app.codecov.io/gh/getBoolean/manga_backup_converter)
[![Codemagic build status](https://api.codemagic.io/apps/64d885be0dff4f86138da577/64d885be0dff4f86138da576/status_badge.svg)](https://codemagic.io/apps/64d885be0dff4f86138da577/64d885be0dff4f86138da576/latest_build)

An opinionated starting point for a Flutter app intended to provide the boilerplate
needed to create a large app and provides utilities to separate code generation into
separate packages.

## Table of Contents <!-- omit in toc -->

- [Motivation](#motivation)
- [About](#about)
- [Demo](#demo)
- [Template: Getting Started](#template-getting-started)
  - [Change App/Package Name](#change-apppackage-name)
  - [Workflow Permissions](#workflow-permissions)
- [Setup](#setup)
- [Testing](#testing)
  - [Integration Tests](#integration-tests)
- [Building](#building)
  - [Flavors](#flavors)
  - [Build for Windows Release](#build-for-windows-release)
  - [Build for other platforms](#build-for-other-platforms)
- [Architecture](#architecture)
  - [Data Layer (Repositories)](#data-layer-repositories)
  - [Domain Layer (Models)](#domain-layer-models)
  - [Presentation Layer (Controllers)](#presentation-layer-controllers)
  - [Application Layer (Service)](#application-layer-service)
- [Libraries](#libraries)
  - [Melos](#melos)
    - [Scripts](#scripts)
  - [GoRouter Navigation](#gorouter-navigation)
  - [ENVied Environment Variables](#envied-environment-variables)
  - [Mason Bricks](#mason-bricks)
  - [JSON Serialization, Unions, Sealed Classes and copyWith](#json-serialization-unions-sealed-classes-and-copywith)
  - [State Management](#state-management)
  - [Async Data Loading and Caching](#async-data-loading-and-caching)
  - [Native Splash Screen](#native-splash-screen)
  - [Native Platform Dialogs/Alerts](#native-platform-dialogsalerts)
  - [Bottom Sheets](#bottom-sheets)
  - [Layout List/Grid](#layout-listgrid)
- [Contributing](#contributing)

## Motivation

This is an opinionated template I use for my personal projects. It uses `melos` monorepo
to separate the code generation into separate packages for [assets/](./packages/assets/), [env/](./packages/env/),
and [localization/](./packages/localization/)

This repository also follows [Riverpod App Architecture](https://codewithandrea.com/articles/flutter-app-architecture-riverpod-introduction/),
I highly recommend reading the article. Each `layer` has its own folder per feature in the [lib/src/features/](./lib/src/features/) folder.

## About

- Made with Flutter
- Template by [@getBoolean](https://github.com/getBoolean)
- Minimal OS Version:
  - iOS: 13.0
  - Android: 6.0 (SDK 23)
  - MacOS: 10.14.6
  - Windows 10
  - Linux: Any modern distribution

## Demo

Flutter Web is deployed to GitHub Pages in a separate subfolder for each branch. The `main` branch is deployed to
[getboolean.github.io/mangabackupconverter](https://getboolean.github.io/manga_backup_converter).

- This GitHub Pages setup requires the Flutter `#` from [HashUrlStrategy](https://api.flutter.dev/flutter/package-flutter_web_plugins_url_strategy/HashUrlStrategy-class.html), so ensure it is not disabled for your Flutter Web CI builds deployed to GitHub Pages. If it is disabled, the Navigator 2.0 subroutes will prevent GitHub Pages from resolving the correct app when refreshed.

For example, in the CI workflow using the argument `--dart-define ENABLE_HASH_URL_STRATEGY=true`

```dart
void main() {
  const useHashUrlStrategy = bool.fromEnvironment('ENABLE_HASH_URL_STRATEGY', defaultValue: false);
  if (!useHashUrlStrategy) {
    setUrlStrategy();
  }
  runApp(MyApp());
}
```

## Template: Getting Started

1. Setup:
   1. [ ] Install [puro](https://puro.dev) Flutter Environment Manager
   1. [ ] Install Flutter using Puro
   1. [ ] Install [Melos](https://pub.dev/packages/melos) globally
   1. [ ] Install [Mason CLI](https://docs.brickhub.dev/)
1. [ ] Run `melos bootstrap` to install dependencies for all packages and generate env files.
1. [ ] Rename App: [Change App/Package Name](#change-apppackage-name)
1. [ ] [Workflow Permissions](#workflow-permissions)
1. [ ] Update Description: [pubspec.yaml](pubspec.yaml) and [README.md](README.md).
1. [ ] Replace [codemagic.io](https://codemagic.io) badge with your own.
1. [ ] Add Environment Variables: [ENVied Environment Variables](#envied-environment-variables) section for details.
1. [ ] [Change App Icon: flutter_launcher_icons](https://pub.dev/packages/flutter_launcher_icons)
1. [ ] [Change Splash Screen: flutter_native_splash](https://pub.dev/packages/flutter_native_splash)
1. [ ] Setup the release build configuration, see the [Building](#building) section.
1. [ ] Setup Codecov for the repository, see the [Codecov documentation](https://docs.codecov.com/docs/quick-start).
1. [ ] Update contribution guidelines at the [Contributing](#contributing) section.
1. [ ] (**Important!**) Update the [LICENSE](./LICENSE.md) file. I give permission to relicense any
code provided in this template, but the licenses of the packages must still be followed.
1. [ ] Delete this `Template: Getting Started` section from the README.

### Change App/Package Name

1. [ ] Run the following command to change the package name, where `com.author.app_name` is the new name for the app.

   ```bash
   dart run change_app_package_name:main com.author.app_name
   ```

1. [ ] Search for `getBoolean/manga_backup_converter` and update it with your GitHub username and repository name
1. [ ] Search for `dev.getboolean.mangabackupconverter` and replace it with your new Android bundle identifier
1. [ ] Search for `dev.getboolean.mangabackupconverter` and replace it with your new iOS bundle identifier
1. [ ] Search for `mangabackupconverter` and replace it with your new package identifier
1. [ ] Search for `Manga Backup Converter` and replace it with your new app name

### Workflow Permissions

1. Github Repo: Settings -> Actions -> General -> Workflow permissions
   1. Enable "Read and write permissions"
   1. Enable "Allow GitHub Actions to create and approve pull requests"
1. Github Repo: Settings -> Environments -> github-pages -> Deployment branches and tags
   1. Change "Selected branches and tags" to "No restriction"
1. Github Repo: Settings -> Secrets and variables -> Repository secrets -> New repository secret
   1. Name: `PAT`
   1. Value: Your GitHub Personal Access Token
      1. Github Profile -> Settings -> Developer settings -> Personal access tokens -> Tokens (classic)
      1. Generate a new token (classic), name it `<AppName> Web Deploy`, and give it the `repo` and `workflow` scopes
1. Github Repo: Settings -> General -> Pull Requests -> Enable "Allow auto-merge"

## Setup

1. Install [puro](https://puro.dev) Flutter Environment Manager
   - Install Flutter using Puro
1. Install [Melos](https://pub.dev/packages/melos) globally
1. Install [Mason CLI](https://docs.brickhub.dev/)
1. Run `melos bootstrap` to install dependencies for all packages and generate env files.

## Testing

- This project uses Mocktail to create mocks and fakes. Follow the instructions in the
[Mocktail README](https://pub.dev/packages/mocktail).
- Tests are located in the `test` root directory and each package. To run all tests, run the following command:

```bash
melos run test
```

### Integration Tests

`patrol` provides visual feedback to the tester andtakes screenshots automatically.
These integration tests are located in the `integration_test` directory.

To run the tests, see the instructions in the [Patrol documentation](https://pub.dev/packages/patrol)

## Building

This project automatically builds for all platforms without code signing using GitHub Actions.
To build the project locally, follow the instructions in the
[Flutter docs](https://flutter.dev/docs).

### Flavors

Flavors are used to provide different environment variables based on the current flavor. By default,
the app uses the "local" flavor. Run/build the app with `--dart-define FLAVOR=<flavorname>`
to change the flavor. The following flavors are supported:

- `local` - Local development. The text banner changes to "Debug" when in debug mode, "Local" in profile mode, and hidden in release mode.
- `dev` - Development build not intended for release.
- `beta` - Beta build intended for release to testers.
- `staging` - Staging build intended for device integration testing.
- `prod` - Production build intended for release to stores.

### Build for Windows Release

1. Customize `msix_config` in [pubspec.yaml](pubspec.yaml) according to the documentation
for [msix](https://pub.dev/packages/msix) for your method of publication. The default
configuration is for CI/CD testing builds only, not releases.
1. Run the corresponding command for your method of publication

### Build for other platforms

- [Flutter Docs for Android](https://docs.flutter.dev/deployment/android).
- [Flutter Docs for iOS](https://docs.flutter.dev/deployment/ios).
- [Flutter Docs for MacOS](https://docs.flutter.dev/deployment/macos).
- [Flutter Docs for Linux](https://docs.flutter.dev/deployment/linux).
- [Flutter Docs for Web](https://docs.flutter.dev/deployment/web).

## Architecture

This project uses the [Riverpod App Architecture](https://codewithandrea.com/articles/flutter-app-architecture-riverpod-introduction/)
in a feature-first manner where each feature is a separate package in the [lib/src/features/](./lib/src/features/) folder.
Each feature has its own layers, which separate the business logic from the UI.

### Data Layer (Repositories)

The repository pattern consists of Repositories, DTOs, and Data Sources. Their jobs are the following:

1. isolate domain models (or entities) from the implementation details of the data sources in the data layer.
2. convert data transfer objects to validated entities that are understood by the domain layer
3. (optionally) perform operations such as data caching.

Repository pattern use cases:

1. talking to REST APIs
2. talking to local or remote databases (e.g. Sembast, Hive, Firestore, etc.)
3. talking to device-specific APIs (e.g. permissions, camera, location, etc.)

### Domain Layer (Models)

Domain Models, which consist of entity and value objects. It should solve domain-related problems.

The domain models can contain logic for mutating them in an immutable manner, but they should not contain any serialization.

- Note: it is a simple data classes that doesn't have access to repositories, services, or
  other objects that belong outside the domain layer.

### Presentation Layer (Controllers)

- holds business logic
- manage the widget state
- interact with repositories in the data layer

### Application Layer (Service)

Implements application-specific logic by accessing the relevant repositories as needed.
The service classes are not concerned about:

- managing and updating the widget state (that's the job of the controller)
- data parsing and serialization (that's the job of the repositories)

## Libraries

### Melos

This project uses [Melos](https://pub.dev/packages/melos) to manage the monorepo.

  ```bash
  flutter pub get
  # Install melos globally
  dart pub global activate melos
  # Setup local dependency overrides for packages in the monorepo
  melos bootstrap

  # Or if dart executables are not on your path
  dart pub global run melos bootstrap
  ```

#### Scripts

Pub:

- `melos run pub` - Run `pub get` in all packages.
- `melos run dart:pkg` - Run `dart pub get` in the selected dart package.
- `melos run flutter:pkg` - Run `flutter pub get` in the selected flutter package.
- `melos run upgrade` - Run `pub upgrade` in all packages.
- `melos run upgrade:pkg` - Run `pub upgrade` in the selected package.

Code Generation:

- `dart run build_runner watch -d` - Watch and generate code for the app, does not work with subpackages
- `melos run generate` - Run `build_runner build` in all packages that depend on `build_runner`.
- `melos run generate:pkg` - Run `build_runner build` for a specific package (except `envied` packages).
- `melos run watch:pkg` - Run `build_runner watch` for a specific package (except `envied` packages). It will not work if you choose "all" in the package selection prompt.
- `melos run assets` - Run `assets_gen build` in all packages that depend on `assets_gen`.
- `melos run assets:pkg` - Run `assets_gen build` for a specific package.
- `melos run env` - Run `build_runner` in all packages that depends on `envied`.
- `melos run env:pkg` - Run `build_runner` in a specific package that depends on `envied`.
- `melos run loc` - Run `flutter gen-l10n` in the localization package to generate
  the localized strings from the arb files.

Tests:

- `melos run lint` - Run dart analyzer and custom lints in all packages.
- `melos run analyze` - Run `dart analyze` in all packages.
- `melos run custom_lint` - Run `dart run custom_lint` in all packages.
- `melos run test` - Run all Flutter tests.
- `melos run format` - Run `dart format` in all packages.
- `melos run fix` - Run `dart fix --apply` in all packages.
- `melos run test` - Run all tests in the project.
- `melos run flutter_test` - Run all Flutter tests in the project.
- `melos run dart_test` - Run all Dart tests in the project.
- `melos run flutter_test:pkg` - Run Flutter tests for a specific package.
- `melos run dart_test:pkg` - Run Dart tests for a specific (Dart only) package.

### GoRouter Navigation

This project uses [GoRouter](https://pub.dev/packages/go_router) for navigation
and provides some starter boilerplate for adaptive multitab navigation using `ResponsiveScaffold`.

### ENVied Environment Variables

Environment variables are setup using [ENVied](https://pub.dev/packages/envied)
in the [env](packages/env/) package. Environment variables need to be
defined for debug, profile, and release modes.

1. Copy the `*.env.example` files and remove the `.example` extension from them.
1. Add the values for the environment variables in the respective `.env*` file.
   - Each key must be added to each `.env*` file, unless a non null default value is added
     to the `@EnviedField` annotation.
   - It is recommended to use an empty string for the default and use `Env`'s getter to access the value.
1. Update [src/env/app_env_fields.dart](packages/env/lib/src/env/app_env_fields.dart)
with the new environment variables for `AppEnvFieldsGenerated` and `AppEnvFieldsNullable`.
1. Add the new environment variables to the implementing `*Env` classes in the [src/env](packages/env/src/env/) directory.
   - It must be done for *all* even if only one `.env` file is planned to be used
1. Enable `obfuscate` for API keys in the `@EnviedField` annotation. (Note: still assume it is not secure)
1. Optionally, add a `@EnviedField` `defaultValue` or enable `optional` on the annotation for keys which are
not required in all modes.

### Mason Bricks

[Mason](https://pub.dev/packages/mason) to generate code for features
and tests using templates. To use the bricks, install the Mason VS Code extension. To create
addition bricks, use [Mason CLI](https://pub.dev/packages/mason_cli).

### JSON Serialization, Unions, Sealed Classes and copyWith

- [dart_mappable](https://pub.dev/packages/dart_mappable)
  - Used for Unions, JSON serialization, and copyWith
- [modddels](https://pub.dev/packages/modddels)
  - Used for type-safe data validation, NOT serialization

### State Management

This project is preconfigured to use [Riverpod Generator](https://pub.dev/packages/riverpod_generator).
The normal riverpod syntax is still supported. See Andrea's article on
[Riverpod architecture](https://codewithandrea.com/articles/flutter-app-architecture-riverpod-introduction/)
for how to structure your code.

It is recommend to run build_runner in watch mode to generate the code for Riverpod.

```dart
dart run build_runner watch -d
```

### Async Data Loading and Caching

The [stock](https://pub.dev/packages/stock) package is recommended for loading data from both remote and
local sources. Its main goal is to prevent excessive calls to the network and disk cache. By
utilizing it, you eliminate the possibility of flooding your network with the same request
while, at the same time, adding layers of caching.

Although you can use it without a local source, the greatest benefit comes from combining Stock with a local database such as Floor, Drift, Sqflite, Realm, etc. *(excerpt from the README)*

### Native Splash Screen

Follow the instructions in the file [flutter_native_splash.yaml](flutter_native_splash.yaml)

### Native Platform Dialogs/Alerts

Use [flutter_native_dialog](https://pub.dev/packages/flutter_native_dialog) to show native dialogs/alerts.

### Bottom Sheets

Use [wolt_modal_sheet](https://pub.dev/packages/wolt_modal_sheet) to show customizable and responsive bottom sheets.

### Layout List/Grid

Use [wolt_responsive_layout_grid](https://pub.dev/packages/wolt_responsive_layout_grid) to show a responsive list/grid.

## Contributing

1. Fork it [https://github.com/getBoolean/manga_backup_converter/fork](https://github.com/getBoolean/manga_backup_converter/fork)
1. Create your feature branch (git checkout -b feature/fooBar)
1. Commit your changes (git commit -am 'Add some fooBar')
1. Push to the branch (git push origin feature/fooBar)
1. Create a new Pull Request
