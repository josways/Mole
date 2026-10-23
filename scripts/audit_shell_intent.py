#!/usr/bin/env python3
"""Gate the shell constructs whose risk is intent, not correctness.

ShellCheck and the tests judge whether code works. They cannot tell whether
a new line runs data as code, talks to the network, or reaches for root, and
those are the lines a pull request built to pass every test would add. Three
rules, each failing with the file, line and what to do next:

eval
    Every executed `eval` either restores a state captured in the same file by
    `$(trap -p ...)` or `$(shopt -p ...)` (directly or through one plain
    copy), or carries a `# eval: <reason>` comment on its own line or on the
    comment line right above it, the convention the indirect reads by name
    already follow.

network
    `curl`, `wget`, `nc`, `ncat`, `telnet`, `ssh`, `scp`, `sftp` and `ftp` run
    only from the installer and the updater, and `/dev/tcp` / `/dev/udp`
    never appear.

privileged
    Direct `sudo`, `osascript` and `launchctl` calls are counted per file
    against PRIVILEGED_CEILING. AGENTS.md requires each one to have a
    MOLE_TEST_MODE / MOLE_TEST_NO_AUTH guard or a full mock in tests; a count
    above its ceiling, or a file without one, means a new call that a reviewer
    must check for that guard before raising the ceiling here. A count below
    the ceiling passes and asks for the ceiling to come down.

Quoted text and comments are ignored, so help text and log messages that name
these commands do not count.
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]

NETWORK_COMMANDS = ("curl", "wget", "nc", "ncat", "telnet", "ssh", "scp", "sftp", "ftp")
NETWORK_ALLOWED = {"install.sh", "lib/manage/update.sh"}

PRIVILEGED_COMMANDS = ("sudo", "osascript", "launchctl")
# Direct calls per file, as counted by this script. Raise a value only after
# confirming the new call is guarded for tests (AGENTS.md, Critical Safety
# Rules); lower it whenever a call goes away.
PRIVILEGED_CEILING: dict[tuple[str, str], int] = {
    ("bin/clean.sh", "sudo"): 1,
    ("bin/touchid.sh", "sudo"): 7,
    ("install.sh", "sudo"): 7,
    ("lib/clean/app_caches.sh", "osascript"): 2,
    ("lib/clean/apps.sh", "osascript"): 2,
    ("lib/clean/brew.sh", "sudo"): 1,
    ("lib/clean/dev.sh", "sudo"): 1,
    ("lib/core/app_protection.sh", "osascript"): 5,
    ("lib/core/app_protection.sh", "sudo"): 2,
    ("lib/core/file_ops.sh", "osascript"): 2,
    ("lib/core/file_ops.sh", "sudo"): 27,
    ("lib/core/log.sh", "sudo"): 1,
    ("lib/core/sudo.sh", "osascript"): 1,
    ("lib/core/sudo.sh", "sudo"): 14,
    ("lib/manage/remove.sh", "sudo"): 1,
    ("lib/manage/update.sh", "sudo"): 1,
    ("lib/optimize/tasks.sh", "osascript"): 1,
    ("lib/optimize/tasks.sh", "sudo"): 9,
    ("lib/uninstall/batch.sh", "launchctl"): 4,
    ("lib/uninstall/batch.sh", "osascript"): 1,
    ("lib/uninstall/batch.sh", "sudo"): 1,
    ("lib/uninstall/brew.sh", "sudo"): 1,
}

EVAL_WORD = re.compile(r"(?:^|[\s;&|(])eval(?=\s|$)")
EVAL_MARKER = re.compile(r"#\s*eval:\s+\S")
RESTORE_OPERAND = re.compile(r'eval\s+"\$\{?([A-Za-z_][A-Za-z_0-9]*)\}?"\s*(?:$|[;&|)])')
CAPTURE = re.compile(r'\$\(\s*(?:builtin\s+)?(?:trap|shopt)\s+-p\b')


def command_pattern(words: tuple[str, ...]) -> re.Pattern[str]:
    return re.compile(
        r"(?:^|[\s;&|(`])(?:command\s+|builtin\s+|exec\s+)?(?:/usr/bin/|/bin/|/usr/sbin/)?("
        + "|".join(re.escape(word) for word in words)
        + r")(?=\s|$|;|\))"
    )


NETWORK_PATTERN = command_pattern(NETWORK_COMMANDS)
PRIVILEGED_PATTERN = command_pattern(PRIVILEGED_COMMANDS)
DEV_SOCKET = re.compile(r"/dev/(?:tcp|udp)/")


def default_sources() -> list[Path]:
    sources = [PROJECT_ROOT / "mole", PROJECT_ROOT / "install.sh"]
    for directory in ("bin", "lib"):
        sources.extend((PROJECT_ROOT / directory).rglob("*.sh"))
    return sorted({path.resolve() for path in sources if path.is_file()})


def code_only(line: str) -> str:
    """Blank quoted text and drop an unquoted comment, keeping column positions.

    Command substitutions inside double quotes stay visible, because
    `"$(curl ...)"` runs curl. Single-quoted text is always inert.
    """
    out: list[str] = []
    single = double = escaped = False
    depth = 0
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            out.append(" " if single or (double and depth == 0) else char)
            continue
        if char == "\\" and not single:
            escaped = True
            out.append(" " if double and depth == 0 else char)
            continue
        if char == "'" and not double:
            single = not single
            out.append(" ")
            continue
        if single:
            out.append(" ")
            continue
        if char == '"':
            if depth == 0:
                double = not double
            out.append(" ")
            continue
        if double and char == "$" and line[index + 1 : index + 2] == "(":
            depth += 1
            out.append(char)
            continue
        if double and depth and char == ")":
            depth -= 1
            out.append(char)
            continue
        if double and depth == 0:
            out.append(" ")
            continue
        if char == "#" and (index == 0 or line[index - 1].isspace()):
            break
        out.append(char)
    return "".join(out)


def heredoc_lines(lines: list[str]) -> set[int]:
    """Line indexes inside a quoted heredoc body, which the shell never runs."""
    inside: set[int] = set()
    terminator = None
    for index, line in enumerate(lines):
        if terminator is not None:
            if line.strip() == terminator:
                terminator = None
            else:
                inside.add(index)
            continue
        match = re.search(r"<<-?\s*(['\"])([A-Za-z_][A-Za-z_0-9]*)\1", code_only_keep_quotes(line))
        if match:
            terminator = match.group(2)
    return inside


def code_only_keep_quotes(line: str) -> str:
    # A heredoc opener's quoted delimiter must survive, so only drop comments.
    single = double = False
    for index, char in enumerate(line):
        if char == "'" and not double:
            single = not single
        elif char == '"' and not single:
            double = not double
        elif char == "#" and not single and not double and (index == 0 or line[index - 1].isspace()):
            return line[:index]
    return line


def restore_sources(lines: list[str]) -> set[str]:
    """Names assigned from trap -p / shopt -p, plus plain copies of them."""
    captured: set[str] = set()
    copies: list[tuple[str, str]] = []
    for line in lines:
        for match in re.finditer(r"(?:^|[\s;(])(?:local\s+)?([A-Za-z_][A-Za-z_0-9]*)=(\S.*)", line):
            name, value = match.group(1), match.group(2)
            if CAPTURE.match(value.lstrip("\"'")) or CAPTURE.search(value[:40]):
                captured.add(name)
                continue
            plain = re.match(r'"?\$\{?([A-Za-z_][A-Za-z_0-9]*)\}?"?\s*(?:$|[;&|])', value)
            if plain:
                copies.append((name, plain.group(1)))
    for _ in range(3):
        for name, source in copies:
            if source in captured:
                captured.add(name)
    return captured


def inspect_file(path: Path, relative: str) -> tuple[list[tuple[int, str]], Counter[str]]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        return [(0, f"could not read source: {exc}")], Counter()

    findings: list[tuple[int, str]] = []
    privileged: Counter[str] = Counter()
    skip = heredoc_lines(lines)
    captured = restore_sources(lines)

    for index, line in enumerate(lines):
        if index in skip or line.lstrip().startswith("#"):
            continue
        code = code_only(line)
        number = index + 1

        if EVAL_WORD.search(code):
            marked = bool(EVAL_MARKER.search(line))
            if not marked and index > 0 and EVAL_MARKER.search(lines[index - 1]) and lines[index - 1].lstrip().startswith("#"):
                marked = True
            restore = RESTORE_OPERAND.search(line)
            if not marked and not (restore and restore.group(1) in captured):
                findings.append(
                    (number, "eval needs '# eval: <reason>' on its line or the comment line above, "
                             "or must restore a value captured by $(trap -p) / $(shopt -p)")
                )

        if DEV_SOCKET.search(line) and not line.lstrip().startswith("#"):
            findings.append((number, "/dev/tcp or /dev/udp opens a network socket; Mole does not do that from shell"))
        if relative not in NETWORK_ALLOWED:
            for match in NETWORK_PATTERN.finditer(code):
                findings.append(
                    (number, f"{match.group(1)} runs a network client outside install.sh and lib/manage/update.sh")
                )

        for match in PRIVILEGED_PATTERN.finditer(code):
            privileged[match.group(1)] += 1

    return findings, privileged


def main(argv: list[str]) -> int:
    sources = [Path(arg).resolve() for arg in argv] if argv else default_sources()
    check_ceiling = not argv
    findings: list[tuple[str, int, str]] = []
    lowered: list[str] = []
    seen: set[tuple[str, str]] = set()

    for source in sources:
        try:
            relative = str(source.relative_to(PROJECT_ROOT))
        except ValueError:
            relative = str(source)
        if not source.is_file():
            findings.append((relative, 0, "source file does not exist"))
            continue
        file_findings, privileged = inspect_file(source, relative)
        findings.extend((relative, line, message) for line, message in file_findings)
        for command, count in privileged.items():
            key = (relative, command)
            seen.add(key)
            ceiling = PRIVILEGED_CEILING.get(key, 0)
            if count > ceiling:
                findings.append(
                    (relative, 0,
                     f"{count} direct {command} call(s), ceiling {ceiling}: confirm each new call has a "
                     f"MOLE_TEST_MODE / MOLE_TEST_NO_AUTH guard or a full test mock, then update "
                     f"PRIVILEGED_CEILING in scripts/audit_shell_intent.py")
                )
            elif count < ceiling:
                lowered.append(f"{relative}: {command} {count} < ceiling {ceiling}")

    if check_ceiling:
        for key, ceiling in PRIVILEGED_CEILING.items():
            if key not in seen and ceiling:
                lowered.append(f"{key[0]}: {key[1]} 0 < ceiling {ceiling}")

    if findings:
        for relative, line, message in findings:
            print(f"{relative}:{line}: {message}")
        return 1

    for note in lowered:
        print(f"note: lower PRIVILEGED_CEILING for {note}")
    print(f"shell-intent-audit-ok files={len(sources)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
