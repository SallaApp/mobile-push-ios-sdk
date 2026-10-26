#!/usr/bin/env bash
# Keeps README.md and the docs identical to code that compiles. Every Swift and
# Objective-C code block in README.md and in each .md file directly in docs/ follows a marker line:
#
#   <!-- snippet:<path> -->          the block equals that file of Examples/SallaPushExample, byte for byte
#   <!-- snippet:<path>#<name> -->   the block equals the region between `// snippet:<name>` and `// end-snippet` in
#                                    that file, without the region's common indentation
#   <!-- unchecked: <reason> -->     the block is not code the example can compile (a SwiftPM manifest excerpt)
#
# A Swift or Objective-C snippet counts only when its file is compiled by a target that the SallaPushExample scheme
# builds, read from the example's project.pbxproj and shared scheme; scripts/verify.sh (step example) builds that
# scheme.
#
# Inside a compiled file, only code the compiler reads counts. The check fails when a region's markers sit inside a
# conditional compilation block (Swift #if, #elseif, #else; Objective-C #if, #ifdef, #ifndef, #elif, #else), a /* */
# comment or a string literal, when a region holds a conditional compilation directive, and when a file shown in full
# holds one: a branch the build doesn't take is never compiled.
#
# The check also fails:
#   - when the README does not show the example's AppDelegate.swift and NotificationService.swift in full;
#   - when a size budget the README or a doc states ("more than ... <N> bytes") differs from the one
#     scripts/size-report.sh enforces by default;
#   - when the log code reference of docs/LOGGING.md (between the log-codes:start and log-codes:end markers) differs
#     from Sources/SallaPushCore/Logging/Logger.swift in codes or levels, or the README or a doc names elsewhere a log
#     code that Logger.swift doesn't have (a name that ends in a file extension, such as `identity.json`, is a file);
#   - when a version the README or a doc pins (a "- **Version:**" line, every line that says "exact" or "pin to", and
#     every CocoaPods `:tag =>`) differs from the version in Sources/SallaPushCore/SallaPushVersion.swift, or the README
#     names none.
#
#   scripts/check-readme-snippets.sh               run from anywhere; exits 1 on drift, with the reason per problem
#   scripts/check-readme-snippets.sh --self-test   proves, on scratch copies, that every kind of drift is caught
set -euo pipefail

ios="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
case "${1:-}" in
  '' | --self-test) ;;
  *)
    echo "usage: scripts/check-readme-snippets.sh [--self-test]" >&2
    exit 2
    ;;
esac
command -v python3 >/dev/null 2>&1 || {
  echo "check-readme-snippets: python3 not found" >&2
  exit 1
}

python3 - "$ios" "${1:-}" <<'PY'
import difflib
import os
import re
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ElementTree

EXAMPLE = os.path.join("Examples", "SallaPushExample")
PROJECT = "SallaPushExample.xcodeproj"
# The scheme scripts/verify.sh (step example) builds, and the app it must build.
SCHEME = "SallaPushExample"
APP_TARGET = "SallaPushExample"
# The README shows these two example files in full.
REQUIRED_FILES = ("SallaPushExample/AppDelegate.swift", "SallaPushExampleNSE/NotificationService.swift")
# The Markdown files the check reads: README.md, and each .md file directly in docs/ (markdown_files).
README = "README.md"
DOCS = "docs"
# The log code reference: the table between these two lines of docs/LOGGING.md lists every log code with its level.
LOG_REFERENCE = DOCS + "/LOGGING.md"
LOG_TABLE_START = "<!-- log-codes:start -->"
LOG_TABLE_END = "<!-- log-codes:end -->"
# A backticked name whose last part is one of these is a file, such as the state file `identity.json`, not a log code.
FILE_EXTENSIONS = {"json", "md", "plist", "swift", "txt"}
CODE_LANGUAGES = {"swift", "objc", "objective-c", "objectivec", "obj-c"}
REGION_FILES = (".swift", ".m", ".mm", ".h")
COMPILED_FILES = (".swift", ".m", ".mm")
SIZE_SCRIPT = os.path.join("scripts", "size-report.sh")
# A size budget the README states: "more than ... <N> bytes", within one sentence or table cell.
STATED_BUDGET = re.compile(r"\bmore than\b[^.;|]*?(\d[\d,]*) bytes")


