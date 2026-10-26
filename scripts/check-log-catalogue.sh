#!/usr/bin/env bash
# Keeps this SDK's log codes the shared catalogue's. A code is stable API that apps match on in their log handlers,
# always logged at one level and with one category (scripts/log-catalogue.txt), so this check:
#   1. reads every code, with its level and category, from the source: the LogCode enum of
#      Sources/SallaPushCore/Logging/Logger.swift (its cases, its level switch and its category switch);
#   2. fails when Logger.swift differs from the catalogue's lines for "both" and "ios" in any way: a code the catalogue
#      lacks or lists for the Android SDK only, a code of the catalogue that the SDK lacks, another level, another
#      category.
# Tests/SallaPushTests/LogCatalogTests.swift keeps its own list of the codes equal to LogCode in codes and levels
# (swift test), so the tests, the SDK and the catalogue agree.
# It reads the source as text, without a build. Comments, string literals and interpolations are read as the compiler
# reads them, so a quote or a brace inside them cannot shift what the check sees. A source whose shape it does not know
# fails the check, with the line: a check that cannot read the codes must never pass.
#
#   scripts/check-log-catalogue.sh    run from anywhere (scripts/verify.sh catalogue)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

if [ "$#" -ne 0 ]; then
  echo 'usage: scripts/check-log-catalogue.sh' >&2
  exit 2
fi
command -v python3 >/dev/null 2>&1 || {
  echo 'check-log-catalogue.sh: python3 is required' >&2
  exit 1
}

python3 - "$root" scripts/log-catalogue.txt Sources/SallaPushCore/Logging/Logger.swift <<'PY'
import os
import re
import sys

root, catalogue_path, swift_path = sys.argv[1:4]
PROGRAM = "check-log-catalogue.sh"
LEVELS = ("error", "warn", "info", "debug", "verbose")
PLATFORMS = ("both", "ios", "android")
IOS = ("both", "ios")
CATEGORIES = ("lifecycle", "registration", "identity", "notifications", "events", "tags", "network", "storage",
              "consent", "extension")
CODE = re.compile(r"[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*\Z")


class Unreadable(Exception):
    """Something this check cannot read with certainty; line is None when the problem has no line."""

    def __init__(self, message, line=None):
        super().__init__(message)
        self.line = line


# ---------------------------------------------------------------------------------------------------
# Swift tokens: names, string literals (decoded), numbers, punctuation and compiler directives.

class Token:
    __slots__ = ("kind", "text", "line", "plain")

    def __init__(self, kind, text, line, plain=True):
        self.kind = kind  # name, quoted-name, string, number, punct or directive
        self.text = text
        self.line = line
        # A string literal whose text is exactly its value: no interpolation, and not a multi-line literal, whose value
        # Swift derives by stripping indentation that this reader keeps.
        self.plain = plain


LONG_PUNCTUATION = ("...", "..<", "->", "!=", "==", "<=", ">=", "&&", "||", "::", "?.", "?:", "!!",
                    "+=", "-=", "*=", "/=", "%=")
ESCAPES = {"0": "\0", "\\": "\\", "t": "\t", "n": "\n", "r": "\r", '"': '"', "'": "'"}


