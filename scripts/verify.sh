#!/usr/bin/env bash
# The full verification of the SallaPush iOS SDK. CI runs it for every pull request, every push to master and every
# release tag (.github/workflows/verify.yml, one step per step below), so a local run checks the SDK exactly the way
# CI does.
#
#   scripts/verify.sh [step...]     run from anywhere
#
# Steps, in order (without arguments it runs them all and stops at the first failure):
#   lint        SwiftLint 0.63.2, strict, with the crash-safety rules as errors (.swiftlint.yml)
#   gates       the grep gates of scripts/check-gates.sh: crash safety, required-reason APIs, Bundle.module, and no
#               ids of design notes or review findings that aren't in the repository
#   deps        no package dependencies
#   api         the public API equals API.txt (scripts/api-surface.sh --check)
#   version     the declared version is releasable, CHANGELOG.md has its entry, and every podspec sets it
#   goldens     the golden payloads the tests read are the wire contract's, unchanged: regular files whose sha256 are
#               the ones scripts/common.sh pins
#   catalogue   the log codes, with their levels and categories, are the shared log catalogue's
#               (scripts/check-log-catalogue.sh against scripts/log-catalogue.txt)
#   links       every relative Markdown link resolves inside the repository
#   tree        what a commit takes: no secret, credential, build output, symbolic link, submodule, nested repository
#               or file over 5 MB; no build file, script or tool config that reaches outside the repository; the files
#               a build and a release need, the scripts executable; every workflow action pinned to a commit, and no
#               pull_request_target workflow that checks out code
#   build       swift build, with every compiler warning an error
#   test        swift test (macOS), with every compiler warning an error
#   tsan        swift test with Thread Sanitizer, with every compiler warning an error
#   xcode-test  xcodebuild test of every suite on the newest stock iPhone simulator, serially (no simulator clones); a
#               Main Thread Checker report fails
#   xcode-tsan  the same with Thread Sanitizer
#   extension   SallaPushExtension builds for iOS with APPLICATION_EXTENSION_API_ONLY=YES, without a compiler warning
#   example     the example app, its Notification Service Extension and the Objective-C smoke files build, without an
#               Objective-C compiler warning
#   snippets    scripts/check-readme-snippets.sh, then its self-test
#   size        scripts/size-report.sh: fails when SallaPush adds more than 5 MB (5,242,880 bytes) to an app
#
# Needs macOS with Xcode 26 and python3 (version, goldens, catalogue, links, tree and snippets also run elsewhere), and
# for lint SwiftLint 0.63.2.
#
# Environment:
#   SWIFTLINT              the SwiftLint binary (default: swiftlint on PATH); it must be 0.63.2
#   VERIFY_LOG_DIR         when set, receives a <step>.log per step and summary.tsv
#   VERIFY_SIMULATOR_UDID  the simulator of xcode-test and xcode-tsan (default: the newest stock iPhone)
#   VERIFY_DERIVED_DATA    when set, the xcodebuild steps and the size report build under it (one folder each) instead
#                          of Xcode's default DerivedData and .build/size-report
# The size step gates at 5,242,880 bytes whatever SIZE_REPORT_BUDGET_BYTES holds: it passes that number to
# scripts/size-report.sh, whose own default budget must be the same.
set -euo pipefail

readonly SWIFTLINT_VERSION=0.63.2
readonly STEPS="lint gates deps api version goldens catalogue links tree build test tsan xcode-test xcode-tsan extension example snippets size"
# The steps that need no Xcode.
readonly PORTABLE_STEPS="version goldens catalogue links tree snippets"

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$scripts/.." && pwd -P)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$scripts/common.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/sallapush-verify.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

fail() {
  printf 'verify.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  echo "usage: scripts/verify.sh [step...]   steps: $STEPS" >&2
  exit 2
}

require_macos() {
  [ "$(uname -s)" = Darwin ] || fail "this step needs macOS with Xcode"
}

# The problems of the running step (each step runs in a subshell of its own).
problems=0
report() {
  problems=$((problems + 1))
  printf '%s\n' "$*"
}