def read_text(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def markdown_files(ios):
    """The files the check reads, as paths relative to `ios`: README.md, then each .md file directly in docs/, by
    name."""
    folder = os.path.join(ios, DOCS)
    names = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
    return [README] + [f"{DOCS}/{name}" for name in names
                       if name.endswith(".md") and os.path.isfile(os.path.join(folder, name))]


def dedent(lines):
    indents = [len(line) - len(line.lstrip(" ")) for line in lines if line.strip()]
    cut = min(indents) if indents else 0
    return [line[cut:] if line.strip() else "" for line in lines]


def as_text(lines):
    return "".join(line + "\n" for line in lines)


# --- The example project: which files the scheme compiles ------------------------------------------------------------

class ProjectError(Exception):
    pass


def parse_openstep(text):
    """Parses an old-style (OpenStep) property list, the format of project.pbxproj."""
    unquoted = re.compile(r"[A-Za-z0-9_$+/:.\-]+")
    escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'"}
    position = 0

    def skip():
        nonlocal position
        while position < len(text):
            if text[position] in " \t\r\n":
                position += 1
            elif text.startswith("//", position):
                end = text.find("\n", position)
                position = len(text) if end < 0 else end + 1
            elif text.startswith("/*", position):
                end = text.find("*/", position + 2)
                if end < 0:
                    raise ProjectError("a comment is not closed")
                position = end + 2
            else:
                return

    def expect(character):
        nonlocal position
        skip()
        if not text.startswith(character, position):
            raise ProjectError(f"expected '{character}' at offset {position}")
        position += 1

    def value():
        nonlocal position
        skip()
        if position >= len(text):
            raise ProjectError("the file ends early")
        character = text[position]
        if character == "{":
            position += 1
            result = {}
            while True:
                skip()
                if text.startswith("}", position):
                    position += 1
                    return result
                key = value()
                if not isinstance(key, str):
                    raise ProjectError(f"a dictionary key is not a string at offset {position}")
                expect("=")
                result[key] = value()
                expect(";")
        if character == "(":
            position += 1
            result = []
            while True:
                skip()
                if text.startswith(")", position):
                    position += 1
                    return result
                result.append(value())
                skip()
                if text.startswith(",", position):
                    position += 1
                elif not text.startswith(")", position):
                    raise ProjectError(f"expected ',' or ')' at offset {position}")
        if character == '"':
            position += 1
            pieces = []
            while position < len(text) and text[position] != '"':
                if text[position] == "\\" and position + 1 < len(text):
                    following = text[position + 1]
                    if following == "U" and re.match(r"[0-9A-Fa-f]{4}", text[position + 2:position + 6]):
                        pieces.append(chr(int(text[position + 2:position + 6], 16)))
                        position += 6
                        continue
                    pieces.append(escapes.get(following, following))
                    position += 2
                    continue
                pieces.append(text[position])
                position += 1
            if position >= len(text):
                raise ProjectError("a string is not closed")
            position += 1
            return "".join(pieces)
        match = unquoted.match(text, position)
        if not match:
            raise ProjectError(f"unexpected {character!r} at offset {position}")
        position = match.end()
        return match.group(0)

    root = value()
    skip()
    if position != len(text):
        raise ProjectError(f"unexpected text at offset {position}")
    if not isinstance(root, dict) or not isinstance(root.get("objects"), dict):
        raise ProjectError("it has no objects")
    return root


def object_paths(objects, main_group):
    """The path, relative to the project's folder, of every group and file reference reachable from the main group."""
    paths = {}

    def visit(object_id, parent_path):
        item = objects.get(object_id)
        if not isinstance(item, dict) or object_id in paths:
            return
        tree, own = item.get("sourceTree", "<group>"), item.get("path", "")
        if tree == "<group>":
            path = os.path.normpath(os.path.join(parent_path, own)) if own else parent_path
        elif tree == "SOURCE_ROOT":
            path = os.path.normpath(own) if own else ""
        else:
            return
        paths[object_id] = path
        for child in item.get("children", []):
            visit(child, path)

    visit(main_group, "")
    return paths


def compiled_sources(example):
    """{path in the example: [target names]} for every Swift or Objective-C file the scheme's targets compile."""
    project = os.path.join(example, PROJECT)
    try:
        root = parse_openstep(read_text(os.path.join(project, "project.pbxproj")))
    except (OSError, UnicodeDecodeError, ProjectError) as error:
        raise ProjectError(f"could not read {PROJECT}/project.pbxproj: {error}")
    objects = root["objects"]
    project_object = objects.get(root.get("rootObject"), {})
    paths = object_paths(objects, project_object.get("mainGroup"))
    scheme_path = os.path.join(project, "xcshareddata", "xcschemes", SCHEME + ".xcscheme")
    try:
        scheme = ElementTree.parse(scheme_path).getroot()
    except (OSError, ElementTree.ParseError) as error:
        raise ProjectError(f"could not read the shared scheme {SCHEME}: {error}")
    pending = []
    for entry in scheme.iter("BuildActionEntry"):
        if entry.get("buildForRunning") != "YES":
            continue
        for reference in entry.iter("BuildableReference"):
            if reference.get("ReferencedContainer") == f"container:{PROJECT}":
                pending.append(reference.get("BlueprintIdentifier"))
    # The scheme builds implicit dependencies too.
    targets = []
    while pending:
        target_id = pending.pop()
        target = objects.get(target_id)
        if not isinstance(target, dict) or target_id in targets:
            continue
        targets.append(target_id)
        for dependency_id in target.get("dependencies", []):
            dependency = objects.get(dependency_id, {})
            if isinstance(dependency, dict) and dependency.get("target"):
                pending.append(dependency["target"])
    compiled = {}

    def add(path, target_name):
        if path.endswith(COMPILED_FILES):
            compiled.setdefault(path, set()).add(target_name)

    for target_id in targets:
        target = objects[target_id]
        name = target.get("name", target_id)
        phases = {phase_id: objects.get(phase_id, {}) for phase_id in target.get("buildPhases", [])}
        for group_id in target.get("fileSystemSynchronizedGroups", []):
            group = objects.get(group_id, {})
            folder = paths.get(group_id)
            if folder is None:
                continue
            excluded, filters = set(), {}
            for exception_id in group.get("exceptions", []):
                exception = objects.get(exception_id, {})
                kind = exception.get("isa")
                if kind == "PBXFileSystemSynchronizedBuildFileExceptionSet" and exception.get("target") == target_id:
                    excluded.update(exception.get("membershipExceptions", []))
                    filters.update(exception.get("platformFiltersByRelativePath", {}))
                elif (kind == "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet"
                      and exception.get("buildPhase") in phases
                      and phases[exception["buildPhase"]].get("isa") != "PBXSourcesBuildPhase"):
                    excluded.update(exception.get("membershipExceptions", []))
            base = os.path.join(example, folder)
            for directory, folders, files in os.walk(base):
                folders[:] = sorted(entry for entry in folders if not entry.startswith("."))
                for file_name in sorted(files):
                    if file_name.startswith("."):
                        continue
                    inside = os.path.relpath(os.path.join(directory, file_name), base)
                    if any(inside == item or inside.startswith(item + "/") for item in excluded):
                        continue
                    if inside in filters and "ios" not in filters[inside]:
                        continue
                    add(os.path.normpath(os.path.join(folder, inside)), name)
        # A folder the target doesn't own lends it the files that an exception set naming the target lists.
        owned = set(target.get("fileSystemSynchronizedGroups", []))
        for group_id, group in objects.items():
            if (not isinstance(group, dict) or group.get("isa") != "PBXFileSystemSynchronizedRootGroup"
                    or group_id in owned or paths.get(group_id) is None):
                continue
            for exception_id in group.get("exceptions", []):
                exception = objects.get(exception_id, {})
                if (exception.get("isa") == "PBXFileSystemSynchronizedBuildFileExceptionSet"
                        and exception.get("target") == target_id):
                    for inside in exception.get("membershipExceptions", []):
                        if os.path.isfile(os.path.join(example, paths[group_id], inside)):
                            add(os.path.normpath(os.path.join(paths[group_id], inside)), name)
        for phase in phases.values():
            if phase.get("isa") != "PBXSourcesBuildPhase":
                continue
            for build_file_id in phase.get("files", []):
                reference_id = objects.get(build_file_id, {}).get("fileRef")
                if reference_id in paths:
                    add(paths[reference_id], name)
    names = sorted({objects[target_id].get("name", target_id) for target_id in targets})
    return {path: sorted(owners) for path, owners in compiled.items()}, names, objects


# --- What the compiler reads as code: conditional compilation, comments and strings ----------------------------------

SWIFT_DIRECTIVE = re.compile(r"#(if|elseif|else|endif)\b")
C_DIRECTIVE = re.compile(r"#[ \t]*(if|ifdef|ifndef|elif|elifdef|elifndef|else|endif)\b")
OPENING_DIRECTIVES = {"if", "ifdef", "ifndef"}
SWIFT_RAW_STRING = re.compile(r'(#+)("""|")')
SWIFT_EXTENDED_REGEX = re.compile(r"(#+)/")
CPP_RAW_STRING = re.compile(r'(?<![A-Za-z0-9_])(?:u8|u|U|L)?R"([^()\\ \t\n]{0,16})\(')


class SourceLine:
    """How the compiler reads the start of a source line."""
    __slots__ = ("context", "conditionals", "directive")

    def __init__(self, context, conditionals):
        # "code", or what the line starts inside: "block comment", "line comment" or "string literal".
        self.context = context
        # The open conditional compilation blocks, outermost first: (the line that opens it, its directive).
        self.conditionals = conditionals
        # The conditional compilation directive of the line, such as "if" or "endif", if it has one.
        self.directive = None


def language_of(path):
    return "swift" if path.endswith(".swift") else "objc++" if path.endswith(".mm") else "objc"


def source_lines(text, language, code=None):
    """A SourceLine per line of `text` (split on "\\n"), from a lexer for Swift (nested /* */ comments, raw and
    multi-line strings with interpolation, #/regex/# literals) or Objective-C (/* */ comments, backslash-newline
    splices, string and character literals, and C++ raw strings in .mm files). A conditional compilation directive is
    the first token of its line. Bare /regex/ literals are not recognised: telling one from a division takes a parser,
    and the example's snippets have none.

    With a list as `code`, the lexer also appends to it the text as the compiler reads it: comments, and the contents
    and delimiters of literals, become spaces, while an interpolation's code stays. Newlines stay, so offsets and line
    numbers match `text`."""
    swift = language == "swift"
    lines, conditionals = [], []
    # Innermost last: ["code", open parentheses, is an interpolation], ["line"], ["block", nesting], ["string",
    # raw string hashes, is multi-line], ["regex", hashes], ["char"] or ["raw", delimiter].
    stack = [["code", 0, False]]
    contexts = {"code": "code", "line": "line comment", "block": "block comment"}
    position, length = 0, len(text)
    first_token = True

    def start_line():
        lines.append(SourceLine(contexts.get(stack[-1][0], "string literal"), tuple(conditionals)))

    def skip_escape(at):
        # A backslash and the character it escapes; a backslash before a newline leaves the newline to the main loop.
        return at + 2 if at + 1 < length and text[at + 1] != "\n" else at + 1

    start_line()
    while position < length:
        character, top = text[position], stack[-1]
        kind = top[0]
        consumed_from, frames = position, len(stack)
        if character == "\n":
            # Objective-C splices a line that ends in a backslash onto the next; Swift never does.
            spliced = not swift and position > 0 and text[position - 1] == "\\"
            if kind in ("line", "char") and not spliced:
                stack.pop()
            elif kind == "string" and not top[2] and not spliced:
                stack.pop()
            position += 1
            first_token = True
            start_line()
        elif kind == "line":
            position += 1
        elif kind == "block":
            if text.startswith("*/", position):
                top[1] -= 1
                position += 2
                if top[1] == 0:
                    stack.pop()
            elif swift and text.startswith("/*", position):
                top[1] += 1
                position += 2
            else:
                position += 1
        elif kind == "string":
            hashes, multiline = top[1], top[2]
            if character == "\\":
                if swift and text.startswith("#" * hashes + "(", position + 1):
                    stack.append(["code", 1, True])
                    position += 2 + hashes
                elif swift and hashes and not text.startswith("#" * hashes, position + 1):
                    position += 1
                else:
                    position = skip_escape(position + hashes)
            elif character == '"' and text.startswith(('"""' if multiline else '"') + "#" * hashes, position):
                stack.pop()
                position += (3 if multiline else 1) + hashes
                first_token = False
            else:
                position += 1
        elif kind == "char":
            if character == "\\":
                position = skip_escape(position)
            else:
                if character == "'":
                    stack.pop()
                    first_token = False
                position += 1
        elif kind == "regex":
            if character == "\\":
                position = skip_escape(position)
            elif text.startswith("/" + "#" * top[1], position):
                stack.pop()
                position += 1 + top[1]
                first_token = False
            else:
                position += 1
        elif kind == "raw":
            closing = ")" + top[1] + '"'
            if text.startswith(closing, position):
                stack.pop()
                position += len(closing)
                first_token = False
            else:
                position += 1
        elif character in " \t\f\v\ufeff":
            position += 1
        elif text.startswith("//", position):
            stack.append(["line"])
            position += 2
        elif text.startswith("/*", position):
            stack.append(["block", 1])
            position += 2
        else:
            directive = None
            if character == "#" and first_token and not top[2]:
                directive = (SWIFT_DIRECTIVE if swift else C_DIRECTIVE).match(text, position)
            first_token = False
            if directive:
                keyword = directive.group(1)
                lines[-1].directive = keyword
                if keyword in OPENING_DIRECTIVES:
                    conditionals.append((len(lines), keyword))
                elif keyword == "endif" and conditionals:
                    conditionals.pop()
                position = directive.end()
            elif swift:
                raw = SWIFT_RAW_STRING.match(text, position) if character == "#" else None
                regex = SWIFT_EXTENDED_REGEX.match(text, position) if character == "#" and not raw else None
                if raw:
                    stack.append(["string", len(raw.group(1)), raw.group(2) == '"""'])
                    position = raw.end()
                elif regex:
                    stack.append(["regex", len(regex.group(1))])
                    position = regex.end()
                elif text.startswith('"""', position):
                    stack.append(["string", 0, True])
                    position += 3
                elif character == '"':
                    stack.append(["string", 0, False])
                    position += 1
                else:
                    if character == "(":
                        top[1] += 1
                    elif character == ")":
                        top[1] -= 1
                        if top[2] and top[1] == 0:
                            stack.pop()
                    position += 1
            else:
                raw = CPP_RAW_STRING.match(text, position) if language == "objc++" and character in "uULR" else None
                if raw:
                    stack.append(["raw", raw.group(1)])
                    position = raw.end()
                elif character == '"':
                    stack.append(["string", 0, False])
                    position += 1
                elif character == "'":
                    stack.append(["char"])
                    position += 1
                else:
                    position += 1
        if code is not None:
            # Code is what was consumed in a code frame that is still the innermost: opening or closing a comment,
            # a literal or an interpolation is not.
            consumed = text[consumed_from:position]
            is_code = kind == "code" and len(stack) == frames and stack[-1] is top
            code.append(consumed if is_code else re.sub(r"[^\n]", " ", consumed))
    return lines


def misplaced(line):
    """Why code that starts on `line` is never compiled, or None when the compiler reads it as code."""
    if line.context == "block comment":
        return "inside a /* */ comment, so its code is never compiled"
    if line.context == "line comment":
        return "inside a // comment that a backslash continues, so its code is never compiled"
    if line.context == "string literal":
        return "inside a string literal, so its code is never compiled"
    if line.conditionals:
        opened, keyword = line.conditionals[-1]
        return (f"inside the #{keyword} block of line {opened}; a branch the build doesn't take is never compiled, "
                f"so keep README regions out of conditional compilation")
    return None


# --- The checks ----------------------------------------------------------------------------------------------------

def check(ios):
    """Returns the problems found and the counts for the summary."""
    example = os.path.join(ios, EXAMPLE)
    problems = []
    problem = problems.append
    counts = {"files": 0, "regions": 0, "unchecked": 0}

    try:
        compiled, scheme_targets, objects = compiled_sources(example)
    except ProjectError as error:
        problem(str(error))
        compiled, scheme_targets, objects = {}, [], {}
    if objects and APP_TARGET not in scheme_targets:
        problem(f"the {SCHEME} scheme does not build the {APP_TARGET} target")

    # Regions in the example's sources, each in code the compiler reads.
    start_marker = re.compile(r"^\s*//\s*snippet:([A-Za-z0-9_-]+)\s*$")
    end_marker = re.compile(r"^\s*//\s*end-snippet\s*$")
    regions, layouts = {}, {}
    for folder, folders, files in os.walk(example):
        folders[:] = sorted(name for name in folders if not name.endswith((".xcodeproj", ".xcworkspace")))
        for name in sorted(files):
            if not name.endswith(REGION_FILES):
                continue
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, example)
            text = read_text(path)
            layout = layouts[relative] = source_lines(text, language_of(name))
            current, body, start_reason = None, [], None
            for number, line in enumerate(text.split("\n"), 1):
                start, end = start_marker.match(line), end_marker.match(line)
                if start:
                    if current:
                        problem(f"{relative}:{number}: region '{start.group(1)}' starts inside region '{current}'")
                    current, body = start.group(1), []
                    if (relative, current) in regions:
                        problem(f"{relative}:{number}: region '{current}' is defined twice")
                    start_reason = misplaced(layout[number - 1])
                    if start_reason:
                        problem(f"{relative}:{number}: region '{current}' starts {start_reason}")
                elif end:
                    if not current:
                        problem(f"{relative}:{number}: end-snippet without a region")
                    else:
                        regions[(relative, current)] = as_text(dedent(body))
                        reason = misplaced(layout[number - 1])
                        if reason and reason != start_reason:
                            problem(f"{relative}:{number}: region '{current}' ends {reason}")
                        current = None
                elif current:
                    body.append(line)
                    if layout[number - 1].directive:
                        problem(f"{relative}:{number}: region '{current}' holds #{layout[number - 1].directive}; a "
                                f"branch the build doesn't take is never compiled, so keep README regions out of "
                                f"conditional compilation")
            if current:
                problem(f"{relative}: region '{current}' has no end-snippet")

    # Code blocks of the README and the docs.
    marker = re.compile(r"^\s*<!--\s*(snippet|unchecked):\s*(.*?)\s*-->\s*$")
    fence_open = re.compile(r"^(\s*)(`{3,}|~{3,})\s*([^\s`]*)")
    documents = {name: read_text(os.path.join(ios, name)).split("\n") for name in markdown_files(ios)}
    shown_files, shown_regions = {name: set() for name in documents}, set()
    for name, lines in documents.items():
        index = 0
        while index < len(lines):
            opening = fence_open.match(lines[index])
            if not opening:
                found = marker.match(lines[index])
                if found and not (index + 1 < len(lines) and fence_open.match(lines[index + 1])):
                    problem(f"{name}:{index + 1}: the {found.group(1)} marker must be followed by a fenced code block")
                index += 1
                continue
            indent, fence, language = len(opening.group(1)), opening.group(2), opening.group(3).lower()
            start = index
            index += 1
            body = []
            while index < len(lines) and not (lines[index].strip().startswith(fence[0] * len(fence))
                                              and set(lines[index].strip()) == {fence[0]}):
                # A fence indented in a list item indents its content too (CommonMark strips up to that many spaces).
                line = lines[index]
                body.append(line[min(indent, len(line) - len(line.lstrip(" "))):])
                index += 1
            if index >= len(lines):
                problem(f"{name}:{start + 1}: the code block is not closed")
                break
            index += 1
            found = marker.match(lines[start - 1]) if start > 0 else None
            if not found:
                if language in CODE_LANGUAGES:
                    problem(f"{name}:{start + 1}: a {language} block needs a snippet or unchecked marker on the "
                            f"line above")
                continue
            kind, argument = found.group(1), found.group(2)
            if kind == "unchecked":
                if not argument:
                    problem(f"{name}:{start}: the unchecked marker needs a reason")
                counts["unchecked"] += 1
                continue
            path, _, region = argument.partition("#")
            if path.startswith("/") or ".." in path.split("/"):
                problem(f"{name}:{start}: snippet path {path} must stay inside {EXAMPLE}")
                continue
            source = os.path.join(example, path)
            if not os.path.isfile(source):
                problem(f"{name}:{start}: {EXAMPLE}/{path} does not exist")
                continue
            if os.path.normpath(path) not in compiled:
                problem(f"{name}:{start}: {EXAMPLE}/{path} is not compiled by the {SCHEME} scheme "
                        f"(its targets: {', '.join(scheme_targets) or 'none'}), so this block is not proven to "
                        f"compile; move the code into a file one of those targets compiles")
                continue
            shown = as_text(body)
            if region:
                expected = regions.get((path, region))
                if expected is None:
                    problem(f"{name}:{start}: {path} has no region '{region}'")
                    continue
                shown_regions.add((path, region))
                counts["regions"] += 1
                label = f"{path}#{region}"
            else:
                expected = read_text(source)
                shown_files[name].add(path)
                counts["files"] += 1
                label = path
                for number, line in enumerate(layouts.get(os.path.normpath(path), []), 1):
                    if line.directive:
                        problem(f"{name}:{start}: {EXAMPLE}/{path} holds #{line.directive} at line {number}; a "
                                f"file the docs show in full must have no conditional compilation, because a branch "
                                f"the build doesn't take is never compiled")
            if shown != expected:
                problem(f"{name}:{start + 1}: the block differs from {EXAMPLE}/{label}:\n"
                        + "".join(difflib.unified_diff(expected.splitlines(True), shown.splitlines(True),
                                                       f"{EXAMPLE}/{label}", name)))

    for path in REQUIRED_FILES:
        if path not in shown_files[README]:
            problem(f"README.md does not show {EXAMPLE}/{path} in full (<!-- snippet:{path} -->)")

    # The size budget: every "more than <N> bytes" of the README and the docs is the one scripts/size-report.sh enforces
    # by default.
    budget = None
    try:
        script = read_text(os.path.join(ios, SIZE_SCRIPT))
    except OSError:
        script = ""
    budgets = re.findall(r'^budget="\$\{SIZE_REPORT_BUDGET_BYTES:-(\d+)\}"$', script, re.MULTILINE)
    if len(budgets) != 1:
        problem(f"{SIZE_SCRIPT} must set its default budget once, as budget=\"${{SIZE_REPORT_BUDGET_BYTES:-<bytes>}}\"")
    else:
        budget = f"{int(budgets[0]):,} bytes"
        for name, lines in documents.items():
            text = "\n".join(lines)
            for stated in STATED_BUDGET.finditer(text):
                if f"{stated.group(1)} bytes" != budget:
                    problem(f"{name}:{text.count(chr(10), 0, stated.start(1)) + 1}: states a size budget of "
                            f"{stated.group(1)} bytes, but {SIZE_SCRIPT} enforces {budget}")

    # The log code reference of docs/LOGGING.md: exactly the codes of Logger.swift, each at its catalogue level.
    logger = read_text(os.path.join(ios, "Sources", "SallaPushCore", "Logging", "Logger.swift"))
    case_codes = dict(re.findall(r'case (\w+) = "([a-z_]+\.[a-z_]+)"', logger))
    level_switch = logger[logger.find("package var level"):logger.find("package var category")]
    catalogue = {}
    for case_names, level in re.findall(r"case ((?:\.\w+,?\s*)+):\s*return \.(\w+)", level_switch):
        for case_name in re.findall(r"\.(\w+)", case_names):
            if case_name in case_codes:
                catalogue[case_codes[case_name]] = level
    if not case_codes or set(catalogue) != set(case_codes.values()):
        problem("could not read every log code and its level from Sources/SallaPushCore/Logging/Logger.swift")
    reference = documents.get(LOG_REFERENCE, [])
    try:
        table_start = reference.index(LOG_TABLE_START)
        table_end = reference.index(LOG_TABLE_END)
    except ValueError:
        problem(f"{LOG_REFERENCE} has no {LOG_TABLE_START} ... {LOG_TABLE_END} table")
        table_start = table_end = 0
    listed = {}
    for number in range(table_start + 1, table_end):
        row = re.match(r"^\|\s*`([a-z_]+\.[a-z_]+)`\s*\|\s*(\w+)\s*\|", reference[number])
        if row:
            if row.group(1) in listed:
                problem(f"{LOG_REFERENCE}:{number + 1}: {row.group(1)} is listed twice")
            listed[row.group(1)] = row.group(2)
    for code in sorted(set(catalogue) - set(listed)):
        problem(f"{LOG_REFERENCE} log code reference: {code} ({catalogue[code]}) is missing")
    for code in sorted(set(listed) - set(catalogue)):
        problem(f"{LOG_REFERENCE} log code reference: {code} is not a SallaPush iOS log code")
    for code in sorted(set(listed) & set(catalogue)):
        if listed[code] != catalogue[code]:
            problem(f"{LOG_REFERENCE} log code reference: {code} is {catalogue[code]}, not {listed[code]}")
    # Every log code the README and the docs name outside that table, such as in troubleshooting, exists too.
    prefixes = {code.split(".")[0] for code in catalogue}
    for name, lines in documents.items():
        in_fence = False
        for number, line in enumerate(lines, 1):
            if fence_open.match(line):
                in_fence = not in_fence
                continue
            if in_fence or (name == LOG_REFERENCE and table_start < number <= table_end):
                continue
            for code in re.findall(r"`([a-z]+\.[a-z_]+)`", line):
                prefix, _, last = code.partition(".")
                if prefix in prefixes and last not in FILE_EXTENSIONS and code not in catalogue:
                    problem(f"{name}:{number}: {code} is not a SallaPush iOS log code")

    # The pinned version: the "- **Version:**" line, every line that says "exact" or "pin to" (an upgrade step), and
    # every CocoaPods `:tag =>`, in the README and the docs. The README must name it.
    version_file = os.path.join(ios, "Sources", "SallaPushCore", "SallaPushVersion.swift")
    declared = re.findall(r'^package let sallaPushSDKVersion = "(.+)"$', read_text(version_file), re.MULTILINE)
    pins = dict.fromkeys(documents, 0)
    if len(declared) != 1:
        problem("Sources/SallaPushCore/SallaPushVersion.swift must declare sallaPushSDKVersion exactly once")
    else:
        for name, lines in documents.items():
            for number, line in enumerate(lines, 1):
                lowered = line.lower()
                if ("exact" not in lowered and "pin to" not in lowered and ":tag =>" not in line
                        and not line.startswith("- **Version:**")):
                    continue
                for version in re.findall(r"\b\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?", line):
                    pins[name] += 1
                    if version.rstrip(".") != declared[0]:
                        problem(f"{name}:{number}: pins {version.rstrip('.')}, but the SDK declares {declared[0]}")
        if pins[README] == 0:
            problem("README.md names no version: its '- **Version:**' line and the exact pins must name the SDK version")

    summary = (f"README.md and {len(documents) - 1} docs match the example: {counts['files']} whole files and "
               f"{counts['regions']} regions compiled by the {SCHEME} scheme ({', '.join(scheme_targets)}), "
               f"{counts['unchecked']} unchecked block(s), {len(listed)} log codes at their catalogue levels in "
               f"{LOG_REFERENCE}, the log codes they name, the size budget of {budget}, version "
               f"{declared[0] if len(declared) == 1 else '?'} ({sum(pins.values())} pins)")
    return problems, summary


