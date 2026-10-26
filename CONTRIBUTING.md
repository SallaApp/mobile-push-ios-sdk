# Contributing to the SallaPush iOS SDK

Thank you for helping improve the SallaPush iOS SDK.

## Issues

- **Bugs and feature requests:** [open an issue](https://github.com/SallaApp/mobile-push-ios-sdk/issues/new/choose).
  Say which SDK and iOS versions you use, what you expected and what happened, and include the SallaPush log codes you
  saw.
- **Never paste** tokens, keys or customer data. Log codes are enough.
- **Security problems:** don't open an issue. Report them privately, as [SECURITY.md](SECURITY.md) explains.
- **App ids:** Contact the Salla team for your app id.

## Pull requests

- For a large change, open an issue first, so that we can agree on the approach before you write the code.
- Keep each pull request to one change. Update its tests and docs, and add a line under `## [Unreleased]` in
  [CHANGELOG.md](CHANGELOG.md).
- Name the branch like `feature/PROJ-123-retry-registration` (`feature`, `bugfix`, `hotfix` or `test`, then a ticket
  key and number), and title the pull request like `fix(mobile): retry a failed registration`. The checks
  `Validate branch name` and `Validate PR title` ([.github/workflows/lint-pr.yml](.github/workflows/lint-pr.yml)) say
  what they accept.
- Run the checks below before you push. A maintainer reviews your pull request, and may land it as a commit of their
  own that credits you as a co-author (`Co-authored-by`).
- By contributing, you agree that your contribution is licensed under this repository's [MIT License](LICENSE). No
  contributor license agreement or sign-off is needed.

Everyone taking part in this project follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Checks

On a Mac with Xcode 26 and SwiftLint 0.63.2, `scripts/verify.sh` (or `make verify`) runs every check CI runs, and
`scripts/verify.sh lint test` only the steps you name; the script's header lists them. Without Xcode,
`scripts/verify.sh version goldens catalogue links tree snippets` and `scripts/self-test.sh` run anywhere with python3.
CI runs the checks for every pull request and every push to `master` ([.github/workflows/ci.yml](.github/workflows/ci.yml)).

| Command | What it does |
|---|---|
| `make test`, `make tsan` | All test suites on macOS, plain and with Thread Sanitizer |
| `make test-ios` | All test suites on the newest iPhone simulator, and the extension-safety build |
| `make lint`, `make gates`, `make api` | SwiftLint, the crash-safety gates, and the public API against [API.txt](API.txt) |
| `scripts/check-readme-snippets.sh` | The code blocks of the README and the docs equal the example's code, and the log codes and versions they name are the SDK's |
| `scripts/size-report.sh` | What SallaPush adds to an app; it fails over 5 MB |

[docs/RELEASING.md](docs/RELEASING.md) says how a maintainer releases a version.

## The example project

[Examples/SallaPushExample](Examples/SallaPushExample) builds without signing:

- `SallaPushExample` is the app, with the README's `AppDelegate.swift`, and `SallaPushExampleNSE` its Notification
  Service Extension.
- `ReadmeSnippets` compiles every other code block of the README and the docs, the Swift ones in Swift 6 language
  mode. It never runs.
- `SizeBaseline` is the same app without SallaPush, for `scripts/size-report.sh`.

To run the app, replace the example app id in `AppDelegate.swift` with yours, then run the `SallaPushExample` scheme
on a simulator with iOS 16 or later.

## What needs care

- **The README and the docs show the example's code.** Each Swift or Objective-C block follows a hidden `snippet:`
  marker that names the example file, or the `// snippet:<name>` region of it, that the block must equal. Change the
  example first, then copy the code to every block that shows it. Keep regions out of `#if` blocks.
- **Log codes are stable API:** apps match on them. They follow the shared catalogue of
  [scripts/log-catalogue.txt](scripts/log-catalogue.txt), which `scripts/verify.sh catalogue` checks; a maintainer
  carries a change to the other SDKs.
- **The public API** is listed in [API.txt](API.txt). After a change on purpose, run `scripts/api-surface.sh` and
  commit the file with the change. A release keeps the public API of every earlier stable release of its major version.
- **The golden payloads** in [Tests/SallaPushCoreTests/Fixtures/golden](Tests/SallaPushCoreTests/Fixtures/golden)
  are pinned by sha256 in [scripts/common.sh](scripts/common.sh): change one only together with the payload format.
