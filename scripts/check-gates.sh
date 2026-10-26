#!/usr/bin/env bash
# The plain-grep gates over Sources/: the crash-safety bans, the required-reason API
# grep that backs the privacy manifests' "no required-reason APIs", the Bundle.module ban, and no package
# dependencies; and over every file, no ids of design notes or review findings that aren't in this repository. Prints
# every finding and exits 1 when there is one. Needs no SwiftLint.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
findings=0

report() {
  echo "check-gates: $1" >&2
  printf '%s\n' "$2" >&2
  findings=1
}

# Swift lines under Sources/ matching an extended regex, without whole-line comments, minus one exempt file.
code_matches() {
  local pattern="$1" exempt="${2:-}"
  grep -rnE --include='*.swift' "$pattern" Sources \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' \
    | { if [ -n "$exempt" ]; then grep -vF "$exempt:"; else cat; fi; } \
    || true
}

gate() {
  local description="$1" pattern="$2" exempt="${3:-}" matches
  matches="$(code_matches "$pattern" "$exempt")"
  if [ -n "$matches" ]; then report "$description" "$matches"; fi
}

# Crash safety.
gate "traps" '\b(fatalError|precondition|preconditionFailure|assert|assertionFailure|dispatchPrecondition)[[:space:]]*\('
gate "try!" 'try!'
gate "as!" 'as!'
gate "implicitly unwrapped optionals" ':[[:space:]]*[A-Za-z_][A-Za-z0-9_.<>]*![[:space:]]*($|[=,)])'
gate "unowned" '\bunowned\b'
gate "Dictionary(uniqueKeysWithValues:)" 'Dictionary[[:space:]]*\([[:space:]]*uniqueKeysWithValues[[:space:]]*:'
gate "String(format:)" 'String[[:space:]]*\([[:space:]]*format[[:space:]]*:'
gate "UserDefaults" '\bUserDefaults\b'
gate "JSONSerialization.data(withJSONObject:)" 'JSONSerialization[[:space:]]*\.[[:space:]]*data[[:space:]]*\([[:space:]]*withJSONObject'
gate "assumeIsolated outside MainThread.run" '\bassumeIsolated\b' 'Sources/SallaPush/Platform/ApplicationClient.swift'
gate "isolation assertions" '\b(preconditionIsolated|assertIsolated)\b'
gate "DispatchQueue.main.sync" 'DispatchQueue[[:space:]]*\.[[:space:]]*main[[:space:]]*\.[[:space:]]*sync\b'
gate ".sync on a queue" '\.sync[[:space:]]*(\{|\()'
gate "dispatch timer sources" '\bmakeTimerSource\b'
gate "suspend()" '\.suspend[[:space:]]*\([[:space:]]*\)'
gate "continuations outside Util/Once.swift" '\bwith(Checked|Unsafe)(Throwing)?Continuation\b' 'Sources/SallaPushCore/Util/Once.swift'
gate "swizzling or KVO" '\b(method_exchangeImplementations|method_setImplementation|class_replaceMethod|class_addMethod|forKeyPath)\b'
gate "delegate assignment" '\.delegate[[:space:]]*=[^=]'

# Bundle.module traps when the resource bundle is missing; comments included.
matches="$(grep -rnE --include='*.swift' 'Bundle[[:space:]]*\.[[:space:]]*module\b' Sources || true)"
if [ -n "$matches" ]; then report "Bundle.module" "$matches"; fi

# Required-reason APIs (privacy manifests); comments included.
required_reason='\b(systemUptime|mach_absolute_time|CACurrentMediaTime|getattrlist|creationDate|modificationDate|contentModificationDateKey|creationDateKey|fileModificationDate|UserDefaults|volumeAvailableCapacity)|\b(stat|lstat|fstat)\('
matches="$(grep -rnE --include='*.swift' "$required_reason" Sources || true)"
if [ -n "$matches" ]; then report "required-reason APIs" "$matches"; fi

# Ids of design notes, decision records and review findings that aren't in this repository say nothing to a reader:
# every file but this one, comments included. A review finding's id starts a comment, as in "// AB12: …".
matches="$(grep -rnIE --exclude-dir=.build --exclude-dir=.git --exclude-dir=.swiftpm --exclude-dir=DerivedData \
  --exclude=check-gates.sh \
  '\bDESIGN\b|§|\bC1\.[0-9]|\bFROZEN\b|(//|#)[[:space:]]*[A-Z]{1,3}[0-9]{1,3}[a-z]?( and [A-Z]{1,3}[0-9]{1,3}[a-z]?)*:' . \
  || true)"
if [ -n "$matches" ]; then report "references to design notes or reviews outside this repository" "$matches"; fi

# No TODOs or FIXMEs anywhere in the package.
matches="$(grep -rnE --include='*.swift' '\b(TODO|FIXME)\b' Sources Tests Package.swift || true)"
if [ -n "$matches" ]; then report "TODO or FIXME" "$matches"; fi

# No package dependencies.
dependencies="$(swift package --package-path "$root" show-dependencies --format json \
  | python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("dependencies", [])))')"
if [ "$dependencies" != "0" ]; then
  report "package dependencies" "$dependencies dependencies declared; SallaPush has none"
fi

if [ "$findings" -ne 0 ]; then
  exit 1
fi
echo "check-gates: no findings"
