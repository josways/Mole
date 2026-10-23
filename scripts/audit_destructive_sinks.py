#!/usr/bin/env python3
"""Require an explicit safety justification on raw deletion commands.

Covered sinks: every `rm` in command position, recursive or not (a
single-file `rm -f` on a path Mole did not create bypasses Trash routing and
path protection as surely as `rm -rf`, and AGENTS.md already asks
self-created mktemp files to carry the annotation), `find -delete`,
`defaults delete`, and a sqlite3 call whose statement deletes or rewrites
rows (DELETE FROM, DROP, VACUUM). Each needs `# SAFE: <one-sentence reason>`
on one of its physical lines; a continued command may carry it on its last
line. `rm` as an argument (`bun pm cache rm`) or a name lookup
(`declare -F rm`) is not a call and is skipped.
"""

from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SAFE_MARKER = re.compile(r"\s#\s*SAFE:\s+\S")
RM_COMMAND = re.compile(r"(?<![A-Za-z0-9_])(?:(?:/usr)?/bin/)?r\\?m(?=\s)")
FIND_DELETE = re.compile(r"(?:^|\s)-delete(?=\s|[;&|)]|$)")
DEFAULTS_DELETE = re.compile(r"(?<![A-Za-z0-9_-])defaults\s+(?:-currentHost\s+)?delete(?=\s|$)")
SQLITE_COMMAND = re.compile(r"(?<![A-Za-z0-9_-])sqlite3(?=\s)")
SQL_DESTRUCTIVE = re.compile(r"\b(?:DELETE\s+FROM|DROP\s+(?:TABLE|INDEX|VIEW)|VACUUM)\b", re.IGNORECASE)
OUTPUT_ONLY_PREFIXES = ("echo ", "echo\t", "printf ", "printf\t", "log_")
# Words that still leave the next word in command position.
COMMAND_PREFIXES = {
    "sudo", "command", "exec", "xargs", "-exec", "-execdir", "then", "do", "else",
    "elif", "if", "while", "until", "!", "env", "nice", "time", "run_with_timeout",
}


def default_sources() -> list[Path]:
    sources = [PROJECT_ROOT / "mole", PROJECT_ROOT / "install.sh"]
    for directory in ("bin", "lib", "scripts"):
        sources.extend((PROJECT_ROOT / directory).rglob("*.sh"))
    return sorted({path.resolve() for path in sources if path.is_file()})


def shell_words(fragment: str) -> list[str]:
    try:
        lexer = shlex.shlex(fragment, posix=True, punctuation_chars=";&|")
        lexer.whitespace_split = True
        lexer.commenters = "#"
        return list(lexer)
    except ValueError:
        # A malformed or multi-line quoting context is still inspected by the
        # conservative token fallback rather than disappearing from the gate.
        return fragment.split()


def is_output_only_reference(command: str, match_start: int) -> bool:
    prefix = command[:match_start].lstrip()
    if not prefix.startswith(OUTPUT_ONLY_PREFIXES):
        return False
    # A command separator before the sink means the output helper finished and
    # the later rm/find is executable code, not prose inside its argument.
    return re.search(r"(?:;|&&|\|\||\||\$\()", prefix) is None


def has_recursive_force_rm(command: str) -> bool:
    for match in RM_COMMAND.finditer(command):
        if is_output_only_reference(command, match.start()):
            continue
        flags: set[str] = set()
        for token in shell_words(command[match.end() :]):
            if token in {";", "&&", "||", "|"}:
                break
            if token == "--":
                continue
            if token == "--force":
                flags.add("f")
                continue
            if token == "--recursive":
                flags.add("r")
                continue
            if token.startswith("-") and not token.startswith("--"):
                flags.update(token[1:])
                continue
            # Redirections can appear after the target. They do not change the
            # rm option set, but the first ordinary argv ends option parsing.
            if token[:1].isdigit() and ">" in token:
                continue
            # rm option parsing remains active until an explicit `--`; an
            # option-looking token after another operand is still dangerous.
            continue
        if "r" in flags or "R" in flags:
            return True
    return False


