#!/usr/bin/env bash
# Fails when the public API of <commit> breaks the public API of any <baseline-commit>. .github/workflows/release.yml
# runs it for every stable release that keeps its major version, with every earlier stable release of that major
# version as a baseline (scripts/release-plan.sh, api_baselines).
#
#   scripts/api-compat.sh <baseline-commit>... <commit>
#   scripts/api-compat.sh --public <dump> <output>     only the filter below, on one dump (python3, no Xcode)
#   scripts/api-compat.sh --breaks <report>            only the breaks of one comparison report, without the accepted
#                                                      ones (exit 1 when one is left; no Xcode)
#
# macOS with Xcode. Builds each commit of this package once, for the iOS simulator, dumps the API of every library
# module with swift-api-digester, and compares each baseline's dump with the commit's. This is what
# `swift package diagnose-api-breaking-changes` does, driven directly: that command builds for the host, where every
# UIKit-guarded API is compiled out, and it cannot read the digester's output when cross compiling for iOS.
# The digester also dumps the `package` declarations that SallaPushCore shares with the other two modules, which no app
# can use, so both dumps leave them out first (public_api): a change to them is no break, and a declaration that stops
# being public is one. A commit compared with itself is built once (a quick proof that the gate reads the package,
# before a stable release needs it).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

die() {
  printf 'api-compat.sh: %s\n' "$*" >&2
  exit 1
}

# Writes the digester's dump <dump> to <output> without what no app can use: every declaration and accessor the dump
# marks isInternal (the `package` ones; `internal` and `private` ones are never dumped), and every conformance to such
# a protocol.
#   public_api <dump> <output>
public_api() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

source, target = sys.argv[1:3]
try:
    with open(source, encoding="utf-8") as handle:
        dump = json.load(handle)
except (OSError, ValueError) as error:
    sys.exit(f"api-compat.sh: cannot read {source}: {error}")
root = dump.get("ABIRoot") if isinstance(dump, dict) else None
if not isinstance(root, dict) or root.get("kind") != "Root":
    sys.exit(f"api-compat.sh: {source} is not an API dump of swift-api-digester")
# The lists of declarations; conformances point at their protocol by usr.
LISTS = ("children", "accessors")
hidden = set()


def collect(node):
    if node.get("isInternal") and node.get("usr"):
        hidden.add(node["usr"])
    for key in LISTS:
        for child in node.get(key, []):
            collect(child)


def prune(node):
    for key in LISTS:
        if key in node:
            node[key] = [child for child in node[key] if not child.get("isInternal")]
            for child in node[key]:
                prune(child)
    if "conformances" in node:
        node["conformances"] = [item for item in node["conformances"] if item.get("usr") not in hidden]


collect(root)
prune(root)
with open(target, "w", encoding="utf-8") as handle:
    json.dump(dump, handle, indent=1)
    handle.write("\n")
PY
}

# Changes the digester reports as breaks that were made on purpose, each as its exact report line. The declaration stays
# in the Objective-C API, unchanged, and a Swift caller has another call:
# - willPresent(_:presentationOptions:) is the Objective-C form of willPresent(_:); since 1.1.0 Swift code can't call it.
readonly ACCEPTED_BREAKS="Func SallaPushNotifications.willPresent(_:presentationOptions:) has been removed"

# Prints the breaks of the digester's comparison report <report>, every line that isn't blank or a /* Section */
# header, except the accepted ones, which it names; fails when a break is left.
#   breaks_of <report>
breaks_of() {
  local reported
  reported="$(grep -vE '^[[:space:]]*($|/\*)' "$1" || true)"
  [ -n "$reported" ] || return 0
  printf '%s\n' "$reported" | grep -xF "$ACCEPTED_BREAKS" | sed 's/^/accepted, made on purpose: /' || true
  ! printf '%s\n' "$reported" | grep -vxF "$ACCEPTED_BREAKS"
}

if [ "${1:-}" = --breaks ]; then
  [ "$#" -eq 2 ] && [ -f "$2" ] || {
    echo 'usage: scripts/api-compat.sh --breaks <report>' >&2
    exit 2
  }
  breaks_of "$2"
  exit
fi

if [ "${1:-}" = --public ]; then
  [ "$#" -eq 3 ] || {
    echo 'usage: scripts/api-compat.sh --public <dump> <output>' >&2
    exit 2
  }
  public_api "$2" "$3"
  exit 0
fi