class Lexer:
    def __init__(self, text):
        self.text = text
        self.i = 0
        self.line = 1

    def fail(self, message, line=None):
        raise Unreadable(message, line or self.line)

    def tokens(self):
        result = []
        while True:
            token = self.next()
            if token is None:
                return result
            result.append(token)

    def peek(self, offset=0):
        index = self.i + offset
        return self.text[index] if index < len(self.text) else ""

    def skip_blank(self):
        text, n = self.text, len(self.text)
        while self.i < n:
            c = text[self.i]
            if c == "\n":
                self.line += 1
                self.i += 1
            elif c in " \t\r\f\v":
                self.i += 1
            elif text.startswith("//", self.i):
                end = text.find("\n", self.i)
                self.i = n if end < 0 else end
            elif text.startswith("/*", self.i):
                # Swift nests block comments.
                start, depth = self.line, 1
                self.i += 2
                while depth:
                    if self.i >= n:
                        self.fail("a block comment never ends", start)
                    if text.startswith("/*", self.i):
                        depth += 1
                        self.i += 2
                    elif text.startswith("*/", self.i):
                        depth -= 1
                        self.i += 2
                    else:
                        if text[self.i] == "\n":
                            self.line += 1
                        self.i += 1
            else:
                return

    def next(self):
        self.skip_blank()
        text, n = self.text, len(self.text)
        if self.i >= n:
            return None
        c, line = text[self.i], self.line
        if c == '"':
            return self.string(0)
        if c == "#":
            # A raw string (#"...", ##"..."), or a compiler directive such as #if.
            hashes = 0
            while self.peek(hashes) == "#":
                hashes += 1
            if self.peek(hashes) == '"':
                self.i += hashes
                return self.string(hashes)
            end = self.i + 1
            while end < n and (text[end].isalnum() or text[end] == "_"):
                end += 1
            if end == self.i + 1:
                self.i += 1
                return Token("punct", "#", line)
            directive = text[self.i:end]
            self.i = end
            return Token("directive", directive, line)
        if c == "`":
            end = text.find("`", self.i + 1)
            if end < 0 or "\n" in text[self.i:end]:
                self.fail("a quoted name never ends")
            name = text[self.i + 1:end]
            self.i = end + 1
            return Token("quoted-name", name, line)
        if c.isalpha() or c == "_" or c == "$":
            end = self.i + 1
            while end < n and (text[end].isalnum() or text[end] in "_$"):
                end += 1
            name = text[self.i:end]
            self.i = end
            return Token("name", name, line)
        if c.isdigit():
            end = self.i + 1
            while end < n and (text[end].isalnum() or text[end] == "_" or
                               (text[end] == "." and end + 1 < n and text[end + 1].isdigit())):
                end += 1
            number = text[self.i:end]
            self.i = end
            return Token("number", number, line)
        for punctuation in LONG_PUNCTUATION:
            if text.startswith(punctuation, self.i):
                self.i += len(punctuation)
                return Token("punct", punctuation, line)
        self.i += 1
        return Token("punct", c, line)

    def group(self, opening, closing):
        """Skips an interpolation: from its opening bracket to the one that closes it."""
        start, depth = self.line, 1
        self.i += 1
        while depth:
            token = self.next()
            if token is None:
                self.fail("an interpolation never ends", start)
            if token.kind == "punct" and token.text == opening:
                depth += 1
            elif token.kind == "punct" and token.text == closing:
                depth -= 1

    def string(self, hashes):
        """A string literal, at its opening quote. hashes counts the # before a raw string."""
        text, n = self.text, len(self.text)
        start = self.line
        multiline = text.startswith('"""', self.i)
        self.i += 3 if multiline else 1
        closing = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        parts, interpolated = [], False
        while True:
            if self.i >= n:
                self.fail("a string literal never ends", start)
            if text.startswith(closing, self.i):
                self.i += len(closing)
                return Token("string", "".join(parts), start, not interpolated and not multiline)
            c = text[self.i]
            if text.startswith(escape, self.i):
                after = self.i + len(escape)
                kind = text[after] if after < n else ""
                if kind == "(":
                    self.i = after
                    self.group("(", ")")
                    interpolated = True
                    continue
                if kind == "u" and text.startswith("{", after + 1):
                    end = text.find("}", after + 2)
                    digits = text[after + 2:end] if end > 0 else ""
                    if not re.fullmatch(r"[0-9A-Fa-f]{1,8}", digits):
                        self.fail("a \\u{...} escape is malformed")
                    parts.append(chr(int(digits, 16)))
                    self.i = end + 1
                    continue
                if multiline and kind == "\n":
                    self.line += 1
                    self.i = after + 1
                    continue
                if kind not in ESCAPES:
                    self.fail(f"the escape \\{kind} is not one Swift knows")
                parts.append(ESCAPES[kind])
                self.i = after + 1
                continue
            if c == "\n":
                if not multiline:
                    self.fail("a string literal never ends", start)
                self.line += 1
            parts.append(c)
            self.i += 1


# ---------------------------------------------------------------------------------------------------
# Structure helpers over a token list.

OPENING = {"(": ")", "[": "]", "{": "}"}


def is_name(token, text=None):
    return token.kind in ("name", "quoted-name") and (text is None or token.text == text)


def is_keyword(token, text):
    return token.kind == "name" and token.text == text


def is_punct(token, text):
    return token.kind == "punct" and token.text == text


def is_plain_string(token):
    return token.kind == "string" and token.plain