# The files of the repository that a commit would take: tracked, and untracked but not ignored. NUL-separated, into
# <listing>; the callers read that file, never a process substitution, whose failure no shell option reports.
#   list_files <listing> [<git ls-files option>...]
list_files() {
  local listing="$1"
  shift
  git -C "$root" ls-files -z "$@" >"$listing" ||
    fail "cannot list the files of $root (git ls-files failed); run the verification in a clone of the repository"
}

# ---------------------------------------------------------------------------------------------------------------------
# Steps

step_lint() {
  local swiftlint="${SWIFTLINT:-swiftlint}" version
  command -v "$swiftlint" >/dev/null 2>&1 ||
    fail "SwiftLint is not installed (CI installs the pinned $SWIFTLINT_VERSION bundle; locally install it or set SWIFTLINT)"
  version="$("$swiftlint" version)"
  [ "$version" = "$SWIFTLINT_VERSION" ] || fail "SwiftLint $version found; the rules are pinned to $SWIFTLINT_VERSION (set SWIFTLINT)"
  (cd "$root" && "$swiftlint" lint --strict --config .swiftlint.yml)
}

step_gates() { (cd "$root" && scripts/check-gates.sh); }

step_deps() {
  (cd "$root" && swift package show-dependencies --format json) >"$work/dependencies.json"
  python3 - "$work/dependencies.json" <<'PY'
import json, sys
dependencies = json.load(open(sys.argv[1])).get("dependencies")
if dependencies is None or dependencies:
    sys.exit(f"the SDK must have no package dependencies, found {[d.get('identity') for d in dependencies or []]}")
print("no package dependencies")
PY
}

step_api() { (cd "$root" && scripts/api-surface.sh --check); }

step_version() {
  local version heading podspec podspec_version
  version="$(sdk_declared_version "$root")" || fail "cannot read the declared version"
  sdk_check_version_grammar "$version" || fail "$SDK_VERSION_FILE declares $version, which no release tag can be"
  heading="$(sdk_changelog_heading "$root" "$version")" ||
    fail "add the '## [$version]' entry to $SDK_CHANGELOG: every declared version has one"
  # CocoaPods reads a pod's version, and the version of the pods it depends on, from s.version, not from the tag.
  for podspec in $SDK_PODSPECS; do
    if ! podspec_version="$(sdk_podspec_version "$root" "$podspec")"; then
      report "cannot read the version of $podspec"
    elif [ "$podspec_version" != "$version" ]; then
      report "$podspec declares $podspec_version, not $version: set s.version of every podspec to the declared version"
    fi
  done
  [ "$problems" -eq 0 ] || fail "$problems podspec version problem(s)"
  echo "$SDK_VERSION_FILE declares $version; $SDK_CHANGELOG: $heading; the podspecs ($SDK_PODSPECS) set $version"
}

# The golden payloads the tests read are the SallaPush server's wire contract: regular files, copies of the contract's,
# which scripts/common.sh pins by sha256.
step_goldens() {
  local name file expected actual
  for name in $SDK_GOLDEN_NAMES; do
    file="$SDK_GOLDEN_DIR/$name.json"
    expected="$(sdk_golden_sha256 "$name")"
    if [ -L "$root/$file" ]; then
      report "$file is a symbolic link; it must be a regular file, a copy of the contract's payload"
    elif [ ! -f "$root/$file" ]; then
      report "$file is missing"
    else
      actual="$(sdk_sha256_of "$root/$file")"
      [ "$actual" = "$expected" ] ||
        report "$file has sha256 $actual, not the contract's $expected: the golden payloads are the SallaPush server's wire contract; change one only together with that contract, then its sha256 in scripts/common.sh"
    fi
  done
  [ "$problems" -eq 0 ] || fail "$problems golden payload problem(s)"
  echo "the golden payloads ($SDK_GOLDEN_NAMES) are the contract's: their sha256 are the ones scripts/common.sh pins"
}

step_catalogue() { "$scripts/check-log-catalogue.sh"; }

