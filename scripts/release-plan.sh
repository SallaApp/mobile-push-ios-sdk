#!/usr/bin/env bash
# Resolves and checks a release tag before anything is built (.github/workflows/release.yml, job "Resolve the
# release"). A release is a tag X.Y.Z or X.Y.Z-(alpha|beta|rc).N on this repository, and SwiftPM installs the tag
# itself.
#
#   scripts/release-plan.sh <tag>
#
# Prints key=value lines for $GITHUB_OUTPUT:
#   version        the tag
#   prerelease     true for X.Y.Z-(alpha|beta|rc).N
#   sha            the commit the tag points at (peeled; GITHUB_SHA is never trusted for a tag)
#   api_baselines  the stable releases whose public API this one must keep, space-separated in version order: every
#                  stable tag of the same major version below this version on the history of the tagged commit, from
#                  FIRST_PUBLIC_VERSION on. Empty for a pre-release and for the first stable release of a major version
#   major_bump     true when a stable release of a lower major version precedes this one and none of its own major
#                  version does: the first release of a new major version, whose API is not compared
# Every stable tag on that history counts, one whose release run failed included: SwiftPM installs a tag as soon as it
# is pushed, and a pushed tag is never moved or deleted, so apps may use any of them. Comparing only with the last one
# would let a release that keeps a refused tag's API break the last good one. A stable tag off master, which this script
# refuses, is on no later release's history and is never compared.
# It fails unless:
#   - the tag is a release version (scripts/common.sh: the grammar, and the SallaPush server's 32-character limit);
#   - the tag exists in this clone;
#   - a stable tag points at a commit on master (RELEASE_MASTER_REF, default refs/remotes/origin/master);
#     a pre-release may tag any commit;
#   - Sources/SallaPushCore/SallaPushVersion.swift declares exactly this version at that commit;
#   - CHANGELOG.md has one '## [<tag>]' entry at that commit.
set -euo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$scripts/.." && pwd -P)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$scripts/common.sh"
master_ref="${RELEASE_MASTER_REF:-refs/remotes/origin/master}"
# The first public release: the stable tags below it were never public, so no release is compared with them.
readonly FIRST_PUBLIC_VERSION=1.1.0

die() {
  printf 'release-plan.sh: %s\n' "$*" >&2
  exit 1
}

git_root() {
  git -C "$root" "$@"
}

[ "$#" -eq 1 ] || {
  echo 'usage: scripts/release-plan.sh <X.Y.Z[-(alpha|beta|rc).N]>' >&2
  exit 2
}
version="$1"
sdk_check_version_grammar "$version" || die "the tag $version is not a release"
[[ "$version" =~ $SDK_VERSION_RE ]]
major="${BASH_REMATCH[1]}"

sha="$(git_root rev-parse --verify --quiet "refs/tags/$version^{commit}")" ||
  die "the tag $version does not exist in this clone (actions/checkout: fetch-depth: 0)"
prerelease=false
case "$version" in *-*) prerelease=true ;; esac

if git_root rev-parse --verify --quiet "$master_ref^{commit}" >/dev/null; then
  if ! git_root merge-base --is-ancestor "$sha" "$master_ref"; then
    [ "$prerelease" = true ] || die "the stable release $version must tag a commit on master; $sha is not on $master_ref"
    echo "release-plan.sh: the pre-release $version tags $sha, which is not on master" >&2
  fi
else
  [ "$prerelease" = true ] || die "$master_ref is missing; a stable release must be checked against master (actions/checkout: fetch-depth: 0)"
  echo "release-plan.sh: $master_ref is missing; the pre-release $version is not checked against master" >&2
fi

declared="$(sdk_declared_version "$root" "$sha")" || die "cannot read the declared version at $sha"
[ "$declared" = "$version" ] ||
  die "$SDK_VERSION_FILE declares $declared at $sha, but the tag is $version: bump sallaPushSDKVersion in the release's pull request"
heading="$(sdk_changelog_heading "$root" "$version" "$sha")" ||
  die "$SDK_CHANGELOG has no single '## [$version]' entry at $sha: add it in the release's pull request"
case "$heading" in
  *[Uu]nreleased*) echo "release-plan.sh: the $SDK_CHANGELOG heading '$heading' still says it is unreleased" >&2 ;;
esac

# Stable versions below the one being released, from FIRST_PUBLIC_VERSION on, from tags whose commit is an ancestor of
# it. A function, because bash 3.2 (macOS) cannot parse a case statement written inside $(...).
stable_versions_below() {
  local candidate
  git_root tag -l '[0-9]*' | while IFS= read -r candidate; do
    [[ "$candidate" =~ $SDK_VERSION_RE ]] || continue
    case "$candidate" in *-*) continue ;; esac
    [ "$candidate" != "$version" ] || continue
    git_root merge-base --is-ancestor "refs/tags/$candidate" "$sha" || continue
    [ "$(printf '%s\n%s\n' "$candidate" "$version" | sort -V | sed -n 1p)" = "$candidate" ] || continue
    [ "$(printf '%s\n%s\n' "$FIRST_PUBLIC_VERSION" "$candidate" | sort -V | sed -n 1p)" = "$FIRST_PUBLIC_VERSION" ] ||
      continue
    printf '%s\n' "$candidate"
  done
}

api_baselines=""
major_bump=false
if [ "$prerelease" = false ]; then
  below="$(stable_versions_below | sort -V)"
  # The ones of this major version, oldest first.
  api_baselines="$(printf '%s\n' "$below" | awk -F . -v major="$major" '$1 != "" && $1 == major' | tr '\n' ' ')"
  api_baselines="${api_baselines% }"
  if [ -z "$api_baselines" ] && [ -n "$below" ]; then
    major_bump=true
  fi
fi

printf 'version=%s\nprerelease=%s\nsha=%s\napi_baselines=%s\nmajor_bump=%s\n' \
  "$version" "$prerelease" "$sha" "$api_baselines" "$major_bump"
