# Contributing

Open an issue with the iOS/iPadOS version, the action that failed, and a minimal reproducible example. Use synthetic media when possible. Do not upload a private photo package, personal photo-library identifiers, credentials, device logs containing personal information, or signing files.

Before opening a pull request, run the project, localization, core-test, and ZIP-test commands in the README. Build the iOS simulator app for Swift/UI changes. For AirDrop, PhotoKit, external storage, iCloud, and background execution, describe what was checked on a real device and what remains untested.

UI and PhotoKit integration tests require a dedicated simulator, the `DROPACK_QA=1` test setting, and full Photos access. Do not run media-writing tests against a personal photo library. The core and ZIP package tests do not require a Photos library or signing account.

Keep changes focused. Preserve interruption recovery, archive integrity, and the separation between deleting a local package and deleting the user's Photos assets. Do not claim a transfer speed or capacity without a reproducible measurement.

All contributions must be compatible with the MIT license. Preserve third-party notices and document the origin and license of any added assets. Report sensitive vulnerabilities using the repository's private security reporting feature.