# Every relative Markdown link must resolve inside the repository; absolute links are refused.
step_links() {
  list_files "$work/files" --cached --others --exclude-standard
  # grep exits 1 when there is no Markdown file, which is no failure; a failed git stopped above.
  tr '\0' '\n' <"$work/files" | grep -E '\.md$' >"$work/markdown" || true
  [ -s "$work/markdown" ] || fail "no Markdown files: the README is missing"
  python3 - "$root" "$work/markdown" <<'PY'
import os, re, sys
from urllib.parse import unquote

root, listing = os.path.realpath(sys.argv[1]), sys.argv[2]
inline = re.compile(r'!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+(?:"[^"]*"|\'[^\']*\'))?\s*\)')
reference = re.compile(r'^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+.*)?$')
fence = re.compile(r'^\s{0,3}(```|~~~)')
problems = checked = 0
with open(listing, encoding="utf-8") as names:
    files = [line.strip() for line in names if line.strip()]
for name in files:
    path = os.path.join(root, name)
    if not os.path.isfile(path):
        continue
    in_fence = False
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, 1):
            if fence.match(line):
                in_fence = not in_fence
                continue
            if in_fence:
                continue
            text = re.sub(r'`[^`]*`', '', line)
            targets = inline.findall(text)
            match = reference.match(text)
            if match:
                targets.append(match.group(1))
            for target in targets:
                if re.match(r'^[A-Za-z][A-Za-z0-9+.-]*:', target) or target.startswith('#'):
                    continue
                checked += 1
                if target.startswith('/'):
                    print(f"{name}:{number}: {target} is an absolute link; use a path relative to the file")
                    problems += 1
                    continue
                relative = unquote(target.split('#', 1)[0].split('?', 1)[0])
                if not relative:
                    continue
                resolved = os.path.realpath(os.path.join(os.path.dirname(path), relative))
                if os.path.commonpath([resolved, root]) != root:
                    print(f"{name}:{number}: {target} points outside the repository")
                    problems += 1
                elif not os.path.exists(resolved):
                    print(f"{name}:{number}: {target} does not exist")
                    problems += 1
print(f"{len(files)} Markdown file(s), {checked} relative link(s), {problems} problem(s)")
sys.exit(1 if problems else 0)
PY
}

# File names that hold credentials or signing material, and the names of build output and Xcode user state, matched
# case-insensitively (macOS file systems ignore case).
check_path() {
  local path="$1" dir component
  local -a components
  shopt -s nocasematch
  case "${path##*/}" in
    googleservice-info.plist | google-services.json | secrets.properties | local.properties | keystore.properties | \
      id_rsa | id_dsa | id_ecdsa | id_ed25519 | id_ecdsa_sk | id_ed25519_sk | .netrc | _netrc | .git-credentials | \
      *.p8 | *.p12 | *.pfx | *.pem | *.key | *.ppk | *.cer | *.jks | *.keystore | *.mobileprovision | \
      *.provisionprofile | .env*)
      report "$path: a file of credentials or signing material; never commit it"
      ;;
    *.xcuserstate | *.pyc)
      report "$path: Xcode user state or build output; never commit it"
      ;;
  esac
  dir="${path%/*}"
  if [ "$dir" != "$path" ]; then
    IFS=/ read -r -a components <<<"$dir"
    for component in ${components[@]+"${components[@]}"}; do
      case "$component" in
        .build | build | deriveddata | .swiftpm | xcuserdata | __pycache__)
          report "$path: build output or Xcode user state ($component/); never commit it"
          break
          ;;
      esac
    done
  fi
  shopt -u nocasematch
}

# Reads "<base depth><TAB><path>" lines, and prints path:line: token for every relative reference in those files that
# climbs above the repository root, from a base directory <base depth> folders deep. A path segment holding an
# expansion ($VAR, $(cmd), ${var}, ~) stands for the base directory, which is how $(dirname "$0")/.. and $(SRCROOT)/..
# are meant.
escaping_references() {
  awk -F '\t' -v root="$root" '
    function check(token, file, number, base_depth,    n, i, seg, depth, lowest) {
      if (index(token, "..") == 0 || substr(token, 1, 1) == "/") return
      n = split(token, seg, "/")
      depth = 0; lowest = 0
      for (i = 1; i <= n; i++) {
        if (seg[i] == "" || seg[i] == ".") continue
        if (seg[i] == "..") { depth--; if (depth < lowest) lowest = depth }
        else if (seg[i] ~ /[$(){}~]/) depth = 0
        else depth++
      }
      if (-lowest > base_depth) printf "%s:%d: %s\n", file, number, token
    }
    {
      base_depth = $1 + 0
      file = $2
      source = root "/" file
      number = 0
      while ((status = (getline line < source)) > 0) {
        number++
        while (match(line, "[A-Za-z0-9_.@+~/${}()-]+")) {
          check(substr(line, RSTART, RLENGTH), file, number, base_depth)
          line = substr(line, RSTART + RLENGTH)
        }
      }
      if (status < 0) { printf "cannot read %s\n", file > "/dev/stderr"; failed = 1 }
      close(source)
    }
    END { exit failed }
  ' "$1"
}

