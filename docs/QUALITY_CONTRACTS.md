# Quality contracts

These are implementation contracts for Mole CLI (macOS), not new cleanup
targets or a promise of feature parity with the other Mole products.
`AGENTS.md` and the area rules remain the safety policy owners.

## Deletion modules

Load shell operations through `lib/core/file_ops.sh`. Internal modules do not
initialize their own state or provide a second public deletion entry point.

| Responsibility | Owner / input | Output and failure behavior | Executable evidence |
| --- | --- | --- | --- |
| Path and owner policy | `file_ops_policy.sh`: `validate_path_for_deletion(path)` and tri-state probes | Zero accepts this observation; nonzero retains. Probe unknown never becomes absence. `_MOLE_VALIDATION_REASON` carries the fixed refusal reason. | `tests/core_safe_functions.bats`, `tests/path_validation_fuzz.bats` |
| Execution | `file_ops_remove.sh`: safe wrappers; `file_ops_trash.sh`: `mole_delete(path, needs_sudo, identity, digest, absent_path)` routing | Rebind required evidence at the sink; preserve timeout/signal statuses. Preview never mutates the target. Failed/refused paths do not count as reclaimed. | `tests/file_ops_mole_delete.bats`, `tests/file_ops_safe_remove_symlink.bats` |
| Trash | `file_ops_trash.sh`: single/batch movers with parent and target identities | No overwrite; immutable privileged staging; a failed move never authorizes permanent deletion. Stable invoking-user values may be shared, live ownership and destination safety may not. | `tests/user_file_ops.bats`, `tests/uninstall_remove_file_list.bats` |
| Bounded discovery/removal | `file_ops_find.sh`: root, exact pattern/type/age/depth and deadline | Complete producer output only; unknown/failed scans cannot authorize partial deletion. Execution keeps the same candidate predicates and safe sinks. | `tests/core_safe_functions.bats` |
| Sizing/accounting | `file_ops_size.sh`: path, deadline, strict/readable mode | Kilobytes on stdout; incomplete strict measurements fail. Only a real timeout marks cleanup totals partial. Sizing never grants deletion authority and is never cached by parent mtime. | `tests/file_ops_size.bats` |
| Forensic logging | `file_ops_log.sh`: mode, size, outcome, original path | One escaped TSV record; append failure warns once, without changing the removal outcome or actual action path. Operation/session logging remains in `log.sh`/`base.sh`. | `tests/history.bats`, `tests/file_ops_mole_delete.bats` |

All Shell operation functions were extracted without rewriting their bodies.
The facade preserves initialization and source order; policy observations and
Trash batch identities are still process-local, not shared across commands.

## Uninstall phases

`batch.sh` is the compatibility entry point and orchestrator. Phase functions
read and write its locals using Bash dynamic scope; they are not standalone
commands. Sourcing a phase must not scan, prompt, authorize or remove anything.

| Phase module | Inputs | Outputs / stop behavior |
| --- | --- | --- |
| `batch_plan.sh` | Selected apps, complete bounded inventory, current bundle metadata | `app_details`, classifications and estimates. Incomplete discovery retains uncertain leftovers; interruption prevents later phases. Inventory snapshots expire before confirmation. |
| `batch_preview.sh` | Filtered plan, user-data selections and estimates | Updated reviewed plan and confirmation. Status 0 continues; 2 cancels; 3 refuses missing terminal; 4 ends a noninteractive dry run; other failures abort. Authorization happens only after review. |
| `batch_execute.sh` | Confirmed plan, established sudo session, current ownership | Per-app completed-path ledger, successes/failures and retained reasons. Recheck identity and surviving owners; removal cancellation stops later work and keeps completed receipts. |
| `batch_summary.sh` | Completed outcomes and actually measured bytes | Terminal-safe summary. No rediscovery, authorization, sizing or deletion. |

Preview uses static protection. It must not initialize the memoized complete
lsof mode before the sudo gate. Execution uses the same filtered plan, then
rechecks live evidence. `tests/uninstall.bats`, `tests/brew_uninstall.bats`,
`tests/uninstall_safety.bats` and `tests/uninstall_remove_file_list.bats` cover
these transitions, including positive controls for later eligible candidates.

## User data layout and compatibility

`install.sh --config DIR` relocates installed **code and install receipts**
(`bin`, `lib`, version/channel metadata). It does not relocate user state.
Changing that meaning would require a separate migration decision.

| Class | Existing and current location | Resolution owner | Recovery / retention |
| --- | --- | --- | --- |
| User configuration | `~/.config/mole` | `lib/core/paths.sh`, `internal/userpaths` | Preserve whitelist and unknown preference keys. `whitelist_checks` remains the legacy optimize fallback; upgrade writes `whitelist_optimize` using the existing loader. An unreadable whitelist is not a missing whitelist. |
| Derived caches | `~/.cache/mole` | Same resolvers | Analyze owns only `analyzer/` and its explicitly named legacy files; retain unrelated shell cache entries. Schema, TTL, entry/byte caps and stale-temp cleanup remain enforced. Corrupt derived data can be rebuilt. |
| Audit and diagnostics | `~/Library/Logs/mole` | Same resolvers | Keep existing log format, rotation and `MO_NO_OPLOG` behavior. `mo remove` preserves this root. No new log purge policy. |

