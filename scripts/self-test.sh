#!/usr/bin/env bash
# Tests of this repository's own tooling, each in a throwaway repository under a temporary directory:
#   - scripts/release-plan.sh, the release workflow's tag checks: the version grammar, the declared version and the
#     CHANGELOG entry at the tagged commit, stable tags only on master, the API baselines (every earlier stable release
#     of the major version, from the first public version on) and the major-bump flag;
#   - the filter of scripts/api-compat.sh, which leaves the package declarations out of the API comparison (the
#     comparison itself needs Xcode);
#   - scripts/release-notes.sh, the GitHub Release's notes: the body of the version's CHANGELOG entry, with relative
#     links that also work on the release page;
#   - the steps of scripts/verify.sh that need no Xcode (version, goldens, catalogue, links, tree) and
#     scripts/check-log-catalogue.sh, with each refusal, on copies of this repository's files.
# The cases read the version this repository declares, so a release's version bump never touches them. It needs bash,
# git and python3, no Xcode, and never touches this repository. The scratch commits and tags use an isolated git
# configuration (HOME, no global or system config) and are never signed or pushed.
#
#   scripts/self-test.sh
set -euo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$scripts/.." && pwd -P)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$scripts/common.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/sallapush-self-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

# Scratch git: no global or system configuration (git before 2.32 ignores GIT_CONFIG_GLOBAL, hence HOME), never signed.
mkdir -p "$work/home"
export HOME="$work/home" XDG_CONFIG_HOME="$work/home/.config" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=self-test GIT_AUTHOR_EMAIL=self-test@example.invalid
export GIT_COMMITTER_NAME=self-test GIT_COMMITTER_EMAIL=self-test@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

passed=0
failed=0
out="$work/out"

section() { printf '\n== %s\n' "$1"; }

# check <label> <ok|fails> <command...>: runs the command, its output into $out, and expects it to pass or fail.
check() {
  local label="$1" want="$2" status=0
  shift 2
  "$@" >"$out" 2>&1 || status=$?
  if { [ "$want" = ok ] && [ "$status" -eq 0 ]; } || { [ "$want" = fails ] && [ "$status" -ne 0 ]; }; then
    passed=$((passed + 1))
    echo "ok   $label"
  else
    failed=$((failed + 1))
    echo "FAIL $label (exit $status, expected $want)"
    sed 's/^/       /' "$out"
  fi
}

# says <label> <text>: a line of the last check's output holds the text. says_line <label> <line>: one is the line.
says() {
  if grep -qF -- "$2" "$out"; then
    passed=$((passed + 1))
    echo "ok   $1"
  else
    failed=$((failed + 1))
    echo "FAIL $1: the output does not say '$2'"
    sed 's/^/       /' "$out"
  fi
}

says_line() {
  if grep -qxF -- "$2" "$out"; then
    passed=$((passed + 1))
    echo "ok   $1"
  else
    failed=$((failed + 1))
    echo "FAIL $1: no output line is '$2'"
    sed 's/^/       /' "$out"
  fi
}

# ---------------------------------------------------------------------------------------------------------------------
# release-plan.sh