# The files a build, the checks and a release need, and the scripts that CI, the Makefile and the README run directly.
readonly REQUIRED_FILES="Package.swift API.txt README.md CHANGELOG.md LICENSE Makefile .swiftlint.yml
Sources/SallaPushCore/SallaPushVersion.swift Sources/SallaPushCore/Logging/Logger.swift
Sources/SallaPush/PrivacyInfo.xcprivacy Sources/SallaPushExtension/PrivacyInfo.xcprivacy
Examples/SallaPushExample/SallaPushExample.xcodeproj/project.pbxproj
Examples/SallaPushExample/SallaPushExample.xcodeproj/xcshareddata/xcschemes/SallaPushExample.xcscheme
Examples/SallaPushExample/SallaPushExample.xcodeproj/xcshareddata/xcschemes/SizeBaseline.xcscheme
.github/workflows/ci.yml .github/workflows/verify.yml .github/workflows/release.yml
scripts/common.sh scripts/log-catalogue.txt"
readonly EXECUTABLE_FILES="scripts/verify.sh scripts/self-test.sh scripts/release-plan.sh scripts/release-notes.sh
scripts/api-compat.sh scripts/api-surface.sh scripts/check-gates.sh scripts/check-log-catalogue.sh
scripts/check-readme-snippets.sh scripts/size-report.sh"