def rm_in_command_position(command: str, match_start: int) -> bool:
    prefix = command[:match_start].rstrip()
    segment = re.split(r"(?:;|&&|\|\||\||\$\(|\bthen\b|\bdo\b)", prefix)[-1].split()
    while segment and segment[0] in {"if", "elif", "while", "until", "!", "else"}:
        segment = segment[1:]
    # `declare -F rm`, `command -v rm`: a lookup of the name, not a call.
    if segment and (segment[0] in {"declare", "typeset", "type", "unset", "hash", "alias", "unalias"}
                    or segment[:2] == ["command", "-v"]):
        return False
    if not prefix or prefix[-1] in ";&|({`":
        return True
    if prefix.endswith("$("):
        return True
    previous = prefix.split()[-1]
    if previous in COMMAND_PREFIXES or previous.startswith(("-", "$", '"$', "'")):
        return True
    # `bun pm cache rm`: rm is an argument of another command.
    return False


def has_any_rm(command: str) -> bool:
    return any(
        not is_output_only_reference(command, match.start())
        and rm_in_command_position(command, match.start())
        for match in RM_COMMAND.finditer(command)
    )


def has_defaults_delete(command: str) -> bool:
    return any(
        not is_output_only_reference(command, match.start())
        for match in DEFAULTS_DELETE.finditer(command)
    )


def has_destructive_sqlite(command: str) -> bool:
    return bool(SQL_DESTRUCTIVE.search(command)) and any(
        not is_output_only_reference(command, match.start())
        for match in SQLITE_COMMAND.finditer(command)
    )


def has_find_delete(command: str) -> bool:
    return any(
        not is_output_only_reference(command, match.start())
        for match in FIND_DELETE.finditer(command)
    )


def has_unquoted_comment(line: str) -> bool:
    single_quoted = False
    double_quoted = False
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\" and not single_quoted:
            escaped = True
            continue
        if char == "'" and not double_quoted:
            single_quoted = not single_quoted
            continue
        if char == '"' and not single_quoted:
            double_quoted = not double_quoted
            continue
        if (
            char == "#"
            and not single_quoted
            and not double_quoted
            and (index == 0 or line[index - 1].isspace())
        ):
            return True
    return False


def logical_blocks(lines: list[str]) -> list[tuple[int, str, list[str]]]:
    blocks: list[tuple[int, str, list[str]]] = []
    start = 1
    physical: list[str] = []
    joined: list[str] = []
    for line_number, line in enumerate(lines, start=1):
        if not physical:
            start = line_number
        physical.append(line)
        stripped = line.rstrip()
        if stripped.endswith("\\") and not has_unquoted_comment(stripped):
            joined.append(stripped[:-1])
            continue
        joined.append(line)
        blocks.append((start, " ".join(joined), list(physical)))
        physical.clear()
        joined.clear()
    if physical:
        blocks.append((start, " ".join(joined), list(physical)))
    return blocks


def inspect_file(path: Path) -> list[tuple[int, str]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        return [(0, f"could not read source: {exc}")]

    findings: list[tuple[int, str]] = []
    for line_number, command, physical_lines in logical_blocks(lines):
        stripped = command.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        recursive_rm = has_recursive_force_rm(command)
        any_rm = recursive_rm or has_any_rm(command)
        find_delete = has_find_delete(command)
        defaults_delete = has_defaults_delete(command)
        sqlite_delete = has_destructive_sqlite(command)
        if not (any_rm or find_delete or defaults_delete or sqlite_delete):
            continue
        if any_rm:
            annotated = any(
                RM_COMMAND.search(line) and SAFE_MARKER.search(line)
                for line in physical_lines
            ) or (len(physical_lines) > 1 and bool(SAFE_MARKER.search(physical_lines[-1])))
            kind = "raw recursive rm" if recursive_rm else "raw rm"
        elif find_delete:
            annotated = any(
                FIND_DELETE.search(line) and SAFE_MARKER.search(line)
                for line in physical_lines
            )
            kind = "raw find -delete"
        else:
            # A continued sqlite3 call cannot carry a comment before its
            # backslash, so the marker may sit on any line of the command.
            annotated = any(SAFE_MARKER.search(line) for line in physical_lines)
            kind = "defaults delete" if defaults_delete else "sqlite3 DELETE/DROP/VACUUM"
        if annotated:
            continue
        findings.append(
            (line_number, f"{kind} requires '# SAFE: <one-sentence reason>'")
        )
    return findings


def main(argv: list[str]) -> int:
    sources = [Path(arg).resolve() for arg in argv] if argv else default_sources()
    findings: list[tuple[Path, int, str]] = []
    for source in sources:
        if not source.is_file():
            findings.append((source, 0, "source file does not exist"))
            continue
        findings.extend((source, line, message) for line, message in inspect_file(source))

    if findings:
        for source, line, message in findings:
            print(f"{source}:{line}: {message}")
        return 1

    print(f"destructive-sink-audit-ok files={len(sources)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
