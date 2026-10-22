#!/bin/bash
# Internal sizing/accounting module. Load through file_ops.sh.
# Contracts and failure modes: docs/QUALITY_CONTRACTS.md.

# ============================================================================
# Size Calculation
# ============================================================================

# Get path size in KB (returns 0 if not found)
#
# For regular files and symlinks, prefer allocated blocks from 'stat' over
# 'du': it avoids the fork+pipe cost of 'du | awk' on every call, which adds
# up in tight loops (e.g. external-volume ._* sweeps, Application Support log
# scans). macOS st_blocks and 'du -skP' use the same 512-byte allocation basis
# without following symlinks. Directories still go through 'du' because 'stat'
# only reports a single directory entry, not recursive content size. .app
# bundles use Spotlight's physical size when available so uninstall previews
# do not add logical bundle bytes to physical leftover sizes.
#
# Optional third argument "readable": du exits 1 when it cannot list some
# directory, after printing the total of everything it could read. Uninstall
# needs a complete size (#1404), so by default that is a failure. A cleanup
# total passes "readable" and takes the readable bytes: a directory the user
# cannot list cannot be removed by Mole either, so those bytes are exactly what
# the cleanup can free, and dropping them counted the whole item as 0.
get_path_size_kb() {
    local path="$1"
    local size_timeout="${2:-$MOLE_TIMEOUT_DISK_VERIFY_SEC}"
    local size_mode="${3:-}"
    [[ -z "$path" || ! -e "$path" ]] && {
        echo "0"
        return
    }

    if [[ ! "$size_timeout" =~ ^[0-9]+(\.[0-9]+)?$ || "$size_timeout" =~ ^0+(\.0+)?$ ]]; then
        size_timeout="$MOLE_TIMEOUT_DISK_VERIFY_SEC"
    fi
    local timeout_whole="${size_timeout%%.*}"
    local timeout_budget=$((10#$timeout_whole))
    if [[ "$size_timeout" == *.* && "${size_timeout#*.}" =~ [1-9] ]]; then
        timeout_budget=$((timeout_budget + 1))
    fi
    [[ $timeout_budget -gt 0 ]] || timeout_budget=1
    local size_deadline=$((SECONDS + timeout_budget))

    # Uninstall totals represent estimated disk occupancy. Keep .app bundles
    # on the same physical-size basis as the directory fallback; logical size
    # can be much larger for APFS-cloned bundles and must not be mixed into the
    # same total as `du` results (#1404).
    if [[ "$path" == *.[aA][pP][pP] || "$path" == *.[aA][pP][pP]/ ]]; then
        local mdls_size
        local mdls_timeout=""
        local mdls_deadline_rc=0
        mdls_timeout=$(_mole_timeout_with_deadline \
            "$size_timeout" "$size_deadline") || mdls_deadline_rc=$?
        [[ $mdls_deadline_rc -eq 0 ]] || return "$mdls_deadline_rc"
        local mdls_rc=0
        mdls_size=$(run_with_timeout "$mdls_timeout" mdls \
            -name kMDItemPhysicalSize -raw "$path" < /dev/null 2> /dev/null) || mdls_rc=$?
        mole_rc_timeout_or_signal "$mdls_rc" && return "$mdls_rc"
        if [[ "$mdls_size" =~ ^[0-9]+$ && "$mdls_size" -gt 0 ]]; then
            echo $(((mdls_size + 1023) / 1024))
            return
        fi
    fi

    # Fast path for regular files and symlinks: st_blocks is measured in
    # 512-byte units and matches the physical basis of `du -skP`.
    if [[ -f "$path" || -L "$path" ]]; then
        local blocks
        local stat_timeout=""
        local stat_deadline_rc=0
        stat_timeout=$(_mole_timeout_with_deadline \
            "$size_timeout" "$size_deadline") || stat_deadline_rc=$?
        [[ $stat_deadline_rc -eq 0 ]] || return "$stat_deadline_rc"
        local stat_rc=0
        blocks=$(run_with_timeout "$stat_timeout" "$STAT_BSD" \
            -f%b "$path" < /dev/null 2> /dev/null) || stat_rc=$?
        mole_rc_timeout_or_signal "$stat_rc" && return "$stat_rc"
        if [[ "$blocks" =~ ^[0-9]+$ ]]; then
            echo $(((blocks + 1) / 2))
            return
        fi
    fi

    # Bounded like every other du call site (hints/project/caches): an
    # unbounded walk here wedges one parallel sizing worker forever on a
    # stalled SMB/FUSE mount. A timeout is cancellation, not a zero-byte
    # measurement, because callers may feed the result into a deletion plan.
    local size
    local du_timeout=""
    local du_deadline_rc=0
    du_timeout=$(_mole_timeout_with_deadline \
        "$size_timeout" "$size_deadline") || du_deadline_rc=$?
    [[ $du_deadline_rc -eq 0 ]] || return "$du_deadline_rc"
    local du_rc=0
    size=$(run_with_timeout "$du_timeout" du -skP "$path" 2> /dev/null |
        awk 'NR==1 {print $1; exit}') || du_rc=$?
    # `du` may print a partial aggregate before reporting an unreadable child.
    # Any nonzero status makes that number incomplete, so never return it as a
    # successful size estimate (#1404), unless the caller asked for readable
    # bytes (see above).
    if mole_rc_timeout "$du_rc" && declare -F debug_log > /dev/null; then
        debug_log "Size check timed out after ${size_timeout}s: $path"
    fi
    if [[ $du_rc -eq 1 && "$size_mode" == "readable" && "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
        return 0
    fi
    [[ $du_rc -eq 0 ]] || return "$du_rc"

    if [[ "$size" =~ ^[0-9]+$ ]]; then
        echo "$size"
    else
        [[ "${MO_DEBUG:-}" == "1" ]] && debug_log "get_path_size_kb: Failed to get size for $path (returned: $size)"
        echo "0"
    fi
}

# Add one reported cleanup row to the run totals: its item count, its KB, and
# one category. Every section that prints its own result row goes through
# here, so non-numeric input counts as zero instead of arithmetic on a name.
# Dry-run totals are rebuilt from the preview ledger at the end of the run.
mole_add_cleaned_row() {
    local count="${1:-0}" size_kb="${2:-0}"
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
    files_cleaned=$((${files_cleaned:-0} + count))
    total_size_cleaned=$((${total_size_cleaned:-0} + size_kb))
    total_items=$((${total_items:-0} + 1))
}

# Classify a per-item get_path_size_kb status for a caller whose size only
# feeds totals (bugs reference, section 15). Callers measure with "readable",
# so an unlistable directory already arrives as its readable bytes. A timeout
# leaves the item eligible with an unknown size and marks the freed total
# partial; any other failure (the item vanished) leaves nothing to free and no
# mark; a signal records the cancellation and returns its status so the caller
# stops.
mole_item_size_continues() {
    local rc="${1:-0}"
    [[ $rc -eq 0 ]] && return 0
    if [[ $rc -ge 128 ]]; then
        _mole_record_clean_cancellation "$rc"
        return "$rc"
    fi
    if mole_rc_timeout "$rc"; then
        MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
    fi
    return 0
}

# Calculate total size for multiple paths
calculate_total_size() {
    local files="$1"
    local total_kb=0 file
    local -a unique_paths=()
    while IFS= read -r file; do
        [[ -z "$file" || ! -e "$file" ]] || unique_paths+=("$file")
    done <<< "$files"
    local filtered=""
    filtered=$(mole_filter_nested_paths "${unique_paths[@]+"${unique_paths[@]}"}") || return $?
    unique_paths=()
    while IFS= read -r file; do
        [[ -z "$file" ]] || unique_paths+=("$file")
    done <<< "$filtered"

    for file in "${unique_paths[@]+"${unique_paths[@]}"}"; do
        local size_kb=0
        local size_rc=0
        size_kb=$(get_path_size_kb "$file") || size_rc=$?
        mole_rc_timeout_or_signal "$size_rc" && return "$size_rc"
        [[ $size_rc -eq 0 && "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        total_kb=$((total_kb + size_kb))
    done

    echo "$total_kb"
}