step_tree() {
  local entry mode path anchor base depth slashes hit file name required
  list_files "$work/files" --cached --others --exclude-standard
  list_files "$work/staged" --stage

  # Symbolic links and submodules: staged entries by their mode (a checkout without symlink support turns a staged
  # link into a plain file), and every file a commit takes by what the working tree holds. SwiftPM checkouts and
  # archives need regular files, and the package holds no other repository.
  while IFS= read -r -d '' entry; do
    mode="${entry%% *}"
    path="${entry#*$'\t'}"
    case "$mode" in
      120000) report "$path is a symbolic link (to $(git -C "$root" cat-file blob ":$path")); commit regular files only" ;;
      160000) report "$path is a submodule; the SDK repository holds no other repository" ;;
    esac
  done <"$work/staged"

  : >"$work/regular"
  : >"$work/configs"
  while IFS= read -r -d '' path; do
    case "$path" in
      */)
        report "$path is a nested git repository; a commit would record it as a submodule"
        continue
        ;;
    esac
    check_path "$path"
    if [ -L "$root/$path" ]; then
      [ "$(git -C "$root" --literal-pathspecs ls-files --stage -- "$path" | cut -d ' ' -f 1)" = 120000 ] ||
        report "$path is a symbolic link (to $(readlink "$root/$path")); commit regular files only"
      continue
    fi
    [ -f "$root/$path" ] || continue
    printf '%s\0' "$path" >>"$work/regular"

    # Build files, scripts and tool configs must not refer to a path outside the repository. A reference resolves
    # against the file's directory; inside an Xcode project or workspace, against the directory holding the bundle
    # (so the example project's local package reference, two levels up from Examples/SallaPushExample, passes); and a
    # workflow's against the workspace root, where its steps run.
    case "${path##*/}" in
      Package.swift | Makefile | *.mk | *.pbxproj | *.xcconfig | *.xcscheme | *.xcworkspacedata | *.xctestplan | \
        *.sh | *.yml | *.yaml | *.py) ;;
      *) continue ;;
    esac
    case "$path" in
      .github/workflows/* | .github/actions/*) anchor="" ;;
      *.xcodeproj/*) anchor="${path%%.xcodeproj/*}.xcodeproj" ;;
      *.xcworkspace/*) anchor="${path%%.xcworkspace/*}.xcworkspace" ;;
      *) anchor="$path" ;;
    esac
    case "$anchor" in
      */*) base="${anchor%/*}" ;;
      *) base="" ;;
    esac
    if [ -z "$base" ]; then
      depth=0
    else
      slashes="${base//[!\/]/}"
      depth=$((${#slashes} + 1))
    fi
    printf '%s\t%s\n' "$depth" "$path" >>"$work/configs"
  done <"$work/files"
  escaping_references "$work/configs" >"$work/escapes" || fail "cannot read the build files and scripts"
  while IFS= read -r hit; do
    report "$hit resolves outside the repository"
  done <"$work/escapes"

  # Git lists a nested repository as its directory (above), but older gits list the files of one without commits
  # instead, so every directory that holds a listed file must have no .git either.
  tr '\0' '\n' <"$work/files" |
    awk -F/ '!/\/$/ { path = ""; for (i = 1; i < NF; i++) { path = path (i > 1 ? "/" : "") $i; print path } }' |
    sort -u >"$work/directories"
  while IFS= read -r path; do
    if [ -e "$root/$path/.git" ]; then
      report "$path/ is a nested git repository; a commit would record it as a submodule"
    fi
  done <"$work/directories"

  # A file over 5 MB, and a private key or a GitHub token in any file a commit takes. The report never shows the secret.
  python3 - "$root" "$work/regular" "$SDK_MAX_FILE_BYTES" >"$work/secrets" <<'PY' || fail "cannot scan the files for secrets"
import os, re, sys

# Each pattern is written so that this file's own text never matches it.
findings = (
    (re.compile(rb"-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----"), "a private key (PEM, OpenSSH, PKCS#8 or PGP)"),
    (re.compile(rb"---- BEGIN SSH2 ENCRYPTED " + rb"PRIVATE KEY ----"), "a private key (SSH2)"),
    (re.compile(rb"PuTTY-User-Key-File-[0-9]+: "), "a private key (PuTTY)"),
    (re.compile(rb"(?<![A-Za-z0-9_])gh[pousr]_[A-Za-z0-9]{36}(?![A-Za-z0-9_])"), "a GitHub token"),
    (re.compile(rb"(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9]{22}_[A-Za-z0-9]{59}(?![A-Za-z0-9_])"), "a GitHub token"),
)
root, limit = sys.argv[1], int(sys.argv[3])
with open(sys.argv[2], "rb") as listing:
    paths = [path for path in listing.read().split(b"\0") if path]
for path in paths:
    name = path.decode("utf-8", "replace")
    with open(os.path.join(root.encode(), path), "rb") as handle:
        data = handle.read()
    if len(data) > limit:
        print(f"{name}: {len(data)} bytes, over the {limit}-byte (5 MB) limit")
    for pattern, what in findings:
        if pattern.search(data):
            print(f"{name}: holds {what}; remove it, and revoke it if it was ever pushed")
            break
PY
  while IFS= read -r hit; do
    report "$hit"
  done <"$work/secrets"

  # grep reads a file here, never a pipe: grep -q stops reading early, and under pipefail the writer's SIGPIPE would
  # fail the pipeline although the file was found.
  tr '\0' '\n' <"$work/files" >"$work/file-list"
  required="$REQUIRED_FILES"
  for name in $SDK_GOLDEN_NAMES; do
    required="$required $SDK_GOLDEN_DIR/$name.json"
  done
  for file in $required $EXECUTABLE_FILES; do
    if ! grep -qxF -- "$file" "$work/file-list"; then
      report "$file is missing from what a commit takes (absent, or ignored by .gitignore)"
    elif [ -L "$root/$file" ] || [ ! -f "$root/$file" ]; then
      report "$file must be a regular file"
    fi
  done
  for file in $EXECUTABLE_FILES; do
    [ -f "$root/$file" ] || continue
    [ -x "$root/$file" ] || report "$file is not executable (chmod +x $file)"
    mode="$(git -C "$root" ls-files --stage -- "$file" | cut -d ' ' -f 1)"
    case "$mode" in
      '' | 100755) ;;
      *) report "$file is staged with mode $mode; stage it as executable (git update-index --chmod=+x $file)" ;;
    esac
  done

  # Workflows: every action pinned to a full commit id, except this repository's reusable workflows; and no
  # pull_request_target workflow that checks out code, since it runs with this repository's secrets for anyone's pull
  # request.
  tr '\0' '\n' <"$work/files" | grep -E '^\.github/workflows/[^/]+\.ya?ml$' >"$work/workflows" || true
  python3 - "$root" "$work/workflows" >"$work/workflow-problems" <<'PY' || fail "cannot read the workflows"
import os, re, sys

root, listing = sys.argv[1], sys.argv[2]
uses = re.compile(r"^\s*(?:-\s+)?uses:\s*(['\"]?)([^\s'\"#]+)\1\s*(?:#.*)?$")
pinned = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[^@\s]+)?@[0-9a-f]{40}$")
local = re.compile(r"^\./\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$")
with open(listing, encoding="utf-8") as names:
    files = [line.strip() for line in names if line.strip()]
