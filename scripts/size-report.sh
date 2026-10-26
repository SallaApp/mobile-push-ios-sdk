#!/usr/bin/env bash
# What SallaPush adds to an app. Archives the
# example app and SizeBaseline, the same app without SallaPush, in Release for generic/platform=iOS without signing:
# an archive strips its executables exactly as App Store builds ship them. Then it compares the two arm64 executables,
# adds the SDK's resource bundle, prints the exact result, and fails when SallaPush adds more than the budget.
#
# Only SallaPush may differ between the two archives. The Objective-C smoke files (ObjCSmoke.m, ExtensionObjCSmoke.m)
# only prove at compile time that every selector can be called, and nothing references them, so both archives leave
# them out. The script fails when a linker map shows otherwise.
#
# It also prints a download-size estimate and the SDK's code and data per module, read from the linker map, in the
# app and in the Notification Service Extension.
#
#   scripts/size-report.sh                 run from anywhere; builds into .build/size-report (git ignores it)
#
# Environment:
#   SIZE_REPORT_DERIVED_DATA   the DerivedData folder (default: .build/size-report in the repository)
#   SIZE_REPORT_BUDGET_BYTES   the budget in bytes (default: 5242880, the 5 MB ceiling; scripts/verify.sh always
#                              gates at that number)
set -euo pipefail

ios="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
project="$ios/Examples/SallaPushExample/SallaPushExample.xcodeproj"
derived="${SIZE_REPORT_DERIVED_DATA:-$ios/.build/size-report}"
budget="${SIZE_REPORT_BUDGET_BYTES:-5242880}"

fail() {
  printf 'size-report: %s\n' "$*" >&2
  exit 1
}

case "$budget" in
  '' | *[!0-9]*) fail "SIZE_REPORT_BUDGET_BYTES must be a whole number of bytes, got '$budget'" ;;
esac
[ "$(uname -s)" = Darwin ] || fail "needs macOS with Xcode"
command -v xcodebuild >/dev/null 2>&1 || fail "xcodebuild not found; install Xcode"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"
[ -d "$project" ] || fail "$project does not exist"

work="$(mktemp -d "${TMPDIR:-/tmp}/size-report.XXXXXX")"
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT TERM

archive() {
  local scheme="$1" log="$work/$1.log"
  echo "Archiving $scheme (Release, generic/platform=iOS, unsigned, without the Objective-C smoke files)..."
  if ! xcodebuild archive -project "$project" -scheme "$scheme" -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived" -archivePath "$work/$scheme.xcarchive" \
    CODE_SIGNING_ALLOWED=NO LD_GENERATE_MAP_FILE=YES \
    EXCLUDED_SOURCE_FILE_NAMES="ObjCSmoke.m ExtensionObjCSmoke.m" >"$log" 2>&1; then
    tail -n 60 "$log" >&2
    fail "archiving $scheme failed (the last 60 lines of its log are above)"
  fi
}

# The newest linker map of a target in the archive intermediates (the folder layout differs between Xcode versions).
link_map() {
  local best="" candidate
  while IFS= read -r -d '' candidate; do
    if [ -z "$best" ] || [ "$candidate" -nt "$best" ]; then
      best="$candidate"
    fi
  done < <(find "$derived/Build/Intermediates.noindex" -type f -name "$1-LinkMap-normal-arm64.txt" \
    -path '*ArchiveIntermediates*' -print0)
  printf '%s\n' "$best"
}

archive SizeBaseline
archive SallaPushExample

app="$work/SallaPushExample.xcarchive/Products/Applications/SallaPushExample.app"
nse="$app/PlugIns/SallaPushExampleNSE.appex"
baseline="$work/SizeBaseline.xcarchive/Products/Applications/SizeBaseline.app"
app_map="$(link_map SallaPushExample)"
nse_map="$(link_map SallaPushExampleNSE)"
base_map="$(link_map SizeBaseline)"
[ -n "$app_map" ] || fail "no linker map of SallaPushExample under $derived"
[ -n "$nse_map" ] || fail "no linker map of SallaPushExampleNSE under $derived"
[ -n "$base_map" ] || fail "no linker map of SizeBaseline under $derived"
for binary in "$app/SallaPushExample" "$nse/SallaPushExampleNSE" "$baseline/SizeBaseline"; do
  [ -f "$binary" ] || fail "the archive does not contain $binary"
  [ "$(xcrun lipo -archs "$binary")" = arm64 ] || fail "$binary is not an arm64-only executable"
done

xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed -e 's/Build version/build/' -e 's/ *$//')"

python3 - "$budget" "$xcode_version" "$app" "$nse" "$baseline" "$app_map" "$nse_map" "$base_map" <<'PY'
import os
import re
import sys
import zlib

budget, xcode, app, nse, baseline, app_map, nse_map, base_map = sys.argv[1:9]
budget = int(budget)
modules = ("SallaPush", "SallaPushCore", "SallaPushExtension")
# Example code the archives must leave out, so that the delta is SallaPush's.
left_out = {app_map: ("ObjCSmoke.o",), nse_map: ("ExtensionObjCSmoke.o",)}


