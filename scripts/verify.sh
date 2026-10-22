#!/bin/bash
# Complete local verification. Unlike the lightweight scripts, missing tools
# are errors here; a successful run must include ShellCheck, Bats and Go.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

missing=()
for tool in git go golangci-lint shellcheck bats shfmt goimports python3 fd zip unzip; do
    command -v "$tool" > /dev/null 2>&1 || missing+=("$tool")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    printf 'Full verification requires missing tools: %s\n' "${missing[*]}" >&2
    printf 'Next action: run nix develop --command ./scripts/verify.sh (uses flake.lock).\n' >&2
    exit 1
fi

export TERM="${TERM:-xterm-256color}"
export MOLE_TEST_NO_AUTH=1
export MOLE_SKIP_FINDER_TESTS=1

go version
golangci-lint version
shellcheck --version
bats --version
shfmt --version

# Check formatting without modifying the checkout.
while IFS= read -r -d '' file; do
    shfmt -i 4 -ci -sr -d "$file"
done < <(git ls-files --cached --others --exclude-standard -z '*.sh' mole)
unformatted=$(goimports -l -local github.com/tw93/mole ./cmd ./internal)
if [[ -n "$unformatted" ]]; then
    printf 'Go formatting differs:\n%s\nNext action: run ./scripts/check.sh --format.\n' "$unformatted" >&2
    exit 1
fi

./scripts/check.sh --no-format
./scripts/test.sh
go test -race ./...
printf '\nFull verification passed (lint, Bats, Go, race).\n'