for name in files:
    with open(os.path.join(root, name), encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    checkout = target = False
    for number, line in enumerate(lines, 1):
        match = uses.match(line)
        if match:
            reference = match.group(2)
            if not (pinned.match(reference) or local.match(reference)):
                print(f"{name}:{number}: uses {reference}; pin the action to a full commit id (owner/repo@<40 hex> # vX.Y.Z)")
            if reference.startswith("actions/checkout@"):
                checkout = True
        if re.match(r"^\s*pull_request_target\s*:", line) or re.match(r"^on:\s*\[?.*\bpull_request_target\b", line):
            target = True
    if target and checkout:
        print(f"{name}: a pull_request_target workflow checks out code; it runs with this repository's secrets for "
              "any pull request, so it must never run the pull request's code")
PY
  while IFS= read -r hit; do
    report "$hit"
  done <"$work/workflow-problems"

  [ "$problems" -eq 0 ] || fail "$problems problem(s) in what a commit takes"
  echo "$(tr -cd '\0' <"$work/files" | wc -c | tr -d ' ') files: no secret, credential, build output, symbolic link, submodule, nested repository or file over 5 MB; nothing reaches outside the repository; every required file present and every script executable; every workflow action pinned"
}

# Every compiler warning is an error: the SDK and its tests build without one.
step_build() { (cd "$root" && swift build -Xswiftc -warnings-as-errors); }
step_test() { (cd "$root" && swift test -Xswiftc -warnings-as-errors); }
step_tsan() { (cd "$root" && swift test --sanitize=thread -Xswiftc -warnings-as-errors); }

# The scheme that builds and tests every target: Xcode names it <package name>-Package for a package with several
# products. It is read from the manifest, not from xcodebuild -list, which cannot take -derivedDataPath and would
# record the package in Xcode's default DerivedData.
package_scheme() {
  (cd "$root" && swift package dump-package) >"$work/package.json"
  python3 - "$work/package.json" <<'PY'
import json, sys
package = json.load(open(sys.argv[1]))
products = [product.get("name") for product in package.get("products", [])]
if len(products) < 2:
    sys.exit(f"expected a package with several products, whose Xcode scheme is <name>-Package; found {products}")
print(package["name"] + "-Package")
PY
}