test_release_plan() {
  local repo="$work/release" c1 c2 c3 c4 c5 side head
  section "release-plan.sh (release.yml, job Resolve the release)"
  mkdir -p "$repo/scripts" "$repo/Sources/SallaPushCore"
  cp "$scripts/release-plan.sh" "$scripts/common.sh" "$repo/scripts/"
  g() { git -C "$repo" -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }
  version() { printf 'package let sallaPushSDKVersion = "%s"\n' "$1" >"$repo/Sources/SallaPushCore/SallaPushVersion.swift"; }
  changelog() {
    local heading
    printf '# Changelog\n' >"$repo/CHANGELOG.md"
    for heading; do printf '\n%s\n\n- A change.\n' "$heading" >>"$repo/CHANGELOG.md"; done
  }
  commit() { g add -A && g commit -q -m "$1" && g rev-parse HEAD; }
  # side_commit <parent> <message>: a commit of the working tree off master, made without a checkout or a branch.
  side_commit() { g add -A && g commit-tree "$(g write-tree)" -p "$1" -m "$2"; }
  # release <version> <message>: declares the version with its CHANGELOG entry, commits, and tags the commit.
  release() {
    version "$1"
    changelog "## [$1] - 2026-10-20"
    g tag "$1" "$(commit "$2")"
  }
  plan() { (cd "$repo" && scripts/release-plan.sh "$@"); }
  g init -q
  g symbolic-ref HEAD refs/heads/master

  version 1.0.0-beta.1
  changelog '## [1.0.0-beta.1] - Unreleased'
  c1="$(commit beta1)"
  g update-ref refs/remotes/origin/master "$c1"
  g tag 1.0.0-beta.1 "$c1"
  check "a pre-release on master passes" ok plan 1.0.0-beta.1
  says "an 'Unreleased' heading is reported" "still says it is unreleased"
  check "it prints exactly the five outputs on stdout" ok test "$(plan 1.0.0-beta.1 2>/dev/null)" = \
    "$(printf 'version=1.0.0-beta.1\nprerelease=true\nsha=%s\napi_baselines=\nmajor_bump=false' "$c1")"
  for bad in v1.0.0 1.0 1.0.0-beta 1.0.0-preview.1 01.0.0 1.0.0+build.1 1.0.0-beta.01 1.0.0-beta.1.2 \
    123456789012.123456789012.1234567-rc.1; do
    check "the tag '$bad' is refused" fails plan "$bad"
    says "it says why ($bad)" "is not a release"
  done
  check "an unknown tag is refused" fails plan 1.0.0-beta.9
  says "it says why" "does not exist in this clone"

  g tag -a -m "SallaPush iOS SDK 1.0.0-beta.2" 1.0.0-beta.2 "$c1"
  check "a tag of a commit that declares another version is refused" fails plan 1.0.0-beta.2
  says "it names both versions" "declares 1.0.0-beta.1 at $c1, but the tag is 1.0.0-beta.2"
  g tag -d 1.0.0-beta.2 >/dev/null

  version 1.0.0
  changelog '## [1.0.0-rc.1] - 2026-10-05' '## [1.0.0-beta.1] - 2026-10-04'
  c2="$(commit no-entry)"
  g update-ref refs/remotes/origin/master "$c2"
  g tag 1.0.0 "$c2"
  check "a version without its CHANGELOG entry is refused (another version's heading is no entry)" fails plan 1.0.0
  says "it says which entry" "has no single '## [1.0.0]' entry"
  g tag -d 1.0.0 >/dev/null
  changelog '## [1.0.0] - 2026-10-06' '## [1.0.0] - 2026-10-05'
  c3="$(commit two-entries)"
  g update-ref refs/remotes/origin/master "$c3"
  g tag 1.0.0 "$c3"
  check "two entries of one version are refused" fails plan 1.0.0
  says "it counts them" "(found 2)"
  g tag -d 1.0.0 >/dev/null

  changelog '## [1.0.0] - 2026-10-06'
  c4="$(commit stable)"
  g update-ref refs/remotes/origin/master "$c4"
  g tag -a -m "SallaPush iOS SDK 1.0.0" 1.0.0 "$c4"
  check "the first stable release passes, compared with no release" ok plan 1.0.0
  says_line "an annotated tag peels to its commit" "sha=$c4"
  says_line "no baseline" "api_baselines="
  says_line "no major bump" "major_bump=false"
  says_line "stable" "prerelease=false"

  version 1.1.1
  changelog '## [1.1.1] - 2026-10-07'
  side="$(side_commit "$c4" side)"
  g tag 1.1.1 "$side"
  check "a stable tag off master is refused" fails plan 1.1.1
  says "it says why" "must tag a commit on master"
  version 1.1.0-beta.1
  changelog '## [1.1.0-beta.1] - 2026-10-07'
  head="$(side_commit "$side" side-beta)"
  g tag 1.1.0-beta.1 "$head"
  check "a pre-release off master passes" ok plan 1.1.0-beta.1
  says "it says so" "is not on master"
  says_line "a pre-release is compared with no release" "api_baselines="

  version 1.1.0
  changelog '## [1.1.0] - 2026-10-08'
  c5="$(commit minor)"
  g tag 1.1.0 "$c5"
  release 1.9.0 1.9
  release 1.10.0 1.10
  release 2.0.0 major
  # 2.1.0's release run may have failed (an API break, say): its tag stays, and SwiftPM installs it all the same.
  release 2.1.0 2.1
  release 2.1.1 2.1.1
  g update-ref refs/remotes/origin/master "$(g rev-parse HEAD)"
  check "1.1.0, the first public version, passes" ok plan 1.1.0
  says_line "1.1.0 is compared with no release: 1.0.0, below the first public version, was never public" "api_baselines="
  says_line "1.1.0 is no major bump" "major_bump=false"
  check "versions sort as versions" ok plan 1.10.0
  says_line "1.10.0 is compared with every earlier public 1.x release, oldest first: not 1.0.0, the off-master 1.1.1 or pre-releases" \
    "api_baselines=1.1.0 1.9.0"
  check "a major version is a major bump" ok plan 2.0.0
  says_line "2.0.0 is compared with no release" "api_baselines="
  says_line "2.0.0 is a major bump" "major_bump=true"
  check "a release is compared with every earlier release of its major version, not only the last one" ok plan 2.1.1
  says_line "2.1.1 must keep 2.0.0's API as well as 2.1.0's" "api_baselines=2.0.0 2.1.0"
  says_line "2.1.1 is no major bump" "major_bump=false"
  g update-ref -d refs/remotes/origin/master
  check "a stable release without origin/master is refused" fails plan 2.0.0
  says "it says why" "refs/remotes/origin/master is missing"
  check "RELEASE_MASTER_REF names another master ref" ok env RELEASE_MASTER_REF=refs/heads/master "$repo/scripts/release-plan.sh" 2.0.0
  check "no argument is a usage error" fails plan
}