def bracket_pairs(tokens):
    """Maps the index of every opening bracket to the index of the bracket that closes it."""
    pairs, stack = {}, []
    for index, token in enumerate(tokens):
        if token.kind != "punct":
            continue
        if token.text in OPENING:
            stack.append(index)
        elif token.text in (")", "]", "}"):
            if not stack or OPENING[tokens[stack[-1]].text] != token.text:
                raise Unreadable(f"an unbalanced {token.text}", token.line)
            pairs[stack.pop()] = index
    if stack:
        raise Unreadable(f"a {tokens[stack[-1]].text} that never closes", tokens[stack[-1]].line)
    return pairs


def top_level(pairs, start, end):
    """The indices in [start, end) outside any bracket; a bracketed group yields only its opening index."""
    index = start
    while index < end:
        yield index
        index = pairs[index] + 1 if index in pairs else index + 1


def split_top_level(tokens, pairs, start, end, separator=","):
    """The [start, end) ranges between the separators outside any bracket."""
    ranges, begin = [], start
    for index in top_level(pairs, start, end):
        if is_punct(tokens[index], separator):
            ranges.append((begin, index))
            begin = index + 1
    ranges.append((begin, end))
    return ranges


def first_top_level(tokens, pairs, start, end, punctuation):
    return next((index for index in top_level(pairs, start, end) if is_punct(tokens[index], punctuation)), None)


def text_of(tokens):
    return " ".join('"%s"' % token.text if token.kind == "string" else token.text for token in tokens)


def qualified(tokens, owner):
    """The last name of NAME or OWNER.NAME (with any module before OWNER); None for anything else."""
    if len(tokens) == 1 and is_name(tokens[0]):
        return tokens[0].text
    if (len(tokens) >= 3 and len(tokens) % 2 == 1 and all(is_name(token) for token in tokens[0::2])
            and all(is_punct(token, ".") for token in tokens[1::2]) and tokens[-3].text == owner):
        return tokens[-1].text
    return None


# ---------------------------------------------------------------------------------------------------
# enum LogCode in Logger.swift.

SWIFT_SHAPE = ("this check reads the cases of enum LogCode (case name = \"code\"), its computed property level (one "
               "switch over self that returns a level such as .warn) and its computed property category (one switch "
               "over self, rawValue or rawValue.prefix(while: { $0 != \".\" }) that returns a string literal)")


def swift_switch(tokens, pairs, opening, what):
    """The subject, and the bounds of the switch body, of a computed property that is one switch."""
    start, end = opening + 1, pairs[opening]
    if start + 1 < end and is_keyword(tokens[start], "get") and is_punct(tokens[start + 1], "{"):
        if pairs[start + 1] != end - 1:
            raise Unreadable(f"{what} holds more than its getter", tokens[start].line)
        start, end = start + 2, end - 1
    if start < end and is_keyword(tokens[start], "return"):
        start += 1
    if not (start < end and is_keyword(tokens[start], "switch")):
        line = tokens[start].line if start < end else tokens[opening].line
        raise Unreadable(f"{what} is not one switch", line)
    body = start + 1
    while body < end and not is_punct(tokens[body], "{"):
        body = pairs[body] + 1 if body in pairs else body + 1
    if body >= end:
        raise Unreadable(f"the switch of {what} has no body", tokens[start].line)
    if pairs[body] != end - 1:
        raise Unreadable(f"{what} holds more than its switch", tokens[pairs[body] + 1].line)
    return tokens[start + 1:body], body, pairs[body]


def swift_arms(tokens, pairs, opening, closing, what):
    """[(patterns or None for default, result tokens, line)] of a switch body."""
    starts = []
    for index in top_level(pairs, opening + 1, closing):
        token = tokens[index]
        if token.kind == "directive":
            raise Unreadable(f"{token.text} inside the switch of {what}: this check cannot tell which arms are "
                             "compiled", token.line)
        if is_punct(token, "@"):
            raise Unreadable(f"the switch of {what} has an attribute such as @unknown", token.line)
        if is_keyword(token, "case") or is_keyword(token, "default"):
            starts.append(index)
    if not starts or starts[0] != opening + 1:
        raise Unreadable(f"the switch of {what} does not start with a case", tokens[opening].line)
    arms = []
    for number, start in enumerate(starts):
        end = starts[number + 1] if number + 1 < len(starts) else closing
        colon = first_top_level(tokens, pairs, start + 1, end, ":")
        if colon is None:
            raise Unreadable(f"an arm of the switch of {what} has no colon", tokens[start].line)
        if is_keyword(tokens[start], "default"):
            if colon != start + 1:
                raise Unreadable(f"the default arm of the switch of {what} is malformed", tokens[start].line)
            patterns = None
        else:
            patterns = [tokens[a:b] for a, b in split_top_level(tokens, pairs, start + 1, colon)]
        result = tokens[colon + 1:end]
        if result and is_punct(result[-1], ";"):
            result = result[:-1]
        if result and is_keyword(result[0], "return"):
            result = result[1:]
        arms.append((patterns, result, tokens[start].line))
    return arms