# A stock iPhone simulator of the newest model on the newest iOS runtime the selected Xcode supports. Stock devices
# (named like their device type) win over custom ones; a device type that needs a newer iOS is a newer model, and
# simctl lists the flagship of a generation first.
simulator() {
  local sdk
  sdk="$(xcrun --sdk iphonesimulator --show-sdk-version)"
  xcrun simctl list runtimes available -j >"$work/runtimes.json"
  xcrun simctl list devicetypes -j >"$work/devicetypes.json"
  xcrun simctl list devices available -j >"$work/devices.json"
  python3 - "$sdk" "$work/runtimes.json" "$work/devicetypes.json" "$work/devices.json" <<'PY'
import json, sys

def version(text):
    return tuple(int(part) for part in text.split(".") if part.isdigit())

sdk = version(sys.argv[1])
runtimes = json.load(open(sys.argv[2]))["runtimes"]
types = json.load(open(sys.argv[3]))["devicetypes"]
devices = json.load(open(sys.argv[4]))["devices"]
position = {t["identifier"]: index for index, t in enumerate(types)}
generation = {t["identifier"]: t.get("minRuntimeVersion", 0) for t in types}
names = {t["identifier"]: t["name"] for t in types}
candidates = []
for runtime in runtimes:
    platform = runtime.get("platform") or runtime.get("name", "").split(" ")[0]
    if platform != "iOS" or not runtime.get("isAvailable", True) or version(runtime["version"]) > sdk:
        continue
    for device in devices.get(runtime["identifier"], []):
        kind = device.get("deviceTypeIdentifier", "")
        if not kind.startswith("com.apple.CoreSimulator.SimDeviceType.iPhone"):
            continue
        candidates.append((version(runtime["version"]), device["name"] == names.get(kind), generation.get(kind, 0),
                           -position.get(kind, len(types)), device["udid"], device["name"], runtime["version"]))
if not candidates:
    sys.exit(f"no available iPhone simulator for iOS {sys.argv[1]} or older; install a simulator runtime")
best = max(candidates)
print(f"{best[4]}\t{best[5]} (iOS {best[6]})")
PY
}

# Sets derived to the -derivedDataPath arguments of one build (package or example), or to nothing for Xcode's default
# DerivedData (VERIFY_DERIVED_DATA unset).
derived=()
derived_data() {
  derived=()
  [ -z "${VERIFY_DERIVED_DATA:-}" ] || derived=(-derivedDataPath "$VERIFY_DERIVED_DATA/$1")
}

xcode_test() {
  local scheme picked udid
  scheme="$(package_scheme)"
  if [ -n "${VERIFY_SIMULATOR_UDID:-}" ]; then
    udid="$VERIFY_SIMULATOR_UDID"
    xcrun simctl list devices available >"$work/devices.txt"
    grep -qF "($udid)" "$work/devices.txt" || fail "VERIFY_SIMULATOR_UDID $udid is not an available simulator"
    picked="$udid"$'\t'"VERIFY_SIMULATOR_UDID"
  else
    picked="$(simulator)"
    udid="${picked%%$'\t'*}"
  fi
  echo "scheme $scheme, simulator ${picked#*$'\t'} $udid"
  derived_data package
  # Serially, on that one simulator: parallel testing would clone it for every test runner.
  (cd "$root" && xcodebuild test -scheme "$scheme" -destination "platform=iOS Simulator,id=$udid" \
    -parallel-testing-enabled NO ${derived[@]+"${derived[@]}"} "$@") 2>&1 | tee "$work/xcodebuild-test.log"
  # The Main Thread Checker only logs; any report is a failure here.
  if grep -n 'Main Thread Checker:' "$work/xcodebuild-test.log"; then
    fail "the Main Thread Checker reported UIKit use off the main thread"
  fi
}

step_xcode_test() { xcode_test; }
step_xcode_tsan() { xcode_test -enableThreadSanitizer YES; }

step_extension() {
  derived_data package
  (cd "$root" && xcodebuild build -quiet -scheme SallaPushExtension -destination 'generic/platform=iOS' \
    ${derived[@]+"${derived[@]}"} APPLICATION_EXTENSION_API_ONLY=YES CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES)
}

# Objective-C warnings only: Xcode builds the package as a dependency of the example with -suppress-warnings, which
# SWIFT_TREAT_WARNINGS_AS_ERRORS can't be combined with (the build and extension steps cover the package's Swift).
step_example() {
  derived_data example
  (cd "$root" && xcodebuild build -quiet -project Examples/SallaPushExample/SallaPushExample.xcodeproj \
    -scheme SallaPushExample -destination 'generic/platform=iOS Simulator' ${derived[@]+"${derived[@]}"} \
    CODE_SIGNING_ALLOWED=NO GCC_TREAT_WARNINGS_AS_ERRORS=YES)
}

