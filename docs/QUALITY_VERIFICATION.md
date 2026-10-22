# Quality improvement verification

Date: 2026-10-22. Product: Mole CLI (macOS).
Branch: `quality-contracts-and-verification`.
Starting source: `6869656411b2952d2b6f0805ace28ecfa3827deb` (clean `main`).
No version, release, public reply or cross-product synchronization is included.

## Delivered scope

| Improvement | Implementation / receipt owner |
| --- | --- |
| Verifiable module contracts | `QUALITY_CONTRACTS.md`; six internal `file_ops_*.sh` modules and four uninstall phase modules, retaining the public load points |
| Config and user-data convention | Pure Shell/Go user-path resolvers; legacy locations and optimize whitelist upgrade behavior retained |
| Shell/Go interface | Shared path corpus, exhaustive representable-byte log comparison and explicit intentional differences |
| Test maintenance | Cache tests moved out of `analyze_test.go`; production cache decoder and independent candidate-sort fuzz oracle |
| Reliable complete checks | `make verify-full`, required-tool preflight, locked Nix environment, bounded Extended Quality workflow |
| Protection data vs. behavior | Independent data loading/idempotence test; existing protection pattern tests retained |
| Changed-target safety | Trash fallback rebinds the original leaf and physical parent; changed/unknown evidence retains the target |
| Fault injection | Target/parent/symlink replacement, timeout/cancellation, failed atomic rename and retained staging/destination assertions |
| Concurrency | Go race job, concurrent publication contract and existing cache-cancellation lifecycle tests |
| Performance | Wide/deep/mixed full-scan and initial-listing benchmarks with allocation receipts |
| Obsolete/duplicate logic | Existing staticcheck unused, ShellCheck and normalized-body audit run; retirement evidence defined, no unproved Shell deletion |
| Cleanup rule value | Evidence and numeric sampling-threshold requirement codified in the owning rule workflow; no target added/removed without real-user samples |
| Persistence privacy | New/replaced Analyze payloads and Status preferences are 0600; existing logs and data paths retained |
| Test effectiveness | Three controlled mutants require a passing baseline and their specific failing contract assertion in an isolated source copy |

See `QUALITY_CONTRACTS.md` for the contracts, commands and specific test owners.

## Verification receipts

- Shell extraction comparison: all 71 functions from the original file-ops
  facade and all 54 functions from the original uninstall batch file have
  byte-identical bodies after moving. Top-level state initialization order is
  retained; public symbols still load through the original facades.
- Red/green: changed leaf, parent and symlink fallback tests and cancellation
  fallback tests failed against the original routing behavior, then passed with
  identity rebinding and typed timeout propagation.
- Red/green: cache/preference privacy assertions failed at the original 0644
  mode and passed at 0600. Failed-rename tests retain the destination and leave
  no staging files.
- `./scripts/check.sh --format` passed. Repository lint/audits passed with
  golangci-lint reporting zero issues. The first complete Bats/Go/integration
  run ended with the runner's `All tests passed!` summary.
- `go test -race ./...` passed for all four packages.
- `FuzzValidatePath`, `FuzzCacheEntry`, `FuzzCandidateOrdering` each passed a
  20-second run with two workers. These are bounded local runs, not exhaustive
  proofs.
- Controlled mutations: 3 / 3 rejected (protected path, canceled publication,
  unescaped log controls). The script first verified each unmodified test.
- Missing-tool control: invoking `verify.sh` with only system tools returned 1
  before running checks, named the missing tools and supplied the locked-Nix
  recovery command.
- Final `./scripts/verify.sh` after all module moves returned 0, ending with
  `Full verification passed (lint, Bats, Go, race).` Its full test runner ended
  with `All tests passed!`; the final race run passed for all four packages.

Toolchain used locally: Go 1.26.0, golangci-lint 2.12.2, goimports 0.49.0,
shfmt 3.13.1, ShellCheck 0.11.0, Bats 1.12.0, fd 10.3.0 and GNU parallel
20250922. Tools were first prepared under a task-owned temporary directory,
then installed into the user's versioned `~/.local/share/mole-dev-tools/`
directory with command links in `~/.local/bin`. The Go archive matched the
official download manifest's SHA256. No existing command was overwritten.

## Synthetic baseline

Apple M5 / darwin arm64 / Go 1.26.0; three repetitions at three iterations each.
These establish an initial local baseline, not a before/after speedup claim.

| Workload | Observed time/op range | Allocated bytes/op range |
| --- | --- | --- |
| Wide tree, 128 files | 1.62–2.38 ms | 148,485–148,672 |
| Deep tree, 128 files | 9.15–9.36 ms | 328,069–335,962 |
| Mixed tree, 128 files | 3.27–4.31 ms | 223,989–230,938 |
| Initial listing, 256 files | 2.40–3.64 ms | 201,738 |

## Limits

Real Finder/authorization behavior was disabled during automated verification;
Trash tests use isolated files and injected or direct filesystem transports.
The external path-based Trash APIs still have a residual check-to-action
window. The changes do not claim a transaction with another process modifying
the filesystem. No real-user cleanup-space sample or published package/feed
verification was performed, and no cleanup rule was removed on local magnitude
alone. Extended Quality is configured here; its remote CI results are not yet
verified by this local receipt.