# ---------------------------------------------------------------------------------------------------------------------
# api-compat.sh --public: the API comparison of a release leaves out what no app can use. The comparison itself needs
# Xcode; its filter runs anywhere.

test_api_compat() {
  local dumps="$work/api-compat" name
  section "api-compat.sh --public, the filter of the release workflow's API comparison"
  mkdir -p "$dumps"
  # Stand-ins for swift-api-digester's dumps of SallaPushCore: a baseline; a commit that changes only package
  # declarations (new cases of a package enum, a package method's new parameter, a renamed package property, a dropped
  # package setter and a dropped conformance to a package protocol); one that adds a case to a public enum; and one that
  # makes a public property package.
  python3 - "$dumps" <<'PY'
import json
import os
import sys


def node(kind, decl_kind, name, usr, package=False, **lists):
    item = {"kind": kind, "name": name, "printedName": name, "declKind": decl_kind, "usr": usr,
            "moduleName": "SallaPushCore"}
    if package:
        item["isInternal"] = True
    item.update(lists)
    return item


def accessor(owner, name, package=False):
    return node("Accessor", "Accessor", name, f"s:{owner}.{name}", package)


def dump(levels=("off", "warn"), codes=("init.started", "register.ok"), events="events(deviceId:body:completion:)",
         code_is_package=False, raw="raw", package_setter=True, redactable=True):
    conformances = [{"kind": "Conformance", "name": "Equatable", "printedName": "Equatable", "usr": "s:SQ"}]
    if redactable:
        conformances.append({"kind": "Conformance", "name": "Redactable", "printedName": "Redactable",
                             "usr": "s:Redactable"})
    message = [accessor("SallaPushLogEntry.message", "get")]
    if package_setter:
        message.append(accessor("SallaPushLogEntry.message", "set", package=True))
    children = [
        node("TypeDecl", "Enum", "SallaPushLogLevel", "s:SallaPushLogLevel", conformances=conformances,
             children=[node("Var", "EnumElement", level, f"s:SallaPushLogLevel.{level}") for level in levels]),
        node("TypeDecl", "Class", "SallaPushLogEntry", "s:SallaPushLogEntry", children=[
            node("Var", "Var", "code", "s:SallaPushLogEntry.code", code_is_package,
                 accessors=[accessor("SallaPushLogEntry.code", "get", code_is_package)]),
            node("Var", "Var", "message", "s:SallaPushLogEntry.message", accessors=message),
            node("Var", "Var", raw, f"s:SallaPushLogEntry.{raw}", package=True),
        ]),
        node("TypeDecl", "Enum", "LogCode", "s:LogCode", package=True,
             children=[node("Var", "EnumElement", code, f"s:LogCode.{code}", package=True) for code in codes]),
        node("TypeDecl", "Class", "APIClient", "s:APIClient", package=True,
             children=[node("Function", "Func", events, f"s:APIClient.{events}", package=True)]),
        node("TypeDecl", "Protocol", "Redactable", "s:Redactable", package=True),
    ]
    return {"ABIRoot": {"kind": "Root", "name": "SallaPushCore", "printedName": "SallaPushCore", "children": children,
                        "json_format_version": 8}}


variants = {
    "baseline": dump(),
    "package-change": dump(codes=("init.started", "register.ok", "status.launch", "status.changed"),
                           events="events(deviceId:body:timeout:completion:)", raw="rawText", package_setter=False,
                           redactable=False),
    "public-case": dump(levels=("off", "warn", "verbose")),
    "made-package": dump(code_is_package=True),
}
for name, value in variants.items():
    with open(os.path.join(sys.argv[1], f"{name}.json"), "w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=1)
PY
  # same <a> <b>: both files hold the same JSON value. holds|lacks <dump> <usr>...: a node has each usr, or none has any.
  same() { python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))' "$1" "$2"; }
  usrs() {
    python3 - "$@" <<'PY'
import json
import sys

mode, path, wanted = sys.argv[1], sys.argv[2], sys.argv[3:]
found = set()


def walk(value):
    if isinstance(value, dict):
        if "usr" in value:
            found.add(value["usr"])
        for item in value.values():
            walk(item)
    elif isinstance(value, list):
        for item in value:
            walk(item)


with open(path, encoding="utf-8") as handle:
    walk(json.load(handle))
wrong = [usr for usr in wanted if (usr in found) != (mode == "holds")]
if wrong:
    sys.exit(f"{path}: {'missing' if mode == 'holds' else 'still there'}: {' '.join(wrong)}")
PY
  }
  holds() { usrs holds "$@"; }
  lacks() { usrs lacks "$@"; }

  for name in baseline package-change public-case made-package; do
    check "it filters the $name dump, without Xcode" ok \
      "$scripts/api-compat.sh" --public "$dumps/$name.json" "$dumps/$name.public.json"
  done
  check "a change to package declarations alone leaves the compared API as it was" ok \
    same "$dumps/baseline.public.json" "$dumps/package-change.public.json"
  check "the public declarations, their getters and their public conformances stay" ok \
    holds "$dumps/baseline.public.json" s:SallaPushLogLevel s:SallaPushLogLevel.warn s:SallaPushLogEntry.code \
    s:SallaPushLogEntry.code.get s:SallaPushLogEntry.message s:SallaPushLogEntry.message.get s:SQ
  check "the package declarations, a package setter and a conformance to a package protocol go" ok \
    lacks "$dumps/baseline.public.json" s:LogCode s:LogCode.init.started s:APIClient s:Redactable \
    s:SallaPushLogEntry.raw s:SallaPushLogEntry.message.set
  check "a new case of a public enum is still compared" fails \
    same "$dumps/baseline.public.json" "$dumps/public-case.public.json"
  check "a public declaration made package leaves the compared API, a break" ok \
    lacks "$dumps/made-package.public.json" s:SallaPushLogEntry.code s:SallaPushLogEntry.code.get
  printf '{"kind": "Root"}\n' >"$dumps/other.json"
  check "a file that is no dump of the digester is refused" fails \
    "$scripts/api-compat.sh" --public "$dumps/other.json" "$dumps/other.public.json"
  says "it says why" "is not an API dump of swift-api-digester"
  check "the filter takes a dump and an output" fails "$scripts/api-compat.sh" --public "$dumps/baseline.json"

  # Comparison reports as the digester writes them: breaks under /* Section */ headers.
  local accepted="Func SallaPushNotifications.willPresent(_:presentationOptions:) has been removed"
  local other="Func SallaPushNotifications.clearAll() has been removed"
  printf '\n/* Generic Signature Changes */\n\n/* Removed Decls */\n\n/* Type Changes */\n' >"$dumps/none.report"
  printf '\n/* Removed Decls */\n%s\n\n/* Type Changes */\n' "$accepted" >"$dumps/accepted.report"
  printf '\n/* Removed Decls */\n%s\n%s\n' "$accepted" "$other" >"$dumps/both.report"
  check "a report without a break passes" ok "$scripts/api-compat.sh" --breaks "$dumps/none.report"
  check "a report whose only break was made on purpose passes" ok "$scripts/api-compat.sh" --breaks "$dumps/accepted.report"
  says "it names the accepted one" "accepted, made on purpose: $accepted"
  check "any other break fails" fails "$scripts/api-compat.sh" --breaks "$dumps/both.report"
  says_line "it prints the break" "$other"
  says "and still names the accepted one" "accepted, made on purpose: $accepted"
  check "the breaks take a report" fails "$scripts/api-compat.sh" --breaks "$dumps/missing.report"
}

