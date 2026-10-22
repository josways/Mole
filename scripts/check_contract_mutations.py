#!/usr/bin/env python3
"""Prove selected safety tests reject a controlled defect in an isolated copy.

Never edits the working checkout. A build/setup failure is not a killed mutant:
the selected test must first pass, then fail with its specific contract message.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
MUTATIONS = (
    (
        "protected path",
        "cmd/analyze/delete.go",
        "if isProtectedAnalyzeDeletePath(path) {",
        "if false {",
        "TestSharedDeletionContract",
        "Analyze accepted=true, want false",
    ),
    (
        "canceled publication",
        "cmd/analyze/scanner.go",
        None,
        None,
        "TestCanceledPublicationContract",
        "canceled publication committed:",
    ),
    (
        "log control bytes",
        "cmd/analyze/oplog.go",
        "case c < 0x20 || c == 0x7f:",
        "case false:",
        "TestSharedLogEscapingContract",
        "Shell/Go escape mismatch:",
    ),
)


def test(copy: Path, name: str) -> subprocess.CompletedProcess[str]:
    env = dict(os.environ, MOLE_TEST_NO_AUTH="1", MOLE_SKIP_FINDER_TESTS="1")
    return subprocess.run(
        ["go", "test", "./cmd/analyze", "-run", f"^{name}$", "-count=1"],
        cwd=copy, env=env, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=180, check=False,
    )


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="mole-contract-mutations-") as scratch:
        copy = Path(scratch)
        for directory in ("cmd", "internal", "lib"):
            shutil.copytree(ROOT / directory, copy / directory)
        shutil.copytree(ROOT / "tests/contracts", copy / "tests/contracts")
        for name in ("go.mod", "go.sum"):
            shutil.copy2(ROOT / name, copy / name)

        for label, filename, before, after, name, diagnostic in MUTATIONS:
            baseline = test(copy, name)
            if baseline.returncode != 0:
                raise SystemExit(f"Baseline failed for {label}:\n{baseline.stdout}")
            path = copy / filename
            original = path.read_text()
            if before is None:
                start = original.index("func (p *scanPublication) commit(")
                end = original.index("\nfunc (p *scanPublication) finish(", start)
                mutated = original[:start] + (
                    "func (p *scanPublication) commit(action func() error) error {\n"
                    "\treturn action()\n}\n"
                ) + original[end:]
            else:
                if original.count(before) != 1:
                    raise SystemExit(f"Mutation target is missing or ambiguous: {label}")
                mutated = original.replace(before, after, 1)
            try:
                path.write_text(mutated)
                result = test(copy, name)
            finally:
                path.write_text(original)
            if result.returncode == 0 or diagnostic not in result.stdout:
                raise SystemExit(f"Mutation not rejected by its contract ({label}):\n{result.stdout}")
            print(f"Killed mutation: {label}", flush=True)
    print(f"Contract mutation checks passed: {len(MUTATIONS)} / {len(MUTATIONS)}")


if __name__ == "__main__":
    main()