def object_names(link_map):
    """The file names of the object files a linker map lists."""
    names, listing = set(), False
    with open(link_map, errors="replace") as handle:
        for line in handle:
            if line.startswith("# Object files:"):
                listing = True
            elif line.startswith("# "):
                listing = False
            elif listing:
                match = re.match(r"\[\s*\d+\]\s+(.*)$", line.rstrip("\n"))
                if match:
                    names.add(os.path.basename(match.group(1)))
    return names


problems = []
for link_map, names in left_out.items():
    for name in names:
        if name in object_names(link_map):
            problems.append(f"{os.path.basename(link_map)} links {name}: the archive must leave the Objective-C smoke "
                            f"files out (EXCLUDED_SOURCE_FILE_NAMES), or the delta counts them as SallaPush")
if problems:
    for message in problems:
        print(f"size-report: {message}", file=sys.stderr)
    sys.exit(1)


def deflated(path):
    with open(path, "rb") as handle:
        return len(zlib.compress(handle.read(), 9))


def tree_size(path):
    total = 0
    for folder, _, files in os.walk(path):
        for name in files:
            total += os.path.getsize(os.path.join(folder, name))
    return total


def module_of(object_path):
    """The SDK module an object file of the linker map belongs to, or None."""
    for module in modules:
        if (object_path.endswith("/" + module + ".o")
                or "/" + module + ".build/" in object_path
                or re.search(r"/lib" + module + r"\.a\(", object_path)):
            return module
    return None


def sdk_bytes(link_map):
    """Bytes of code and data per SDK module: the symbols the linker kept, by the object file they came from."""
    objects, totals, section = {}, {}, None
    with open(link_map, errors="replace") as handle:
        for line in handle:
            if line.startswith("# Object files:"):
                section = "objects"
            elif line.startswith("# Sections:"):
                section = "sections"
            elif line.startswith("# Symbols:"):
                section = "symbols"
            elif line.startswith("# Dead Stripped Symbols:"):
                section = "dead"
            elif section == "objects":
                match = re.match(r"\[\s*(\d+)\]\s+(.*)$", line.rstrip("\n"))
                if match:
                    objects[int(match.group(1))] = match.group(2)
            elif section == "symbols":
                match = re.match(r"0x[0-9A-Fa-f]+\s+0x([0-9A-Fa-f]+)\s+\[\s*(\d+)\]", line)
                if match:
                    module = module_of(objects.get(int(match.group(2)), ""))
                    if module:
                        totals[module] = totals.get(module, 0) + int(match.group(1), 16)
    return totals


def show(label, value, note=""):
    print(f"    {label:<44}{value:>12,} bytes{('  ' + note) if note else ''}")


def readable(value):
    """The size in KiB, or in MiB from 1 MiB on."""
    if value >= 1024 * 1024:
        return f"({value / (1024 * 1024):,.2f} MiB)"
    return f"({value / 1024:,.1f} KiB)"


app_binary = os.path.join(app, "SallaPushExample")
base_binary = os.path.join(baseline, "SizeBaseline")
nse_binary = os.path.join(nse, "SallaPushExampleNSE")
executable_delta = os.path.getsize(app_binary) - os.path.getsize(base_binary)
bundles = {name: tree_size(os.path.join(app, name)) for name in sorted(os.listdir(app)) if name.endswith(".bundle")}
added = executable_delta + sum(bundles.values())
download_delta = deflated(app_binary) - deflated(base_binary)
in_app = sdk_bytes(app_map)
in_nse = sdk_bytes(nse_map)

print()
print(f"SallaPush size report: Release archive, arm64, generic/platform=iOS, {xcode}")
print("  Both archives leave out the Objective-C smoke files.")
print()
print("  App executable, as the archive (and the App Store) ships it")
show("SizeBaseline (the app without SallaPush)", os.path.getsize(base_binary))
show("SallaPushExample (the app with SallaPush)", os.path.getsize(app_binary))
show("Added by SallaPush", executable_delta, readable(executable_delta))
print("  Resource bundles added to the app (privacy manifest)")
for name, value in bundles.items():
    show(name, value)
print("  Download estimate of the added executable bytes (deflate, level 9)")
show("Added by SallaPush", download_delta, readable(download_delta))
print("  SallaPush code and data in the app, from the linker map")
for module in modules:
    if module in in_app:
        show(module, in_app[module])
show("Total", sum(in_app.values()), readable(sum(in_app.values())))
print("  Notification Service Extension")
for module in modules:
    if module in in_nse:
        show(module + " (linker map)", in_nse[module])
show("Total (linker map)", sum(in_nse.values()), readable(sum(in_nse.values())))
show("Extension executable, as archived", os.path.getsize(nse_binary))
print()
if not in_app:
    print("size-report: the linker map names no SallaPush object file, so the attribution above is incomplete.")
    sys.exit(1)
within = added <= budget
print(f"{'PASS' if within else 'FAIL'}: SallaPush adds {added:,} bytes {readable(added)} to the app "
      f"(executable and resource bundles), {'within' if within else 'over'} the budget of {budget:,} bytes "
      f"{readable(budget)}.")
sys.exit(0 if within else 1)
PY