# ---------------------------------------------------------------------------------------------------------------------
# release-notes.sh

test_release_notes() {
  local repo="$work/notes"
  section "release-notes.sh (release.yml, job GitHub Release)"
  mkdir -p "$repo/scripts"
  cp "$scripts/release-notes.sh" "$scripts/common.sh" "$repo/scripts/"
  notes() { (cd "$repo" && scripts/release-notes.sh "$@"); }
  cat >"$repo/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

- Not released yet.

## [1.1.0] - 2026-10-20


### Changed

- See [the guide](docs/GUIDE.md#setup), [the site](https://example.com/a), [above](#top) and [the root](/README.md).

## [1.0.0] - 2026-10-10

- The first release.

## [1.0.1-beta.1] - 2026-10-11

## [2.0.0] - 2026-10-21

- Twice.

## [2.0.0] - 2026-10-22

- Twice again.
EOF
  check "a version's notes are the body of its entry" ok notes 1.1.0
  cp "$out" "$work/notes-1.1.0.md"
  check "  ... from its first line, without the heading or the blank lines after it" ok \
    test "$(sed -n 1p "$work/notes-1.1.0.md")" = "### Changed"
  check "  ... up to the next entry" fails grep -q "The first release" "$work/notes-1.1.0.md"
  check "  ... with its relative links as they are" ok grep -qF "[the guide](docs/GUIDE.md#setup)" "$work/notes-1.1.0.md"
  check "a link base makes the relative links point to the tagged files" ok \
    env RELEASE_NOTES_LINK_BASE=https://github.example.invalid/o/r/blob/1.1.0/ "$repo/scripts/release-notes.sh" 1.1.0
  says "  ... a relative link" "[the guide](https://github.example.invalid/o/r/blob/1.1.0/docs/GUIDE.md#setup)"
  says "  ... an absolute link stays" "[the site](https://example.com/a)"
  says "  ... an anchor stays" "[above](#top)"
  says "  ... a link from the root stays" "[the root](/README.md)"
  check "an entry that says nothing fails" fails notes 1.0.1-beta.1
  says "it says why" "the '## [1.0.1-beta.1]' entry of CHANGELOG.md says nothing"
  check "a version without an entry fails" fails notes 3.0.0
  says "it says why" "must have exactly one '## [3.0.0]' entry (found 0)"
  check "a version with two entries fails" fails notes 2.0.0
  says "it counts them" "(found 2)"
  check "a tag that is no release version fails" fails notes Unreleased
  says "it says why" "is not a release version"
  check "no argument is a usage error" fails notes
}

# ---------------------------------------------------------------------------------------------------------------------
# verify.sh, the steps that need no Xcode, and check-log-catalogue.sh

test_verify_portable() {
  local pristine="$work/pristine" case="$work/case" name version golden logger catalogue checkout_pin up
  section "verify.sh version, goldens, catalogue, links and tree; check-log-catalogue.sh"
  # The repository's own files (what a commit would take), into a scratch repository; each case changes a fresh copy.
  mkdir -p "$pristine"
  git -C "$root" ls-files -z --cached --others --exclude-standard >"$work/files"
  while IFS= read -r -d '' name; do
    mkdir -p "$pristine/$(dirname "$name")"
    cp -p "$root/$name" "$pristine/$name"
  done <"$work/files"
  git -C "$pristine" init -q
  fresh() {
    rm -rf "${case:?}"
    cp -Rp "$pristine" "$case"
  }
  g() { git -C "$case" -c commit.gpgsign=false "$@"; }
  run() { (cd "$case" && scripts/verify.sh "$@"); }
  # edit <file> <old> <new>: replaces the first <old> in the copy's <file>; stops the self-test when <old> is missing.
  edit() {
    python3 - "$case/$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
if old not in text:
    sys.exit(f"self-test.sh: {path} does not contain {old!r}; update the case")
with open(path, "w", encoding="utf-8") as handle:
    handle.write(text.replace(old, new, 1))
PY
  }
  # row <code> <level> <platform> <category>: rewrites the copy's catalogue line of <code>.
  row() {
    python3 - "$case/scripts/log-catalogue.txt" "$@" <<'PY'
import sys
path, code, level, platform, category = sys.argv[1:6]
with open(path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")
found = [number for number, line in enumerate(lines) if line.split()[:1] == [code]]
if len(found) != 1:
    sys.exit(f"self-test.sh: {path} has no single line for {code}; update the case")
lines[found[0]] = f"{code:<30} {level:<8} {platform:<8} {category}"
with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
PY
  }
  # The parent steps are spelled at run time: this file is a script of the repository, and the tree step reads it too.
  up=..

  fresh
  check "this repository's files pass" ok run version goldens catalogue links tree
  check "an unknown step is refused" fails run lint-everything
  says "it lists the steps" "steps: lint gates deps api version goldens catalogue links tree"

  # The version this repository declares, whatever it is.
  version="$(sdk_declared_version "$pristine")"
  fresh; edit CHANGELOG.md "## [$version]" "## [$version.9]"
  check "a version without its CHANGELOG entry fails" fails run version
  says "it says which entry" "add the '## [$version]' entry to CHANGELOG.md"
  fresh; edit "$SDK_VERSION_FILE" "\"$version\"" '"1.0.0-preview"'
  check "an unreleasable version fails" fails run version
  says "it says why" "which no release tag can be"
  fresh; edit "$SDK_VERSION_FILE" "\"$version\"" '"1.0.0-alpha.123456789012345678901234"'
  check "a version over 32 characters fails" fails run version
  says "it says why" "longer than the 32-character sdk_version limit"
  fresh; printf 'package let sallaPushSDKVersion = "%s"\n' "$version" >>"$case/$SDK_VERSION_FILE"
  check "a version declared twice fails" fails run version
  says "it says why" "must declare sallaPushSDKVersion exactly once"
  fresh; edit SallaPush.podspec "'$version'" "'$version.9'"
  check "a podspec that sets another version fails" fails run version
  says "it names the podspec and both versions" "SallaPush.podspec declares $version.9, not $version"
  fresh; edit SallaPushExtension.podspec "s.version " "s.summary_version "
  check "a podspec that sets no version fails" fails run version
  says "it says which" "SallaPushExtension.podspec must set s.version exactly once"
  fresh; edit SallaPushCore.podspec "'$version'" "\"$version\""
  check "a version in double quotes counts" ok run version

  golden="$SDK_GOLDEN_DIR/compat-push-ref.json"
  fresh; printf ' ' >>"$case/$golden"
  check "a changed golden payload fails" fails run goldens
  says "it names it" "$golden has sha256"
  says "  ... and whose it must be" "not the contract's"
  fresh; rm "${case:?}/${golden:?}"
  check "a missing golden payload fails" fails run goldens
  says "it names it" "$golden is missing"
  fresh; rm "${case:?}/${golden:?}"; ln -s "$case/README.md" "$case/$golden"
  check "a golden payload that is a symbolic link fails" fails run goldens
  says "it says why" "$golden is a symbolic link"

  logger=Sources/SallaPushCore/Logging/Logger.swift
  catalogue=scripts/log-catalogue.txt
  fresh; edit "$logger" "case .notifForeign:
            return .verbose" "case .notifForeign:
            return .debug"
  check "a code at another level fails" fails run catalogue
  says "it names the code and both levels" "notif.foreign: the SDK logs it at debug"
  fresh; edit "$logger" 'case "net": return "network"' 'case "net": return "storage"'
  check "a code with another category fails" fails run catalogue
  says "it names the category" "net.retry: the SDK gives it the category storage"
  fresh; edit "$logger" '    case logDropped = "log.dropped"' '    case logDropped = "log.dropped"
    case selfTestAdded = "selftest.added"'
  edit "$logger" ".logDropped, .nseAttachmentFailed" ".logDropped, .selfTestAdded, .nseAttachmentFailed"
  check "a code the catalogue lacks fails" fails run catalogue
  says "it names the code" "selftest.added exists in the SDK"
  fresh; row init.no_delegate warn android lifecycle
  check "a code the catalogue gives the Android SDK only fails" fails run catalogue
  says "it names the code" "init.no_delegate exists in the SDK"
  says "  ... and the platform" "lists it for the Android SDK only"
  fresh; printf 'selftest.missing               warn     ios      lifecycle\n' >>"$case/$catalogue"
  check "a catalogued iOS code that the SDK lacks fails" fails run catalogue
  says "it names the code" "lists selftest.missing for the iOS SDK only"
  fresh; printf 'selftest.android_only          warn     android  lifecycle\n' >>"$case/$catalogue"
  check "an Android-only code is not this SDK's, and passes" ok run catalogue
  fresh; edit "$logger" '    case logDropped = "log.dropped"' '    case logDropped = "log.dropped"
    // case selfTestComment = "selftest.comment"
    /* case selfTestBlock = "selftest.block" */'
  check "codes inside comments are not codes" ok run catalogue
  fresh; edit "$logger" 'case initStarted = "init.started"' 'case initStarted = "init.\("started")"'
  check "a code that is not a plain string literal cannot be read, and fails" fails run catalogue
  says "it says why" "is not a plain string literal"
  fresh; edit "$logger" '    case logDropped = "log.dropped"' '    case logDropped = "log.dropped"
    #if DEBUG
    case selfTestDebug = "selftest.debug"
    #endif'
  check "conditional compilation inside the enum cannot be read, and fails" fails run catalogue
  says "it says why" "#if inside enum LogCode"
  fresh; row init.started loud both lifecycle
  check "a catalogue line with an unknown level fails" fails run catalogue
  says "it says why" "init.started has the level loud"

  fresh; printf '\n[the guide](docs/missing.md) and [the root](/README.md) and [up](%s/outside.md)\n' "$up" \
    >>"$case/CHANGELOG.md"
  check "broken, absolute and escaping Markdown links fail" fails run links
  says "a missing target" "docs/missing.md does not exist"
  says "an absolute link" "/README.md is an absolute link"
  says "a link out of the repository" "$up/outside.md points outside the repository"
  fresh
  # shellcheck disable=SC2016 # literal Markdown backticks
  printf '\n```text\n[not a link](nowhere.md)\n```\n' >>"$case/CHANGELOG.md"
  check "a link inside a code block is not checked" ok run links

  fresh; : >"$case/AuthKey_ABC123DEFG.p8"
  check "an ignored signing key is not taken by a commit, and passes" ok run tree
  fresh; mkdir -p "$case/Signing"; : >"$case/Signing/Release.P12"; g add -f Signing/Release.P12
  check "a signing key added past .gitignore fails, whatever its case" fails run tree
  says "it names it" "Signing/Release.P12: a file of credentials or signing material"
  fresh; printf '<plist/>\n' >"$case/Examples/SallaPushExample/GoogleService-Info.plist"
  g add -f Examples/SallaPushExample/GoogleService-Info.plist
  check "a Firebase configuration added past .gitignore fails" fails run tree
  says "it names it" "GoogleService-Info.plist: a file of credentials"
  fresh; printf 'TOKEN=x\n' >"$case/.env.local"; g add -f .env.local
  check "a .env file added past .gitignore fails" fails run tree
  says "it names it" ".env.local: a file of credentials"
  fresh; : >"$case/Examples/id_ed25519"
  check "a credential .gitignore does not know fails" fails run tree
  says "it names it" "Examples/id_ed25519: a file of credentials"
  fresh; mkdir -p "$case/.build/debug"; : >"$case/.build/debug/SallaPush.o"; g add -f .build/debug/SallaPush.o
  check "build output added by force fails" fails run tree
  says "it names it" ".build/debug/SallaPush.o: build output or Xcode user state (.build/)"
  fresh; mkdir -p "$case/Examples/Build/Products"; : >"$case/Examples/Build/Products/app.txt"
  g add -f Examples/Build/Products/app.txt
  check "a build folder fails whatever its case" fails run tree
  says "it names it" "Examples/Build/Products/app.txt: build output or Xcode user state (Build/)"
  name=Examples/SallaPushExample/SallaPushExample.xcodeproj/xcuserdata/dev.xcuserdatad/UserInterfaceState.xcuserstate
  fresh; mkdir -p "$case/$(dirname "$name")"; : >"$case/$name"; g add -f "$name"
  check "Xcode user state added by force fails" fails run tree
  says "it names it" "UserInterfaceState.xcuserstate: Xcode user state or build output"
  fresh; head -c 5242881 /dev/zero >"$case/big.bin"
  check "a file over 5 MB fails" fails run tree
  says "it names it" "big.bin: 5242881 bytes, over the 5242880-byte (5 MB) limit"
  fresh; ln -s README.md "$case/link.md"
  check "a symbolic link fails" fails run tree
  says "it names it" "link.md is a symbolic link (to README.md)"
  fresh; ln -s README.md "$case/staged-link.md"; g add staged-link.md; rm "${case:?}/staged-link.md"
  printf 'README.md' >"$case/staged-link.md"
  check "a staged symbolic link fails, even where the checkout holds a plain file" fails run tree
  says "it names it" "staged-link.md is a symbolic link (to README.md)"
  fresh; g update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,Vendor/sub
  check "a submodule fails" fails run tree
  says "it names it" "Vendor/sub is a submodule"
  # A clone inside the tree: git lists it as a folder once its HEAD resolves.
  fresh; mkdir -p "$case/Vendor/clone"; git -C "$case/Vendor/clone" init -q; : >"$case/Vendor/clone/file.txt"
  git -C "$case/Vendor/clone" add file.txt; git -C "$case/Vendor/clone" -c commit.gpgsign=false commit -q -m clone
  check "a nested repository fails" fails run tree
  says "it names it" "Vendor/clone/ is a nested git repository"
  # A repository without commits: older gits list its files instead of the folder.
  fresh; mkdir -p "$case/Vendor/nested"; git -C "$case/Vendor/nested" init -q; : >"$case/Vendor/nested/file.txt"
  check "a nested repository without commits fails" fails run tree
  says "it names it" "Vendor/nested/ is a nested git repository"
  fresh; rm "${case:?}/API.txt"
  check "a missing required file fails" fails run tree
  says "it names it" "API.txt is missing from what a commit takes"
  fresh; rm "${case:?}/LICENSE"
  check "a missing license fails" fails run tree
  says "it names it" "LICENSE is missing from what a commit takes"
  fresh; printf 'CHANGELOG.md\nxcshareddata/\n' >>"$case/.gitignore"
  check "required files that .gitignore hides fail" fails run tree
  says "it names the changelog" "CHANGELOG.md is missing from what a commit takes"
  says "  ... and the shared scheme" "xcschemes/SallaPushExample.xcscheme is missing from what a commit takes"
  fresh; rm "${case:?}/${SDK_GOLDEN_DIR:?}/c3-ios.json"
  check "a missing golden payload fails the tree too" fails run tree
  says "it names it" "$SDK_GOLDEN_DIR/c3-ios.json is missing from what a commit takes"
  fresh; chmod -x "$case/scripts/release-plan.sh"
  check "a script that lost its executable bit fails" fails run tree
  says "it names it" "scripts/release-plan.sh is not executable"
  fresh; g add scripts/api-compat.sh; g update-index --chmod=-x scripts/api-compat.sh
  check "a script staged without the executable mode fails" fails run tree
  says "it names it" "scripts/api-compat.sh is staged with mode 100644"
  fresh
  # shellcheck disable=SC2016 # the script's text, $(...) included, is written as it is
  printf 'cd "$(dirname "$0")/%s/%s/contracts"\n' "$up" "$up" >"$case/scripts/escape.sh"
  check "a script path that leaves the repository fails" fails run tree
  says "it names the reference" "scripts/escape.sh:1: )/$up/$up/contracts resolves outside the repository"
  fresh
  # shellcheck disable=SC2016 # the script's text, $(...) included, is written as it is
  printf 'cd "$(dirname "$0")/%s/Tests"\n' "$up" >"$case/scripts/escape.sh"
  check "a script path inside the repository passes" ok run tree
  fresh; edit Examples/SallaPushExample/SallaPushExample.xcodeproj/project.pbxproj "relativePath = $up/$up;" \
    "relativePath = $up/$up/$up/outside/ios;"
  check "a project path that leaves the repository fails" fails run tree
  says "it names it" "$up/$up/$up/outside/ios resolves outside the repository"
  fresh; edit .github/workflows/ci.yml "run: scripts/self-test.sh" "run: $up/tools/self-test.sh"
  check "a workflow step that reaches outside the workspace fails" fails run tree
  says "it names it" "$up/tools/self-test.sh resolves outside the repository"
  checkout_pin="$(grep -m 1 -oE 'actions/checkout@[0-9a-f]{40}' "$pristine/.github/workflows/ci.yml")"
  fresh; edit .github/workflows/ci.yml "$checkout_pin" "actions/checkout@v7"
  check "an action pinned to a tag fails" fails run tree
  says "it says what to do" "uses actions/checkout@v7; pin the action to a full commit id"
  fresh; edit .github/workflows/ci.yml "$checkout_pin" "an-org/.CI/testing-ready@master"
  check "an organization's shared action on a branch fails too" fails run tree
  says "it says what to do" "uses an-org/.CI/testing-ready@master; pin the action to a full commit id"
  fresh
  cat >"$case/.github/workflows/target.yml" <<EOF
name: Target
on:
  pull_request_target:
permissions:
  contents: read
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - uses: $checkout_pin # v7.0.1
EOF
  check "a pull_request_target workflow that checks out code fails" fails run tree
  says "it says why" "a pull_request_target workflow checks out code"
  # The secrets are assembled at run time, so that this file never holds one.
  fresh; printf '%s%s\nb3BlbnNzaA==\n' '-----BEGIN OPENSSH ' 'PRIVATE KEY-----' >"$case/Sources/raw-key.txt"
  check "a private key in any file fails" fails run tree
  says "it names the file" "Sources/raw-key.txt: holds a private key"
  fresh; printf 'let token = "%s%s"\n' 'ghp_' 'abcdefghijklmnopqrstuvwxyz0123456789' >"$case/Tests/Token.swift"
  check "a GitHub token in any file fails" fails run tree
  says "it names the file" "Tests/Token.swift: holds a GitHub token"
  # check writes to $out, so the output is read from a copy.
  cp "$out" "$work/token.out"
  check "  ... and never prints the token" fails grep -q 'abcdefghijklmnopqrstuvwxyz0123456789' "$work/token.out"

  fresh
  check "a fresh copy passes again" ok run version goldens catalogue links tree
}

test_release_plan
test_api_compat
test_release_notes
test_verify_portable

printf '\nself-test: %d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
