#!/usr/bin/env python3
"""Point a reviewer at the changes in a pull request that CI cannot judge.

Every check here verifies correctness, and a pull request written to look
correct passes all of them. What CI cannot tell is intent, so this script
names the changes where intent matters most: the workflows and release path,
the installer and updater, the privileged helpers, the gates themselves, the
instructions agents follow, binary files, and new executables. It never
fails the build; it prints a notice per item, as a GitHub annotation when it
runs in Actions, and a summary line either way.

Usage: review_notice.py <base-ref> [<head-ref>]   (head defaults to HEAD)
"""

from __future__ import annotations

import os
import re
import subprocess
import sys

# (pattern, reason) pairs; the first match names the reason for a path.
SENSITIVE = [
    (r"^\.github/", "workflow, CODEOWNERS or repository automation"),
    (r"^(install\.sh|mole)$", "installer or CLI router"),
    (r"^lib/manage/(update|remove)\.sh$", "self-update or self-removal"),
    (r"^(lib/core/sudo\.sh|bin/touchid\.sh)$", "privileged helper"),
    (r"^(Makefile|go\.mod|go\.sum|flake\.nix|package\.nix|overlay\.nix)$", "build or dependency input"),
    (r"^scripts/(check\.sh|test\.sh|audit_[^/]+|review_notice\.py|check_release_minos\.sh)$", "CI gate"),
    (r"^(\.gitleaks\.toml|\.shellcheckrc|\.golangci\.ya?ml)$", "scanner configuration"),
    (r"^(AGENTS\.md|CLAUDE\.md|llms\.txt)$", "agent instructions"),
    (r"^(\.claude|\.agents|skills|plugins)/", "agent instructions or published skill"),
]


def git(*args: str) -> str:
    return subprocess.run(
        ["git", *args], check=True, capture_output=True, text=True
    ).stdout


def classify(numstat: str, summary: str) -> list[tuple[str, str]]:
    notes: list[tuple[str, str]] = []
    seen: set[str] = set()
    for line in numstat.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        added, deleted, path = parts
        if added == "-" and deleted == "-":
            notes.append((path, "binary file"))
            seen.add(path)
            continue
        for pattern, reason in SENSITIVE:
            if re.search(pattern, path):
                notes.append((path, reason))
                seen.add(path)
                break
    for line in summary.splitlines():
        # " create mode 100755 <path>" or " mode change 100644 => 100755 <path>"
        match = re.match(r"\s*(?:create mode|mode change \d+ =>) 100755 (.+)$", line)
        if match and match.group(1) not in seen:
            notes.append((match.group(1), "new executable"))
    return notes


def main(argv: list[str]) -> int:
    if len(argv) not in (2, 3):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 0
    base = argv[1]
    head = argv[2] if len(argv) == 3 else "HEAD"
    try:
        # Renames are reported as a delete plus an add so every path is plain.
        numstat = git("diff", "--numstat", "--no-renames", base, head)
        summary = git("diff", "--summary", "--no-renames", base, head)
    except subprocess.CalledProcessError as error:
        print(f"review-notice: cannot diff {base}..{head}: {error.stderr.strip()}")
        return 0
    notes = classify(numstat, summary)
    in_actions = os.environ.get("GITHUB_ACTIONS") == "true"
    for path, reason in notes:
        if in_actions:
            print(f"::notice file={path},title=Review closely::{reason}")
        else:
            print(f"review closely: {path} ({reason})")
    print(f"review-notice: {len(notes)} item(s) need a closer human review")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
