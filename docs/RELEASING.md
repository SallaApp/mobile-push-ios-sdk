# SallaPush iOS SDK: releasing

How versions work, and how a maintainer releases one. To contribute, see [CONTRIBUTING.md](../CONTRIBUTING.md).

## Versioning

SallaPush follows [Semantic Versioning](https://semver.org). Repository tags are plain versions such as `1.1.0` or
`1.2.0-beta.1`, and `SallaPush.sdkVersion` returns the version at run time. Every change is listed in
[CHANGELOG.md](../CHANGELOG.md).

## Releasing

A release is a tag `X.Y.Z` on this repository, or `X.Y.Z-alpha.N`, `X.Y.Z-beta.N` or `X.Y.Z-rc.N` for a
pre-release. SwiftPM installs the tag itself.

1. In a pull request, set the new version wherever the current one is named; `git grep -nF <current version>` lists
   every place: `sallaPushSDKVersion` in
   [Sources/SallaPushCore/SallaPushVersion.swift](../Sources/SallaPushCore/SallaPushVersion.swift), `s.version` in the
   three podspecs, the README's `Version` line, Swift Package Manager steps and four CocoaPods `:tag`s, and the tests
   that assert the version (`RegistrationTests`, `UpdateTests` and `APISurfaceTests`). Earlier changelog entries and
   sample versions in comments and tests stay. Add the version's entry to [CHANGELOG.md](../CHANGELOG.md), under a
   heading `## [X.Y.Z] - YYYY-MM-DD`. `scripts/verify.sh` fails on any place left behind.
2. Once it's merged, tag the commit the merge made on `master`, and push only that tag:
   `git tag -a X.Y.Z -m "SallaPush iOS SDK X.Y.Z" <commit>`, then `git push origin X.Y.Z`. A pre-release may tag a
   commit of another branch.
3. [The release workflow](../.github/workflows/release.yml) checks the tag against `sallaPushSDKVersion` and the
   changelog, verifies the tagged commit like a pull request, and checks that a stable version keeps the public API of
   every earlier stable release of its major version ([scripts/api-compat.sh](../scripts/api-compat.sh)). If a check
   fails, don't use the tag: fix the problem and release the next version. Never move or delete a pushed tag.
   Releases before 1.1.0, the first public version, are never compared (`FIRST_PUBLIC_VERSION` in
   [scripts/release-plan.sh](../scripts/release-plan.sh)).
4. Once every check passed, the workflow creates the tag's GitHub Release in the environment `release`, with the
   version's changelog entry as its notes ([scripts/release-notes.sh](../scripts/release-notes.sh)).