def swift_case_name(pattern, line, what):
    if len(pattern) == 2 and is_punct(pattern[0], ".") and is_name(pattern[1]):
        return pattern[1].text
    if (len(pattern) == 3 and is_name(pattern[0]) and pattern[0].text in ("LogCode", "Self")
            and is_punct(pattern[1], ".") and is_name(pattern[2])):
        return pattern[2].text
    raise Unreadable(f"the switch of {what} has the pattern {text_of(pattern)}, not a case such as .initStarted", line)


def swift_level(result, line):
    if len(result) == 2 and is_punct(result[0], ".") and is_name(result[1]):
        level = result[1].text
    else:
        level = qualified(result, "SallaPushLogLevel") if len(result) >= 3 else None
    if level is None:
        raise Unreadable(f"an arm of the switch of LogCode.level returns {text_of(result) or 'nothing'}, "
                         "not a level such as .warn", line)
    if level == "off":
        raise Unreadable("an arm of the switch of LogCode.level returns .off, which no code is logged at", line)
    if level not in LEVELS:
        raise Unreadable(f"an arm of the switch of LogCode.level returns .{level}, which is not a log level", line)
    return level


def swift_category_subject(subject):
    """How a category switch matches a code: by case, by the whole code or by its prefix before the dot."""
    texts = [("string", token.text) if token.kind == "string" else (token.kind, token.text) for token in subject]
    if texts[:2] == [("name", "self"), ("punct", ".")]:
        texts = texts[2:]
    if texts == [("name", "self")]:
        return "case"
    if texts == [("name", "rawValue")]:
        return "code"
    prefix = [("name", "rawValue"), ("punct", "."), ("name", "prefix"), ("punct", "("), ("name", "while"),
              ("punct", ":"), ("punct", "{"), ("name", "$0"), ("punct", "!="), ("string", "."), ("punct", "}"),
              ("punct", ")")]
    return "prefix" if texts == prefix else None