# The README check, then its self-test: proof, on scratch copies, that the checker still catches every kind of drift
# (python3 only, seconds).
step_snippets() {
  (cd "$root" && scripts/check-readme-snippets.sh)
  (cd "$root" && scripts/check-readme-snippets.sh --self-test)
}

# The gate is passed to the size script, so a SIZE_REPORT_BUDGET_BYTES left in the caller's environment can never
# change it, and the script's own default must be the same number (CONTRIBUTING.md states it: 5 MB).
step_size() {
  local script="$root/scripts/size-report.sh" budgets
  budgets="$(sed -nE 's/^budget="\$\{SIZE_REPORT_BUDGET_BYTES:-([0-9]+)\}"$/\1/p' "$script")"
  [ "$(printf '%s' "$budgets" | grep -c '')" -eq 1 ] ||
    fail "scripts/size-report.sh must set its default budget once, as budget=\"\${SIZE_REPORT_BUDGET_BYTES:-<bytes>}\""
  [ "$budgets" = "$SDK_SIZE_GATE_BYTES" ] ||
    fail "scripts/size-report.sh sets a default budget of $budgets bytes; the size gate is $SDK_SIZE_GATE_BYTES bytes (5 MB)"
  if [ -n "${SIZE_REPORT_BUDGET_BYTES+set}" ] && [ "$SIZE_REPORT_BUDGET_BYTES" != "$SDK_SIZE_GATE_BYTES" ]; then
    echo "SIZE_REPORT_BUDGET_BYTES=$SIZE_REPORT_BUDGET_BYTES is ignored: the size gate is $SDK_SIZE_GATE_BYTES bytes"
  fi
  echo "size budget: $SDK_SIZE_GATE_BYTES bytes (5 MB; also the default of scripts/size-report.sh)"
  if [ -n "${VERIFY_DERIVED_DATA:-}" ]; then
    (cd "$root" && SIZE_REPORT_BUDGET_BYTES="$SDK_SIZE_GATE_BYTES" \
      SIZE_REPORT_DERIVED_DATA="$VERIFY_DERIVED_DATA/size-report" scripts/size-report.sh)
  else
    (cd "$root" && SIZE_REPORT_BUDGET_BYTES="$SDK_SIZE_GATE_BYTES" scripts/size-report.sh)
  fi
}

# ---------------------------------------------------------------------------------------------------------------------
# Runner

case "${1:-}" in -h | --help) usage ;; esac
steps="$*"
[ -n "$steps" ] || steps="$STEPS"
for step in $steps; do
  case " $STEPS " in
    *" $step "*) ;;
    *) fail "unknown step '$step' (steps: $STEPS)" ;;
  esac
  case " $PORTABLE_STEPS " in
    *" $step "*) ;;
    *) require_macos ;;
  esac
done

logs="${VERIFY_LOG_DIR:-$work/logs}"
mkdir -p "$logs"
summary="$logs/summary.tsv"
[ -f "$summary" ] || printf 'step\tresult\tseconds\n' >"$summary"
grouped=false
[ "${GITHUB_ACTIONS:-}" != true ] || [ "$steps" = "${steps%% *}" ] || grouped=true

for step in $steps; do
  function_name="step_$(printf '%s' "$step" | tr - _)"
  log="$logs/$step.log"
  ! $grouped || echo "::group::verify.sh $step"
  echo "==> verify.sh $step"
  started="$(date +%s)"
  # A subshell with errexit, outside any if/!/&& context, so a failing command inside a step can never be ignored.
  set +e
  (
    set -e
    "$function_name"
  ) 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  set -e
  seconds=$(($(date +%s) - started))
  ! $grouped || echo "::endgroup::"
  if [ "$status" -ne 0 ]; then
    printf '%s\tfailed\t%s\n' "$step" "$seconds" >>"$summary"
    # Without VERIFY_LOG_DIR the logs live in the temporary directory, which is removed on exit.
    fail "$step failed (exit $status) after ${seconds}s${VERIFY_LOG_DIR:+; log: $log}"
  fi
  printf '%s\tpassed\t%s\n' "$step" "$seconds" >>"$summary"
  echo "==> verify.sh $step: passed in ${seconds}s"
done
echo "verify.sh: all passed ($steps)"