# --- Self-test: each kind of drift, made on a scratch copy, must fail the check -----------------------------------

def self_test(ios):
    def edit(root, relative, old, new):
        path = os.path.join(root, relative)
        content = read_text(path)
        if old not in content:
            raise AssertionError(f"the mutation does not apply: {relative} has no {old!r}")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content.replace(old, new, 1))

    def substitute(root, relative, pattern, replacement):
        path = os.path.join(root, relative)
        content, count = re.subn(pattern, replacement, read_text(path), count=1, flags=re.MULTILINE)
        if count != 1:
            raise AssertionError(f"the mutation does not apply: {relative} has no match for {pattern!r}")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)

    def append(root, relative, addition):
        path = os.path.join(root, relative)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(addition)

    def readme_block(region_marker, code, language="swift"):
        return f"\n{region_marker}\n```{language}\n{code}```\n"

    example = EXAMPLE
    readme = "README.md"
    reference = DOCS + "/REFERENCE.md"
    troubleshooting = DOCS + "/TROUBLESHOOTING.md"
    version_file = os.path.join("Sources", "SallaPushCore", "SallaPushVersion.swift")
    # The version cases mutate whatever version the SDK declares, so a release's version bump never touches them.
    declared = re.findall(r'^package let sallaPushSDKVersion = "(.+)"$', read_text(os.path.join(ios, version_file)),
                          re.MULTILINE)
    version = declared[0] if len(declared) == 1 else "the declared version"
    pinned, bumped = [other for other in ("9.8.7", "9.8.6", "9.8.5") if other != version][:2]

    pbxproj = os.path.join(example, PROJECT, "project.pbxproj")
    scheme = os.path.join(example, PROJECT, "xcshareddata", "xcschemes", SCHEME + ".xcscheme")
    app_delegate = os.path.join(example, "SallaPushExample", "AppDelegate.swift")
    logging_snippets = os.path.join(example, "ReadmeSnippets", "Logging.swift")
    objc_snippets = os.path.join(example, "ReadmeSnippets", "ObjCAppDelegate.m")
    broken = "// snippet:broken\nSallaPush.Notifications.thisMethodDoesNotExist(42)\n// end-snippet\n"
    missing_call = "SallaPush.Notifications.thisMethodDoesNotExist(42)\n"
    objc_missing_call = "[SallaPush thisMethodDoesNotExist];\n"

    def hidden_region(source, name, before, after, shown=missing_call, language="swift"):
        """A region named `name` in a compiled file, between the lines `before` and `after`, shown in the README."""
        def mutate(root):
            append(root, source, f"\n{before}// snippet:{name}\n{shown}// end-snippet\n{after}")
            folder = "ReadmeSnippets/" + os.path.basename(source)
            append(root, readme, readme_block(f"<!-- snippet:{folder}#{name} -->", shown, language))
        return mutate

    def region_with_text_that_looks_like_structure(root):
        # Directive and comment markers inside strings, a comment inside the region, and #available are all fine.
        shown = ('let directive = "#if false /* not a comment */ // not one either"\n'
                 'let block = """\n'
                 '    #if this is text, "quoted" \\(directive.count) \\"""\n'
                 '    /* text, not a comment\n'
                 '    """\n'
                 'let raw = #"a raw "string" with \\#(directive.count) and \\( text"#\n'
                 '/* A comment inside the region shows in the README as a comment. */\n'
                 'if #available(iOS 16, *) {\n'
                 '    print(directive, block, raw)\n'
                 '}\n')
        indented = "".join("    " + line if line.strip() else line for line in shown.splitlines(True))
        append(root, logging_snippets, f"\nfunc lexerProbe() {{\n    // snippet:lexer-text\n{indented}"
                                       f"    // end-snippet\n}}\n")
        append(root, readme, readme_block("<!-- snippet:ReadmeSnippets/Logging.swift#lexer-text -->", shown))

    def objc_region_with_text_that_looks_like_structure(root):
        shown = ('static NSString *const kDirective = @"#if 0 /* not a comment */";\n'
                 "static const char kQuote = '\"';\n"
                 "#pragma mark - Not conditional compilation\n"
                 "/* A comment inside the region shows in the README as a comment. */\n")
        append(root, objc_snippets, f"\n// snippet:objc-lexer-text\n{shown}// end-snippet\n")
        append(root, readme, readme_block("<!-- snippet:ReadmeSnippets/ObjCAppDelegate.m#objc-lexer-text -->",
                                          shown, "objc"))

    def whole_file_holds_conditional_compilation(root):
        for relative in (app_delegate, readme):
            edit(root, relative, "        SallaPush.Notifications.didReceive(response)\n",
                 "        #if DEBUG\n        SallaPush.Notifications.didReceive(response)\n        #endif\n")

    def excluded_from_target(root):
        # A membership exception that removes Logging.swift from the ReadmeSnippets target.
        path = os.path.join(root, pbxproj)
        content = read_text(path)
        group = re.search(r"(\t\t(\w{24}) /\* ReadmeSnippets \*/ = \{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n)",
                          content)
        target = re.search(r"\t\t(\w{24}) /\* ReadmeSnippets \*/ = \{\n\t\t\tisa = PBXNativeTarget;", content)
        if not group or not target:
            raise AssertionError("the mutation does not apply: no ReadmeSnippets group or target")
        content = content.replace(group.group(1), group.group(1)
                                  + "\t\t\texceptions = (\n\t\t\t\tFFFFFFFFFFFFFFFFFFFFFFFF,\n\t\t\t);\n", 1)
        content = content.replace("/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */",
                                  "\t\tFFFFFFFFFFFFFFFFFFFFFFFF = {\n\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n"
                                  "\t\t\tmembershipExceptions = (\n\t\t\t\tLogging.swift,\n\t\t\t);\n"
                                  f"\t\t\ttarget = {target.group(1)};\n\t\t}};\n"
                                  "/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */", 1)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)

    def baseline_lends_a_file_to_readme_snippets(root):
        # An exception set on SizeBaseline's folder, naming ReadmeSnippets: ReadmeSnippets compiles that file too.
        path = os.path.join(root, pbxproj)
        content = read_text(path)
        group = re.search(r"\t\t\w{24} /\* SizeBaseline \*/ = \{\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n"
                          r"\t\t\texceptions = \(\n", content)
        target = re.search(r"\t\t(\w{24}) /\* ReadmeSnippets \*/ = \{\n\t\t\tisa = PBXNativeTarget;", content)
        if not group or not target:
            raise AssertionError("the mutation does not apply: no SizeBaseline group or ReadmeSnippets target")
        content = content.replace(group.group(0), group.group(0) + "\t\t\t\tEEEEEEEEEEEEEEEEEEEEEEEE,\n", 1)
        content = content.replace("/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */",
                                  "\t\tEEEEEEEEEEEEEEEEEEEEEEEE = {\n\t\t\tisa = PBXFileSystemSynchronizedBuildFileExceptionSet;\n"
                                  "\t\t\tmembershipExceptions = (\n\t\t\t\tAppDelegate.swift,\n\t\t\t);\n"
                                  f"\t\t\ttarget = {target.group(1)};\n\t\t}};\n"
                                  "/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */", 1)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)
        append(root, os.path.join(example, "SizeBaseline", "AppDelegate.swift"),
               "\n// snippet:lent\nlet lentToReadmeSnippets = 1\n// end-snippet\n")
        append(root, readme, readme_block("<!-- snippet:SizeBaseline/AppDelegate.swift#lent -->",
                                          "let lentToReadmeSnippets = 1\n"))

    def readme_stops_building_snippets(root):
        path = os.path.join(root, scheme)
        content = read_text(path)
        entry = re.search(r'buildForRunning = "YES"(?=(?:(?!BuildActionEntry>).)*libReadmeSnippets\.a)', content, re.S)
        if not entry:
            raise AssertionError("the mutation does not apply: the scheme has no ReadmeSnippets entry")
        content = content[:entry.start()] + 'buildForRunning = "NO"' + content[entry.end():]
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)

    cases = [
        ("an unmodified copy passes", lambda root: None, None),
        ("a whole file drifts in the README",
         lambda root: edit(root, readme, 'SallaPush.initialize("00000000-0000-4000-8000-000000000001", withLaunchOptions: launchOptions)\n'
                                         "        // Set", 'SallaPush.initialize("00000000-0000-4000-8000-000000000009", withLaunchOptions: '
                                                          "launchOptions)\n        // Set"),
         "differs from Examples/SallaPushExample/SallaPushExample/AppDelegate.swift"),
        ("a whole file drifts in the example",
         lambda root: edit(root, app_delegate, "completionHandler(.noData)", "completionHandler(.newData)"),
         "differs from Examples/SallaPushExample/SallaPushExample/AppDelegate.swift"),
        ("a region drifts", lambda root: edit(root, logging_snippets, "logLevel = .verbose", "logLevel = .debug"),
         "ReadmeSnippets/Logging.swift#log-level"),
        ("a block of docs/REFERENCE.md drifts",
         lambda root: edit(root, reference, "configuration.openLaunchURLs = true\n",
                           "configuration.openLaunchURLs = false\n"),
         (f"{reference}:", f"the block differs from {example}/ReadmeSnippets/Configuration.swift#configuration")),
        ("a Swift block has no marker",
         lambda root: edit(root, readme, "<!-- snippet:ReadmeSnippets/Logging.swift#log-level -->\n", ""),
         "needs a snippet or unchecked marker"),
        ("a marker names an unknown region",
         lambda root: edit(root, readme, "Logging.swift#log-level -->", "Logging.swift#log-levels -->"),
         "has no region 'log-levels'"),
        ("a marker names a missing file",
         lambda root: edit(root, readme, "ReadmeSnippets/Logging.swift#log-level -->",
                           "ReadmeSnippets/Logs.swift#log-level -->"), "Logs.swift does not exist"),
        ("a marker path escapes the example",
         lambda root: edit(root, readme, "snippet:ReadmeSnippets/Logging.swift#log-level",
                           "snippet:" + "/".join([os.pardir, os.pardir, "README.md"])),
         "must stay inside"),
        ("a snippet's file is compiled by no target",
         lambda root: (append(root, os.path.join(example, "Drafts", "Broken.swift"), broken),
                       append(root, readme, readme_block("<!-- snippet:Drafts/Broken.swift#broken -->",
                                                         "SallaPush.Notifications.thisMethodDoesNotExist(42)\n"))),
         "Drafts/Broken.swift is not compiled by the SallaPushExample scheme"),
        ("a snippet's file is excluded from its target", excluded_from_target,
         "ReadmeSnippets/Logging.swift is not compiled by the SallaPushExample scheme"),
        ("a snippet's file is compiled only by a target outside the scheme",
         lambda root: (append(root, os.path.join(example, "SizeBaseline", "AppDelegate.swift"),
                              "\n// snippet:baseline\nlet baselineOnly = 1\n// end-snippet\n"),
                       append(root, readme, readme_block("<!-- snippet:SizeBaseline/AppDelegate.swift#baseline -->",
                                                         "let baselineOnly = 1\n"))),
         "SizeBaseline/AppDelegate.swift is not compiled by the SallaPushExample scheme"),
        ("a file another target's folder lends to a scheme target is compiled",
         baseline_lends_a_file_to_readme_snippets, None),
        ("the scheme stops building ReadmeSnippets", readme_stops_building_snippets,
         "is not compiled by the SallaPushExample scheme"),
        ("the project file cannot be read",
         lambda root: edit(root, pbxproj, "objects = {", "objects = {{"), "could not read"),
        ("the README stops showing the required extension file",
         lambda root: edit(root, readme, "<!-- snippet:SallaPushExampleNSE/NotificationService.swift -->",
                           "<!-- unchecked: test -->"),
         "does not show Examples/SallaPushExample/SallaPushExampleNSE/NotificationService.swift in full"),
        ("an unchecked marker has no reason",
         lambda root: substitute(root, readme, r"^<!-- unchecked: .+-->$", "<!-- unchecked: -->"), "needs a reason"),
        ("a marker is not followed by a block",
         lambda root: edit(root, readme, "<!-- snippet:ReadmeSnippets/Logging.swift#log-level -->\n",
                           "<!-- snippet:ReadmeSnippets/Logging.swift#log-level -->\n\n"),
         "must be followed by a fenced code block"),
        ("a code block is not closed", lambda root: append(root, readme, "\n```swift\nlet unclosed = 1\n"),
         "is not closed"),
        ("the README pins another version",
         lambda root: edit(root, readme, f'exact: "{version}"', f'exact: "{pinned}"'), f"pins {pinned}"),
        ("a CocoaPods line of the README pins another version",
         lambda root: edit(root, readme, f":tag => '{version}'", f":tag => '{pinned}'"), f"pins {pinned}"),
        ("the SDK declares another version",
         lambda root: edit(root, version_file, f'"{version}"', f'"{bumped}"'), f"but the SDK declares {bumped}"),
        ("a doc pins another version",
         lambda root: append(root, reference, f"\nChange the version you pin to `{pinned}`.\n"),
         (f"{reference}:", f"pins {pinned}")),
        ("the prose names a log code the SDK doesn't have",
         lambda root: edit(root, readme, "| `init.no_delegate` |", "| `init.no_delegates` |"),
         "init.no_delegates is not a SallaPush iOS log code"),
        ("a doc names a log code the SDK doesn't have",
         lambda root: edit(root, troubleshooting, "| `init.no_delegate` |", "| `init.no_delegates` |"),
         (f"{troubleshooting}:", "init.no_delegates is not a SallaPush iOS log code")),
        ("a file name that starts like a log code is not one",
         lambda root: append(root, reference, "\nSallaPush keeps `identity.json`, `events.json` and `consent.json`.\n"),
         None),
        ("a log code is missing",
         lambda root: edit(root, LOG_REFERENCE, "| `nse.expired` | warn |", "| nse.expired | warn |"),
         "nse.expired (warn) is missing"),
        ("a log level drifts",
         lambda root: edit(root, LOG_REFERENCE, "| `register.ok` | info |", "| `register.ok` | debug |"),
         "register.ok is info, not debug"),
        ("an unknown log code is listed",
         lambda root: edit(root, LOG_REFERENCE, LOG_TABLE_END, "| `log.lost` | warn | Not a code |\n" + LOG_TABLE_END),
         "log.lost is not a SallaPush iOS log code"),
        ("the README states another budget",
         lambda root: append(root, readme, "\nSallaPush adds no more than 1 bytes.\n"),
         "states a size budget of 1 bytes"),
        ("a region sits inside #if false",
         hidden_region(logging_snippets, "inactive", "#if false\n", "#endif\n"),
         "region 'inactive' starts inside the #if block of line"),
        ("a region sits inside #if canImport of an SDK that isn't linked",
         hidden_region(logging_snippets, "missing-sdk", "#if canImport(SomeSDKThatIsNotLinked)\n", "#endif\n"),
         "region 'missing-sdk' starts inside the #if block of line"),
        ("a region sits in the #else branch",
         hidden_region(logging_snippets, "else-branch", "#if canImport(UIKit)\nlet linked = 1\n#else\n", "#endif\n"),
         "region 'else-branch' starts inside the #if block of line"),
        ("a region sits inside a /* */ comment",
         hidden_region(logging_snippets, "commented-out", "/*\n", "*/\n"),
         "region 'commented-out' starts inside a /* */ comment"),
        ("a region sits inside a nested Swift comment",
         hidden_region(logging_snippets, "nested-comment", "/* outer /* inner */ still a comment\n", "*/\n"),
         "region 'nested-comment' starts inside a /* */ comment"),
        ("a region sits inside a multi-line string literal",
         hidden_region(logging_snippets, "in-string", 'let hidden = """\n', '"""\n'),
         "region 'in-string' starts inside a string literal"),
        ("a directive after a comment on its line still opens a block",
         hidden_region(logging_snippets, "after-comment", "/* note */ #if false\n", "#endif\n"),
         "region 'after-comment' starts inside the #if block of line"),
        ("a region opens a /* */ comment that its end marker sits in",
         hidden_region(logging_snippets, "open-comment", "", "*/\n", shown=missing_call + "/*\n"),
         "region 'open-comment' ends inside a /* */ comment"),
        ("a region holds conditional compilation",
         hidden_region(logging_snippets, "conditional-body", "", "",
                       shown="#if canImport(SomeSDKThatIsNotLinked)\n" + missing_call + "#endif\n"),
         "region 'conditional-body' holds #if"),
        ("an Objective-C region sits inside #if 0",
         hidden_region(objc_snippets, "objc-inactive", "#if 0\n", "#endif\n", objc_missing_call, "objc"),
         "region 'objc-inactive' starts inside the #if block of line"),
        ("an Objective-C region sits inside #ifdef",
         hidden_region(objc_snippets, "objc-ifdef", "#ifdef SOME_MACRO_THAT_IS_NOT_DEFINED\n", "#endif\n",
                       objc_missing_call, "objc"),
         "region 'objc-ifdef' starts inside the #ifdef block of line"),
        ("an Objective-C region sits inside a /* */ comment",
         hidden_region(objc_snippets, "objc-commented-out", "/*\n", "*/\n", objc_missing_call, "objc"),
         "region 'objc-commented-out' starts inside a /* */ comment"),
        ("a file shown in full holds conditional compilation", whole_file_holds_conditional_compilation,
         "SallaPushExample/AppDelegate.swift holds #if at line"),
        ("directive and comment text in strings is not structure", region_with_text_that_looks_like_structure, None),
        ("directive and comment text in Objective-C strings is not structure",
         objc_region_with_text_that_looks_like_structure, None),
    ]

    failures = 0
    scratch = tempfile.mkdtemp(prefix="check-readme-snippets.")
    try:
        for name, mutate, expected in cases:
            root = os.path.join(scratch, "ios")
            shutil.rmtree(root, ignore_errors=True)
            shutil.copytree(os.path.join(ios, EXAMPLE), os.path.join(root, EXAMPLE),
                            ignore=shutil.ignore_patterns("xcuserdata", ".DS_Store", "__pycache__"))
            shutil.copyfile(os.path.join(ios, "README.md"), os.path.join(root, "README.md"))
            shutil.copytree(os.path.join(ios, DOCS), os.path.join(root, DOCS),
                            ignore=shutil.ignore_patterns(".DS_Store"))
            for relative in (("Sources", "SallaPushCore", "SallaPushVersion.swift"),
                             ("Sources", "SallaPushCore", "Logging", "Logger.swift"),
                             tuple(SIZE_SCRIPT.split(os.sep))):
                os.makedirs(os.path.join(root, *relative[:-1]), exist_ok=True)
                shutil.copyfile(os.path.join(ios, *relative), os.path.join(root, *relative))
            try:
                mutate(root)
                problems, _ = check(root)
            except AssertionError as error:
                print(f"FAIL {name}: {error}")
                failures += 1
                continue
            # A tuple of texts must all be in one problem, such as the file it names and the drift.
            parts = (expected,) if isinstance(expected, str) else expected
            caught = not problems if expected is None else any(all(part in found for part in parts)
                                                               for found in problems)
            if caught:
                print(f"ok   {name}")
            else:
                failures += 1
                print(f"FAIL {name}: expected {'no problem' if expected is None else repr(expected)}, got:")
                for found in problems[:5]:
                    print("       " + found.split("\n")[0])
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    print(f"check-readme-snippets --self-test: {len(cases) - failures} of {len(cases)} cases behave as expected")
    return failures == 0


ios, mode = sys.argv[1], sys.argv[2]
if mode == "--self-test":
    sys.exit(0 if self_test(ios) else 1)
problems, summary = check(ios)
if problems:
    for message in problems:
        print(f"check-readme-snippets: {message}", file=sys.stderr)
    print(f"check-readme-snippets: {len(problems)} problem(s)", file=sys.stderr)
    sys.exit(1)
print(f"check-readme-snippets: {summary}")
PY
