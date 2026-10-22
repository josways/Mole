# Conductor cleanup (#1800)

`mo clean --dry-run` and `mo clean` report the occupied space of
`~/Conductor/workspaces` and `~/Conductor/archived-contexts` in Large files
when either directory reaches the existing 1 GiB reporting threshold. These
are review rows, not reclaimable-space promises or deletion candidates. They
use the existing bounded measurement pool; a timed-out measurement supplies
no total. A symlink at either reported directory is skipped.

Conductor's `~/Library/Caches/com.conductor.app` cache and its logs under
`~/Library/Logs` already use User essentials cleanup. Preview them with
`mo clean --dry-run`; protect either path through `mo clean --whitelist`.
No additional opt-in or Conductor-specific deletion path is needed.

The report in [#1800](https://github.com/tw93/Mole/issues/1800) measured 30 GB
of Conductor data, 274 MB of archived contexts, and 7 MB of cache on macOS 26
with Mole 1.62.0. These are reporter measurements, not a verified reclaimable
workspace total. The archived contexts in that sample fall below the report
threshold; inspect a smaller directory with `mo analyze ~/Conductor`.

Workspaces, archived contexts, `~/.conductor/projects`, settings,
`conductor.db` and its WAL/SHM, `conductor.db.bak`, `agent-binaries`, and `bin`
are retained. A backup is recovery data, and an empty project directory has
negligible measured value. Workspace removal remains a separate design that
needs real owner, Git, activity, and final deletion checks.

`tests/clean_conductor.bats` covers the report and runs the existing cleanup
against fixture caches/logs in preview, cleanup, and whitelist modes while
checking that the retained data stays intact.
