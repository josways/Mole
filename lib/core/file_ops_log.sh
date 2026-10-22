#!/bin/bash
# Internal forensic-log module. Load through file_ops.sh.
# Log failure warns once and never changes the action path or removal outcome.

_mole_delete_log() {
    local mode="$1"
    local size_kb="$2"
    local status="$3"
    local target="$4"

    local log_file="${MOLE_DELETE_LOG:-$HOME/Library/Logs/mole/deletions.log}"
    local log_dir
    log_dir="${log_file%/*}"
    [[ "$log_dir" != "$log_file" ]] || log_dir="."

    # Surface log-write failures once per session. The deletions log is the
    # only audit trail for Trash-routed removals; silently no-oping when the
    # log dir is unwritable (root-owned from prior sudo, ENOSPC, read-only
    # volume) defeats the design.
    if [[ ! -d "$log_dir" ]] && ! mkdir -p "$log_dir" 2> /dev/null; then
        _mole_warn_log_broken "create directory: $log_dir"
        return 0
    fi

    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z' 2> /dev/null || echo "unknown")

    _mole_escape_log_value mode "$mode"
    _mole_escape_log_value size_kb "$size_kb"
    _mole_escape_log_value status "$status"
    _mole_escape_log_value target "$target"
    local row
    printf -v row '%s\t%s\t%s\t%s\t%s' "$ts" "$mode" "$size_kb" "$status" "$target"
    _mole_write_audit_log "$log_file" 0 "$row" ||
        _mole_warn_log_broken "write to: $log_file"
}
