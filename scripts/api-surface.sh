#!/usr/bin/env bash
# The public API of SallaPushCore, SallaPush and SallaPushExtension as sorted lines:
# `<module> | <kind> | <path> | <declaration>`, from the symbol graphs of an iOS Simulator build (the UIKit-typed
# `initialize` exists only there).
#
#   scripts/api-surface.sh           rewrites API.txt
#   scripts/api-surface.sh --check   fails when the API differs from API.txt
set -euo pipefail

mode="${1:-write}"
case "$mode" in
  write | --check) ;;
  *)
    echo "usage: scripts/api-surface.sh [--check]" >&2
    exit 64
    ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="$root/.build/api-surface"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"

current="$(mktemp)"
log="$(mktemp)"
trap 'rm -f "$current" "$log"' EXIT

rm -rf "$scratch"/*/symbolgraph
status=0
swift package --package-path "$root" --scratch-path "$scratch" \
  --triple arm64-apple-ios15.0-simulator --sdk "$sdk" \
  dump-symbol-graph --minimum-access-level public --skip-synthesized-members >"$log" 2>&1 || status=$?

graphs="$(find "$scratch" -type d -name symbolgraph -print -quit)"
for module in SallaPushCore SallaPush SallaPushExtension; do
  if [ -z "$graphs" ] || [ ! -f "$graphs/$module.symbols.json" ]; then
    cat "$log" >&2
    echo "api-surface: no symbol graph for $module" >&2
    exit 1
  fi
done
# SwiftPM also extracts the synthesized SallaPushPackageTests module, which a cross-compiled build never produces.
# Any other failure is fatal.
if [ "$status" -ne 0 ] && grep "Failed to emit symbol graph for '" "$log" | grep -qv "'SallaPushPackageTests'"; then
  cat "$log" >&2
  exit 1
fi

python3 - "$graphs" >"$current" <<'PY'
import glob
import json
import os
import re
import sys

modules = {"SallaPushCore", "SallaPush", "SallaPushExtension"}
lines = set()
for path in glob.glob(os.path.join(sys.argv[1], "*.symbols.json")):
    # `SallaPush@SallaPushCore.symbols.json` holds SallaPush's extensions of SallaPushCore types.
    if os.path.basename(path).split("@")[0].split(".")[0] not in modules:
        continue
    with open(path, encoding="utf-8") as handle:
        graph = json.load(handle)
    module = graph["module"]["name"]
    for symbol in graph["symbols"]:
        if symbol.get("accessLevel") not in ("public", "open"):
            continue
        declaration = "".join(fragment["spelling"] for fragment in symbol.get("declarationFragments", []))
        declaration = re.sub(r"\s+", " ", declaration).strip()
        lines.add(" | ".join([module, symbol["kind"]["identifier"], ".".join(symbol["pathComponents"]), declaration]))
if not lines:
    sys.exit("api-surface: no public symbols found")
sys.stdout.write("\n".join(sorted(lines)) + "\n")
PY

if [ "$mode" = "--check" ]; then
  if ! diff -u "$root/API.txt" "$current"; then
    echo "api-surface: the public API differs from API.txt; run scripts/api-surface.sh and review the change" >&2
    exit 1
  fi
  echo "api-surface: API.txt is up to date"
else
  cp "$current" "$root/API.txt"
  echo "api-surface: wrote API.txt ($(wc -l <"$root/API.txt" | tr -d ' ') symbols)"
fi