[ "$#" -ge 2 ] || {
  echo 'usage: scripts/api-compat.sh <baseline-commit>... <commit>' >&2
  exit 2
}
[ "$(uname -s)" = Darwin ] || die "the API comparison needs macOS with Xcode"
arguments=("$@")
last=$((${#arguments[@]} - 1))
current="$(git -C "$root" rev-parse --verify --quiet "${arguments[$last]}^{commit}")" ||
  die "${arguments[$last]} is not a commit"
names=()
commits=()
for name in "${arguments[@]:0:$last}"; do
  commit="$(git -C "$root" rev-parse --verify --quiet "$name^{commit}")" || die "$name is not a commit"
  names+=("$name")
  commits+=("$commit")
done

work="$(mktemp -d "${TMPDIR:-/tmp}/sallapush-api-compat.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

sdk_path="$(xcrun --sdk iphonesimulator --show-sdk-path)"
triple="$(uname -m)-apple-ios15.0-simulator"

# Exports the package at a commit into $work/<name> and builds it for the iOS simulator; prints the modules directory.
# It runs inside a command substitution, where errexit is off, so every step returns its own failure.
build_package() {
  local commit="$1" name="$2" bin
  mkdir -p "$work/$name" || return 1
  git -C "$root" archive "$commit" | tar -x -C "$work/$name" || return 1
  (cd "$work/$name" && swift build --triple "$triple" --sdk "$sdk_path" >&2) || return 1
  bin="$(cd "$work/$name" && swift build --triple "$triple" --sdk "$sdk_path" --show-bin-path)" || return 1
  printf '%s/Modules\n' "$bin"
}

current_modules="$(build_package "$current" current)" || die "could not build $current for the iOS simulator"

# Dumps the API of <module>, built into <modules>, into <output>: only what an app can use (public_api).
#   dump_public <module> <modules> <output>
dump_public() {
  xcrun swift-api-digester -dump-sdk -module "$1" -I "$2" -sdk "$sdk_path" -target "$triple" -abort-on-module-fail \
    -o "$3.all" &&
    public_api "$3.all" "$3"
}

breaking=()
for index in "${!commits[@]}"; do
  name="${names[$index]}"
  baseline="${commits[$index]}"
  echo "== the public API of $name ($baseline)"
  if [ "$baseline" = "$current" ]; then
    tree="$work/current"
    base_modules="$current_modules"
  else
    tree="$work/baseline-$index"
    base_modules="$(build_package "$baseline" "baseline-$index")" || die "could not build $name for the iOS simulator"
  fi

  (cd "$tree" && swift package dump-package) >"$work/package-$index.json"
  python3 - "$work/package-$index.json" >"$work/modules-$index" <<'PY'
import json, sys
package = json.load(open(sys.argv[1]))
for target in package["targets"]:
    if target.get("type") == "regular":
        print(target["name"])
PY
  [ -s "$work/modules-$index" ] || die "no library modules in the package at $name"

  breaks=0
  while IFS= read -r module; do
    # </dev/null: nothing in the loop may read the module list.
    dump_public "$module" "$base_modules" "$work/$module.$index.baseline.json" </dev/null ||
      die "could not dump the API of $module at $name"
    if [ ! -f "$work/$module.current.json" ] &&
      ! dump_public "$module" "$current_modules" "$work/$module.current.json" </dev/null; then
      echo "$module: the module is missing or does not load in $current"
      breaks=$((breaks + 1))
      continue
    fi
    xcrun swift-api-digester -diagnose-sdk -input-paths "$work/$module.$index.baseline.json" \
      -input-paths "$work/$module.current.json" -o "$work/$module.$index.diagnostics" </dev/null ||
      die "could not compare the API of $module with $name"
    # The report lists only breaking changes under /* Section */ headers; any other line is one, unless it is accepted.
    if breaks_of "$work/$module.$index.diagnostics" >"$work/$module.$index.breaks"; then
      sed 's/^/  /' "$work/$module.$index.breaks"
      echo "$module: no breaking changes"
    else
      echo "$module: API-breaking changes since $name:"
      sed 's/^/  /' "$work/$module.$index.breaks"
      breaks=$((breaks + 1))
    fi
  done <"$work/modules-$index"
  [ "$breaks" -eq 0 ] || breaking+=("$name ($breaks module(s))")
done

if [ "${#breaking[@]}" -ne 0 ]; then
  die "$current breaks the public API of ${breaking[*]}; a break needs a new major version"
fi
echo "api-compat.sh: $current keeps the public API of ${names[*]}"
