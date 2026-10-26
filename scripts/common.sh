# shellcheck shell=bash disable=SC2034 # the constants are read by the scripts that source this file
# Definitions shared by scripts/verify.sh, scripts/release-plan.sh and scripts/self-test.sh. Sourced, never run. The
# functions never exit: they print what is wrong to stderr and return 1, so they also work inside $(...).

# Release versions, which are also the release tags: X.Y.Z or X.Y.Z-(alpha|beta|rc).N, no build metadata, at most 32
# characters (the SallaPush server's limit for the SDK version).
readonly SDK_VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$'
readonly SDK_VERSION_MAX_LENGTH=32

# The size gate: SallaPush may add at most 5 MB (5,242,880 bytes) to an app. scripts/verify.sh passes it to
# scripts/size-report.sh, whose own default budget must be the same number (CONTRIBUTING.md states it: 5 MB).
readonly SDK_SIZE_GATE_BYTES=5242880

# The largest file a commit may hold (scripts/verify.sh tree).
readonly SDK_MAX_FILE_BYTES=5242880

# The file that declares the version, and the declaration: the single source of truth that release tags must match.
readonly SDK_VERSION_FILE=Sources/SallaPushCore/SallaPushVersion.swift
readonly SDK_VERSION_DECLARATION='^package let sallaPushSDKVersion = "(.+)"$'
readonly SDK_CHANGELOG=CHANGELOG.md
# The podspecs, one per library. Each sets s.version to the declared version, which is also the tag CocoaPods fetches.
readonly SDK_PODSPECS="SallaPushCore.podspec SallaPush.podspec SallaPushExtension.podspec"
readonly SDK_PODSPEC_VERSION="^[[:space:]]*s\\.version[[:space:]]*=[[:space:]]*['\"]([^'\"]+)['\"][[:space:]]*\$"

# The golden payloads the tests read: byte-for-byte copies of the SallaPush server's wire contract, pinned here by
# sha256, except that c3-ios leaves out the store's credential fields. The server sends these payloads, so a golden
# changes only together with that contract: copy the contract's new file here, without those fields, then pin its new
# sha256.
readonly SDK_GOLDEN_DIR=Tests/SallaPushCoreTests/Fixtures/golden
readonly SDK_GOLDEN_NAMES="c3-ios compat-ios compat-ios-typed-data compat-push-ref"

# Prints the pinned sha256 of a golden payload; fails for a name that is not one.
#   sdk_golden_sha256 <name>
sdk_golden_sha256() {
  case "$1" in
    c3-ios) echo 60d43eca7d65383a81e5d41f007561c44427c207a0123bb20a3d91ee8c45cd3c ;;
    compat-ios) echo 4fab30cb596976fba041c74f9a8b980a9c7e132129c69869ac8dbfb60ee01b99 ;;
    compat-ios-typed-data) echo 1f90a2bdcc8183278f193003ed21672fd894ee5a3b5598d7435fd42ac0cc01f4 ;;
    compat-push-ref) echo e60562f5e5c1d788351a9c88717410d41bc103817132526a558c2022b42610cc ;;
    *) return 1 ;;
  esac
}

# Prints the sha256 of a file: sha256sum (Linux), shasum (macOS) or openssl, whichever exists.
#   sdk_sha256_of <file>
sdk_sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d ' ' -f 1
  else
    openssl dgst -sha256 -r "$1" | cut -d ' ' -f 1
  fi
}

# Prints a file of the repository at <root>: from the working tree, or from <commit> when one is given.
#   sdk_file_content <root> <path> [<commit>]
sdk_file_content() {
  local root="$1" path="$2" commit="${3:-}"
  if [ -n "$commit" ]; then
    git -C "$root" show "$commit:$path" 2>/dev/null || {
      echo "$path does not exist at $commit" >&2
      return 1
    }
  else
    [ -f "$root/$path" ] || {
      echo "$path does not exist" >&2
      return 1
    }
    cat "$root/$path"
  fi
}

# Prints the version that SDK_VERSION_FILE declares, in the working tree or at <commit>. Fails unless exactly one
# declaration exists and its value is a plain version string.
#   sdk_declared_version <root> [<commit>]
sdk_declared_version() {
  local root="$1" commit="${2:-}" content matches count version
  content="$(sdk_file_content "$root" "$SDK_VERSION_FILE" "$commit")" || return 1
  matches="$(printf '%s\n' "$content" | tr -d '\r' | grep -E "$SDK_VERSION_DECLARATION" || true)"
  count="$(printf '%s' "$matches" | grep -c '' || true)"
  [ "$count" -eq 1 ] || {
    echo "$SDK_VERSION_FILE must declare sallaPushSDKVersion exactly once (found $count matching lines)" >&2
    return 1
  }
  version="$(printf '%s\n' "$matches" | sed -E "s/$SDK_VERSION_DECLARATION/\\1/")"
  case "$version" in
    *[!0-9A-Za-z.+-]* | '')
      echo "$SDK_VERSION_FILE declares '$version', which is not a plain version string" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$version"
}

# Prints the version that <podspec> sets (`s.version = '<version>'`), in the working tree or at <commit>. Fails unless
# exactly one line sets it.
#   sdk_podspec_version <root> <podspec> [<commit>]
sdk_podspec_version() {
  local root="$1" podspec="$2" commit="${3:-}" content matches count
  content="$(sdk_file_content "$root" "$podspec" "$commit")" || return 1
  matches="$(printf '%s\n' "$content" | tr -d '\r' | grep -E "$SDK_PODSPEC_VERSION" || true)"
  count="$(printf '%s' "$matches" | grep -c '' || true)"
  [ "$count" -eq 1 ] || {
    echo "$podspec must set s.version exactly once, to a quoted version (found $count matching lines)" >&2
    return 1
  }
  printf '%s\n' "$matches" | sed -E "s/$SDK_PODSPEC_VERSION/\\1/"
}

# Fails unless <version> is releasable: the grammar of SDK_VERSION_RE, and at most SDK_VERSION_MAX_LENGTH characters.
#   sdk_check_version_grammar <version>
sdk_check_version_grammar() {
  [[ "$1" =~ $SDK_VERSION_RE ]] || {
    echo "$1 is not a release version: X.Y.Z or X.Y.Z-(alpha|beta|rc).N" >&2
    return 1
  }
  [ "${#1}" -le "$SDK_VERSION_MAX_LENGTH" ] || {
    echo "$1 is longer than the $SDK_VERSION_MAX_LENGTH-character sdk_version limit" >&2
    return 1
  }
}

# Prints the heading line of the '## [<version>]' entry of SDK_CHANGELOG, in the working tree or at <commit>. Fails
# when the changelog has no such entry, or more than one.
#   sdk_changelog_heading <root> <version> [<commit>]
sdk_changelog_heading() {
  local root="$1" version="$2" commit="${3:-}" content headings count
  content="$(sdk_file_content "$root" "$SDK_CHANGELOG" "$commit")" || return 1
  # A fixed-string prefix match: the version's dots are not wildcards.
  headings="$(printf '%s\n' "$content" | tr -d '\r' | awk -v heading="## [$version]" 'index($0, heading) == 1')"
  count="$(printf '%s' "$headings" | grep -c '' || true)"
  [ "$count" -eq 1 ] || {
    echo "$SDK_CHANGELOG must have exactly one '## [$version]' entry (found $count)" >&2
    return 1
  }
  printf '%s\n' "$headings"
}