def read_swift(text):
    tokens = Lexer(text).tokens()
    pairs = bracket_pairs(tokens)
    found = [index for index in range(len(tokens) - 1)
             if is_keyword(tokens[index], "enum") and is_name(tokens[index + 1], "LogCode")]
    if len(found) != 1:
        raise Unreadable(f"expected one enum LogCode, found {len(found)}")
    opening = found[0] + 2
    while opening < len(tokens) and not is_punct(tokens[opening], "{"):
        opening = pairs[opening] + 1 if opening in pairs else opening + 1
    if opening >= len(tokens):
        raise Unreadable("enum LogCode has no body", tokens[found[0]].line)
    closing = pairs[opening]

    cases, properties = [], {}
    index = opening + 1
    while index < closing:
        token = tokens[index]
        if token.kind == "directive":
            raise Unreadable(f"{token.text} inside enum LogCode: this check cannot tell which cases are compiled",
                             token.line)
        if is_keyword(token, "case"):
            index += 1
            while True:
                if index >= closing or not is_name(tokens[index]):
                    raise Unreadable("a case of LogCode without a name", token.line)
                name = tokens[index]
                if index + 1 < closing and is_punct(tokens[index + 1], "("):
                    raise Unreadable(f"case {name.text} of LogCode has associated values", name.line)
                if not (index + 2 < closing and is_punct(tokens[index + 1], "=")
                        and tokens[index + 2].kind == "string"):
                    raise Unreadable(f"case {name.text} of LogCode has no code; write case {name.text} = \"<code>\"",
                                     name.line)
                if not tokens[index + 2].plain:
                    raise Unreadable(f"the code of case {name.text} is not a plain string literal", name.line)
                cases.append((name.text, tokens[index + 2].text, name.line))
                index += 3
                if index < closing and is_punct(tokens[index], ","):
                    index += 1
                    continue
                break
            continue
        if (is_keyword(token, "var") and index + 1 < closing and is_name(tokens[index + 1])
                and tokens[index + 1].text in ("level", "category")):
            name = tokens[index + 1].text
            if name in properties:
                raise Unreadable(f"enum LogCode declares {name} twice", token.line)
            brace = index + 2
            while brace < closing and not is_punct(tokens[brace], "{"):
                if is_punct(tokens[brace], "="):
                    raise Unreadable(f"LogCode.{name} is a stored property", token.line)
                brace = pairs[brace] + 1 if brace in pairs else brace + 1
            if brace >= closing:
                raise Unreadable(f"LogCode.{name} has no body", token.line)
            properties[name] = brace
            index = pairs[brace] + 1
            continue
        index = pairs[index] + 1 if index in pairs else index + 1

    if not cases:
        raise Unreadable("enum LogCode has no cases", tokens[found[0]].line)
    names, codes = {}, {}
    for name, code, line in cases:
        if name in names:
            raise Unreadable(f"case {name} of LogCode is declared twice", line)
        if code in codes:
            raise Unreadable(f"the code {code} belongs to two cases, {codes[code]} and {name}", line)
        names[name] = code
        codes[code] = name
    for name in ("level", "category"):
        if name not in properties:
            raise Unreadable(f"enum LogCode has no computed property {name}", tokens[found[0]].line)

    subject, body, end = swift_switch(tokens, pairs, properties["level"], "LogCode.level")
    if [token.text for token in subject] != ["self"]:
        raise Unreadable(f"the switch of LogCode.level is over {text_of(subject)}, not self", tokens[body].line)
    levels, default_level = {}, None
    for patterns, result, line in swift_arms(tokens, pairs, body, end, "LogCode.level"):
        level = swift_level(result, line)
        if patterns is None:
            default_level = (level, line)
            continue
        for pattern in patterns:
            name = swift_case_name(pattern, line, "LogCode.level")
            if name not in names:
                raise Unreadable(f"the switch of LogCode.level names .{name}, which is not a case of LogCode", line)
            if name in levels:
                raise Unreadable(f"the switch of LogCode.level lists .{name} twice", line)
            levels[name] = (level, line)

    subject, body, end = swift_switch(tokens, pairs, properties["category"], "LogCode.category")
    kind = swift_category_subject(subject)
    if kind is None:
        raise Unreadable(f"the switch of LogCode.category is over {text_of(subject)}, not self, rawValue or "
                         "rawValue.prefix(while: { $0 != \".\" })", tokens[body].line)
    categories, default_category = {}, None
    for patterns, result, line in swift_arms(tokens, pairs, body, end, "LogCode.category"):
        if not (len(result) == 1 and is_plain_string(result[0])):
            raise Unreadable(f"an arm of the switch of LogCode.category returns {text_of(result) or 'nothing'}, "
                             "not a string literal", line)
        if patterns is None:
            default_category = (result[0].text, line)
            continue
        for pattern in patterns:
            if kind == "case":
                key = swift_case_name(pattern, line, "LogCode.category")
                if key not in names:
                    raise Unreadable(f"the switch of LogCode.category names .{key}, which is not a case of LogCode",
                                     line)
            elif len(pattern) == 1 and is_plain_string(pattern[0]):
                key = pattern[0].text
            else:
                raise Unreadable(f"the switch of LogCode.category has the pattern {text_of(pattern)}, "
                                 "not a string literal", line)
            if key in categories:
                raise Unreadable(f"the switch of LogCode.category lists {key} twice", line)
            categories[key] = (result[0].text, line)

    result = {}
    for name, code, line in cases:
        level = levels.get(name, default_level)
        if level is None:
            raise Unreadable(f"case {name} has no level: no arm of the switch of LogCode.level names it, "
                             "and the switch has no default", line)
        key = {"case": name, "code": code, "prefix": code.split(".", 1)[0]}[kind]
        category = categories.get(key, default_category)
        if category is None:
            raise Unreadable(f"case {name} has no category: no arm of the switch of LogCode.category matches it, "
                             "and the switch has no default", line)
        result[code] = {"line": line, "level": level[0], "level_line": level[1], "category": category[0],
                        "category_line": category[1]}
    return result


# ---------------------------------------------------------------------------------------------------
# log-catalogue.txt: code, level, platform and category per line; # starts a comment line.