The compatibility layer resolves the same paths as previous versions, so no
directory is moved and no copy can shadow a newer file. It is pure and creates
nothing. `TestLegacyLayoutMatchesShell` checks literal spaces, Unicode and shell
metacharacters; `tests/core_paths.bats` checks invalid input and no side effects.
New/replaced Analyze cache payloads and Status preferences use mode 0600 because
they contain local paths or user choices. Existing directories and logs are not
recursively chmodded. Old state remains readable at its original location.

## Shell / Go boundary

Analyze keeps its Go Trash implementation. It does not invoke the Shell
deletion funnel, source user configuration, or acquire sudo for an ad hoc move.
`tests/contracts/deletion.tsv` is a shared **minimum** deny/accept corpus, read
by `TestSharedDeletionContract`, which executes both actual validators. A
positive row prevents a broken runner or reject-everything policy from passing.
`TestSharedLogEscapingContract` compares every representable non-NUL byte in
both implementations, including literal backslashes and invalid UTF-8.

Intentional differences must not be erased by making the corpus larger:

- Clean and uninstall use app ownership, whitelist and owner-process policies;
  Analyze permits user-selected ordinary files while retaining its critical
  roots, live VM state and endpoint-security exclusions.
- Shell rejects control-byte paths; Analyze can Trash a literal filename with
  such bytes and escapes them in logs. Neither passes them as shell source.
- Analyze protects its resolved home root explicitly; the Shell validator and
  command-level app/user policy have separate responsibilities, including for
  fixture homes outside `/Users`.
- Shell has bounded privileged staging; Analyze remains unprivileged.

`TestTrashFallbackBindsOriginalTarget` changes the leaf, parent or parent
symlink between transports. Unknown/changed identity stops fallback.
`TestTrashFallbackStopsAfterCancellation` and
`TestTrashBatchCancellationKeepsCompletedLedger` stop later transports/items
while keeping completed outcomes. No transport falls back to permanent delete.
Path-based external Trash APIs still do not provide an atomic transaction with
third-party writers; rechecking narrows the race but is not an ownership lease.

## Faults, concurrency and meaningful tests

Use test-owned directories and injected transports, not the real Trash or an
authorization prompt. Rename-failure cases retain existing destinations and
verify staging files are reclaimed. Existing cancellation tests cover a cache
writer waiting at publication, so cancellation cannot resurrect an invalidated
cache. `TestPublicationCancelJoinsConcurrentCommitters` exercises the shared
publication boundary under the race detector.

`scripts/check_contract_mutations.py` copies only required sources into a
temporary directory, proves the selected test passes, injects one defect, and
requires its specific assertion failure. Build errors and missing helpers do
not count as killed mutations. It covers protected-path acceptance, publication
after cancellation and unescaped log control bytes. Never mutate the checkout
or weaken the safety policy to make a mutant pass.

`FuzzCacheEntry` exercises the production gob/schema parser without filesystem
side effects. `FuzzCandidateOrdering` compares the bounded selection against an
independent full-sort oracle and reverses discovery order. Persisted failing
inputs belong in Go's `testdata/fuzz/<target>/` after triage.

## Performance receipts

`BenchmarkQualityScan` uses wide, deep and mixed synthetic trees with cache
reuse and Spotlight disabled. `BenchmarkQualityFirstListing` measures the
initial listing separately. Both report allocations; functional assertions
require the complete fixture to be seen. Existing cancellation tests and Shell
call-count/timing tests cover responsiveness and subprocess fan-out.

Run on the same machine/toolchain before and after an optimization:

```bash
MOLE_TEST_NO_AUTH=1 MOLE_SKIP_FINDER_TESTS=1 go test ./cmd/analyze -run '^$' -bench '^BenchmarkQuality' -benchmem -benchtime=3x -count=3
```

Extended Quality records these receipts without a hard hosted-runner timing
threshold. A synthetic baseline is not evidence of real-user reclaimable space.
Before retaining/removing a low-value cleanup rule on magnitude grounds, record
a read-only sampling plan and numeric reversal threshold in its owning area
record, then collect real-user structure and totals. No sample was collected by
this quality change, so no cleanup target was added or removed on that basis.

## Rule and compatibility retirement

For a new cleanup rule, record exact ownership evidence, rebuildability,
excluded siblings, active/unknown handling, dry-run/final-sink parity and its
regression test in the owning `.claude/rules` file. Do not add a generic rule
engine or a second deletion catalog just to hold these fields.

For a compatibility branch, record the supported platform/tool version, real
consumer, positive test and evidence needed to retire it. Before declaring a
Shell helper dead, inspect production and test callers plus `eval`, `declare -f`
and dynamic lookup. Re-run duplication and lint checks after removal. Neither
an old comment nor a low textual reference count proves dead code. The existing
monthly bundle drift audit remains the owner of new system bundle coverage;
`tests/app_protection_data.bats` independently checks data-only loading and
idempotence, while the existing safety tests verify pattern semantics.

## Verification entry points

`make verify` retains its fast existing meaning. `make verify-full` (or
`./scripts/verify.sh`) requires Go, golangci-lint, ShellCheck, Bats, formatters,
Python, fd and archive tools up front, then runs formatting checks, repository
audits, the full test runner and Go race detection. It refuses a missing tool
instead of reporting a partial check as complete. Use the locked Nix environment
with `nix develop --command ./scripts/verify.sh`; do not update `flake.lock`
merely to run checks. CI's Extended Quality runs race, bounded fuzzing, controlled
mutations and synthetic benchmarks. It does not publish or release anything.
