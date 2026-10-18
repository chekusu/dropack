<p align="center"><img src="PhotoRelay/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="112" alt="Dropack icon"></p>

# Dropack

**Big files. Shared in batches.**

A native iPhone and iPad app for packaging original photos and videos, sharing them through the iOS share sheet, and saving received media to Photos with progress and recovery.

[Website](https://dropack.app) · [Join TestFlight](https://testflight.apple.com/join/yjrwM4vT) · [简体中文](README.zh-CN.md) · [Website source](https://github.com/chekusu/dropack.app)

## What it does

- **Share albums:** select photos, videos, or files; manage an album; create its archive when sharing. Reuse unchanged packaged resources when updating an archive.
- **Use AirDrop:** send a `.dropack` package through Apple's system share sheet, or export a standard ZIP for other tools. A `.dropack` file is a ZIP archive with an album manifest.
- **Receive safely:** inspect a received album before saving. Import photos, videos, ZIPs, or folders chosen in Files, including supported external drives and cloud providers.
- **See the work:** distinguish iCloud downloads from packaging, show item progress, pause and resume supported tasks, and surface progress with Live Activities on supported devices.
- **Avoid repeat imports:** use content hashes and local import history to skip previously confirmed saves. Ambiguous interrupted saves require review rather than automatic duplication.
- **Keep control:** browse album media, add or remove album items, manage local packages, and choose the app language and appearance.

Dropack runs on **iOS / iPadOS 17 or later** and includes 16 languages. Processing happens on the device; there is no Dropack account or file-upload backend. iCloud, AirDrop, Files providers, and update checks can use the network.

## Build

You need a Mac, **Xcode 26 or later** (the source uses the iOS 26 background-processing APIs behind availability checks), and Python 3 for project/resource maintenance. The app itself is Swift / SwiftUI; Expo and Node.js are not required to build it.

```sh
git clone https://github.com/chekusu/dropack.git
cd dropack
open Dropack.xcodeproj
```

Choose the `Dropack` scheme and an iPhone or iPad simulator. Xcode resolves **ZIPFoundation 0.9.20**, pinned in the project and integration-test package.

For a device build, use your own Apple development team. Forks must choose their own app and Live Activity extension bundle identifiers. If you change the `app.dropack.ios` prefix, update the background-task identifiers in `PhotoRelay/Info.plist` and `PhotoRelay/Services/PackageBackgroundExecution.swift` as well. The project generator contains the bundle-ID defaults; update it before regenerating the project. No signing certificates, provisioning profiles, Apple credentials, or official Expo release configuration are included.

An unsigned simulator build:

```sh
xcodebuild -project Dropack.xcodeproj -scheme Dropack \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

## Development and checks

```sh
python3 scripts/generate_project.py --check
python3 scripts/localization_audit.py
python3 -m unittest discover -s scripts/tests
swift test --build-system native
swift test --build-system native --package-path Tests/ZIPIntegration
```

After adding Swift files, run `python3 scripts/generate_project.py`. After changing translations, run `python3 scripts/localization_audit.py --write` and regenerate the project. See [localization notes](localization/README.md).

| Directory | Contents |
| --- | --- |
| `PhotoRelay/Core` | Album models, checkpoints, ZIP validation, resumable file copying, and import identity |
| `PhotoRelay/Services` | PhotoKit, file access, packaging/import workers, previews, and background execution |
| `PhotoRelay/UI` | SwiftUI screens and native UIKit presentations |
| `Shared`, `DropackLiveActivity` | ActivityKit data and the Live Activity extension |
| `Tests` | Core, ZIP interoperability, app integration, and UI tests |
| `localization` | Translation sources for 16 languages |

`PhotoRelay` is the original source-directory name. The product is Dropack. ZIP test fixtures are generated from synthetic data by `Tests/ZIPIntegration/generate_fixtures.py`.

## Boundaries

- AirDrop controls network transfer and receiving behavior. Dropack does not implement a cross-platform transport or byte-level AirDrop resume. iOS may open received files in Files before the user chooses Dropack.
- Packaging preserves original media without transcoding. Original metadata, including location when present, can travel with the package.
- Packaging/ZIP recovery uses item checkpoints; interrupted items can need reprocessing. Direct-file staging can resume by byte offset, while a Photos save must complete as a whole item.
- Background execution is granted by iOS. Live Activities alone do not keep the app running; the app pauses safely when its execution time expires.
- Imports require available device storage. Cloud providers may download an archive before Dropack can inspect it. Media codec support depends on iOS.
- Encrypted, split, and automatically nested ZIP extraction are not supported. Supported capacity and throughput depend on the device and source; no fixed transfer-speed guarantee is made.

The repository contains current development source and may be ahead of the distributed TestFlight build. App Store/TestFlight releases use a separate signing and review process.

## Contributing and security

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). Report sensitive issues through [GitHub private vulnerability reporting](https://github.com/chekusu/dropack/security/advisories/new), not a public issue containing credentials or personal media.

## License

[MIT](LICENSE), copyright 2026 CHEKUSU. ZIPFoundation retains its own MIT notice in [ThirdPartyNotices.txt](ThirdPartyNotices.txt). Included app artwork is described in [ASSETS.md](ASSETS.md). The license grants no rights to imply endorsement or ownership of the Dropack or CHEKUSU trademarks.