def read_catalogue(text):
    rows = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 4:
            raise Unreadable(f"expected 4 columns (code, level, platform, category), found {len(fields)}", number)
        code, level, platform, category = fields
        if not CODE.match(code):
            raise Unreadable(f"{code} is not a code: <area>.<name>, in lowercase letters, digits and underscores",
                             number)
        if level not in LEVELS:
            raise Unreadable(f"{code} has the level {level}; the levels are {', '.join(LEVELS)}", number)
        if platform not in PLATFORMS:
            raise Unreadable(f"{code} has the platform {platform}; the platforms are {', '.join(PLATFORMS)}", number)
        if category not in CATEGORIES:
            raise Unreadable(f"{code} has the category {category}; the categories are {', '.join(CATEGORIES)}",
                             number)
        if code in rows:
            raise Unreadable(f"{code} is listed twice (first on line {rows[code]['line']})", number)
        rows[code] = {"level": level, "platform": platform, "category": category, "line": number}
    if not rows:
        raise Unreadable("it lists no code")
    return rows


# ---------------------------------------------------------------------------------------------------
# The comparison.

def compare(catalogue, sdk):
    problems = []
    for code in sorted(set(sdk) | set(catalogue)):
        row, found = catalogue.get(code), sdk.get(code)
        if row is None:
            problems.append(f"{code} exists in the SDK ({swift_path}:{found['line']}), but {catalogue_path} does not "
                            "list it; add it with its level, platform and category")
            continue
        if row["platform"] not in IOS:
            if found is not None:
                problems.append(f"{code} exists in the SDK ({swift_path}:{found['line']}), but {catalogue_path} lists "
                                f"it for the Android SDK only (line {row['line']})")
            continue
        if found is None:
            listed = "both SDKs" if row["platform"] == "both" else "the iOS SDK only"
            problems.append(f"{catalogue_path} lists {code} for {listed} (line {row['line']}), but {swift_path} has no "
                            "such code")
            continue
        if found["level"] != row["level"]:
            problems.append(f"{code}: the SDK logs it at {found['level']} ({swift_path}:{found['level_line']}); "
                            f"{catalogue_path} says {row['level']} (line {row['line']})")
        if found["category"] != row["category"]:
            problems.append(f"{code}: the SDK gives it the category {found['category']} "
                            f"({swift_path}:{found['category_line']}); {catalogue_path} says {row['category']} "
                            f"(line {row['line']})")
    return problems


SOURCES = (
    (catalogue_path, read_catalogue, "each line holds a code, its level, its platform and its category"),
    (swift_path, read_swift, SWIFT_SHAPE),
)
read, unreadable = [], []
for path, reader, shape in SOURCES:
    try:
        with open(os.path.join(root, path), encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        unreadable.append(f"{path} does not exist")
        continue
    except (OSError, UnicodeDecodeError) as error:
        unreadable.append(f"cannot read {path}: {error}")
        continue
    try:
        read.append(reader(text))
    except Unreadable as error:
        unreadable.append(f"{path}:{error.line}: {error}" if error.line else f"{path}: {error}")
        if path == swift_path:
            unreadable.append(f"{path}: {shape}; if its shape changed on purpose, change "
                              "scripts/check-log-catalogue.sh with it")
if unreadable:
    for message in unreadable:
        print(f"{PROGRAM}: {message}", file=sys.stderr)
    print(f"{PROGRAM}: cannot compare the log codes; nothing may be merged or released until it can", file=sys.stderr)
    sys.exit(1)
catalogue, sdk = read
problems = compare(catalogue, sdk)
if problems:
    for problem in problems:
        print(f"{PROGRAM}: {problem}", file=sys.stderr)
    print(f"{PROGRAM}: {len(problems)} problem(s). A log code is stable API: add or change it in {swift_path}, the "
          f"catalogue of Tests/SallaPushTests/LogCatalogTests.swift and {catalogue_path} in the same pull request, "
          "then in the shared log catalogue (CONTRIBUTING.md, \"What needs care\").", file=sys.stderr)
    sys.exit(1)
counts = {platform: sum(1 for row in catalogue.values() if row["platform"] == platform) for platform in PLATFORMS}
print(f"{PROGRAM}: the SDK logs {len(sdk)} codes, each at the level and with the category of {catalogue_path} "
      f"({counts['both']} codes of both SDKs and {counts['ios']} of the iOS SDK only; {counts['android']} of the "
      "Android SDK only are not this SDK's)")
PY
