#!/usr/bin/env bash
# Prints the release notes of a version: the body of its '## [<version>]' entry in CHANGELOG.md, from the line after
# the heading to the line before the next '## ' heading, without the blank lines around it. The release workflow
# (.github/workflows/release.yml, job "GitHub Release") passes them to `gh release create --notes-file`.
#
#   scripts/release-notes.sh <version>
#
# Fails unless the version is a release version and CHANGELOG.md has exactly one '## [<version>]' entry, which says
# something.
#
# Environment:
#   RELEASE_NOTES_LINK_BASE  when set, such as https://github.com/<owner>/<repo>/blob/<tag>/, every relative Markdown
#                            link of the notes points there, so that it also works on the release page; absolute links,
#                            anchors and links from the root stay as they are
set -euo pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$scripts/.." && pwd -P)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=common.sh
. "$scripts/common.sh"

[ "$#" -eq 1 ] || {
  echo 'usage: scripts/release-notes.sh <X.Y.Z[-(alpha|beta|rc).N]>' >&2
  exit 2
}
version="$1"
sdk_check_version_grammar "$version" || exit 1
sdk_changelog_heading "$root" "$version" >/dev/null || exit 1

# The entry's body; a fixed-string prefix match, as for the heading, so the version's dots are not wildcards. The
# command substitution drops the trailing blank lines, and sed the leading ones.
notes="$(tr -d '\r' <"$root/$SDK_CHANGELOG" | awk -v heading="## [$version]" '
  index($0, heading) == 1 { inside = 1; next }
  inside && /^## / { exit }
  inside { print }
' | sed -e '/[^[:space:]]/,$!d')"
[ -n "$notes" ] || {
  echo "release-notes.sh: the '## [$version]' entry of $SDK_CHANGELOG says nothing" >&2
  exit 1
}
if [ -n "${RELEASE_NOTES_LINK_BASE:-}" ]; then
  notes="$(printf '%s\n' "$notes" | python3 -c '
import re, sys
base = sys.argv[1]
relative = re.compile(r"(\]\()(?![A-Za-z][A-Za-z0-9+.-]*:|#|/)([^)\s]+)(\))")
sys.stdout.write(relative.sub(lambda match: match.group(1) + base + match.group(2) + match.group(3), sys.stdin.read()))
' "$RELEASE_NOTES_LINK_BASE")"
fi
printf '%s\n' "$notes"
