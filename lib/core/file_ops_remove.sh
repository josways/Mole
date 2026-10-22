#!/bin/bash
# Internal deletion module. Load through file_ops.sh; do not initialize independently.
# Inputs, outcomes and failure behavior: docs/QUALITY_CONTRACTS.md.

# ============================================================================
# Safe Removal Operations
# ============================================================================

_record_file_ops_dry_run_target() {
    local path="$1"
    local precomputed_size_kb="${2:-}"

    declare -f record_dry_run_cleanup_target > /dev/null 2>&1 || return 0

    local size_kb=0
    local size_known=true
    local eligibility_still_current=true
    if [[ -n "$precomputed_size_kb" && "$precomputed_size_kb" =~ ^[0-9]+$ ]]; then
        size_kb="$precomputed_size_kb"
    elif [[ "$precomputed_size_kb" == "unknown" ]]; then
        # The caller cannot infer reclaimable bytes from allocated blocks
        # (for example APFS code-signature clones). Keep the preview partial.
        size_known=false
        eligibility_still_current=false
    else
        eligibility_still_current=false
        local measured_size=""
        local measure_rc=0
        measured_size=$(get_path_size_kb "$path" "" readable 2> /dev/null) || measure_rc=$?
        if [[ $measure_rc -ge 128 ]]; then
            return "$measure_rc"
        fi
        if mole_rc_timeout "$measure_rc"; then
            # Sizing budget exhausted: preview the item as size-unknown rather
            # than cancelling the whole dry run.
            MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
        fi
        if [[ $measure_rc -eq 0 && "$measured_size" =~ ^[0-9]+$ ]]; then
            size_kb="$measured_size"
        else
            size_known=false
        fi
    fi

    # A browser can reopen a partial download while the size probe runs. Keep
    # dry-run eligibility aligned with the real final sink instead of listing a
    # file that real cleanup would now refuse.
    if _mole_is_incomplete_download_path "$path"; then
        local download_open_state=0
        _mole_paths_have_open_handle "$path" || download_open_state=$?
        if mole_rc_timeout_or_signal "$download_open_state"; then
            return "$download_open_state"
        fi
        [[ $download_open_state -eq 1 ]] || return 1
    fi

    # A precomputed size means validate_path_for_deletion was the last
    # meaningful probe. If this helper measured after validation, rerun the
    # recorder guards: an owner can open the cache while du is walking it.
    local _MOLE_DRY_RUN_TARGET_PREVALIDATED="$eligibility_still_current"
    local record_rc=0
    record_dry_run_cleanup_target \
        "$path" "$size_kb" 1 "$size_known" || record_rc=$?
    return "$record_rc"
}

# Preserve the first timeout or signal observed by a clean deletion sink. Some
# older cleanup families intentionally treat ordinary item failures as
# best-effort; this sticky status prevents those `|| true` paths from turning a
# user interrupt into permission to continue deleting later targets. An
# optional label names what was running; see _mole_note_clean_cancel_source.
_mole_record_clean_cancellation() {
    local status="$1"
    local source="${2:-}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$status"; then
        local existing="${MOLE_CLEAN_CANCEL_STATUS:-0}"
        if ! mole_rc_timeout_or_signal "$existing"; then
            MOLE_CLEAN_CANCEL_STATUS=$status
            export MOLE_CLEAN_CANCEL_STATUS
        fi
        _mole_note_clean_cancel_source "$source"
    fi
}

# Name what a clean cancellation came from, so the summary and mole.log can say
# what timed out instead of only the exit status. A cancellation unwinds from
# the innermost caller outward, so the first label wins and the step runners
# only fill the gap when nothing deeper knew a better name.
_mole_note_clean_cancel_source() {
    local source="${1:-}"
    [[ -n "$source" && -z "${MOLE_CLEAN_CANCEL_SOURCE:-}" ]] || return 0
    MOLE_CLEAN_CANCEL_SOURCE="$source"
    export MOLE_CLEAN_CANCEL_SOURCE
}

# Safe wrapper around rm -rf with validation
safe_remove() {
    local path="$1"
    local silent="${2:-false}"
    local precomputed_size_kb="${3:-}"
    local deadline_seconds="${4:-}"
    local expected_parent="${5:-}"
    local expected_parent_id="${6:-}"
    local expected_target_id="${7:-}"
    local expected_file_sha256="${8:-}"
    local expected_absent_path="${9:-}"
    local _MOLE_DEFER_CONTAINER_HANDLE_PROBE=false
    local container_probe_parent=""
    local container_probe_parent_id=""
    local container_probe_target_id=""
    local exact_probe_parent=""
    local exact_probe_parent_id=""
    local exact_probe_target_id=""

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi

    # Validate path. Silent cleanup callers still need the same policy result,
    # but should not print one validation warning per skipped cache item.
    # Real cleanup performs its recursive container-handle probe once at the
    # final sink below. A dry-run with no precomputed size likewise defers that
    # one expensive probe until after sizing, where the preview recorder runs
    # the complete eligibility pass. Pre-sized dry-runs probe here once.
    local dry_run_sizes_before_preview=false
    if [[ "${MOLE_DRY_RUN:-0}" == "1" &&
        (! "$precomputed_size_kb" =~ ^[0-9]+$) ]] &&
        declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
        dry_run_sizes_before_preview=true
    fi
    if [[ "${MOLE_DRY_RUN:-0}" != "1" || "$dry_run_sizes_before_preview" == "true" ]]; then
        _MOLE_DEFER_CONTAINER_HANDLE_PROBE=true
    fi
    local validation_rc=0
    if [[ "$silent" == "true" ]]; then
        validate_path_for_deletion "$path" 2> /dev/null || validation_rc=$?
    else
        validate_path_for_deletion "$path" || validation_rc=$?
    fi
    if [[ $validation_rc -ne 0 ]]; then
        if mole_rc_timeout_or_signal "$validation_rc"; then
            _mole_record_clean_cancellation "$validation_rc"
            return "$validation_rc"
        fi
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "${_MOLE_VALIDATION_REASON:-protected}"
        return 1
    fi
    _MOLE_DEFER_CONTAINER_HANDLE_PROBE=false

    # Honor the user whitelist here, not just in safe_clean. safe_remove is
    # called directly by several clean/optimize flows (Xcode DerivedData,
    # mail downloads, deep-system caches, broken LaunchAgents) that would
    # otherwise ignore a user's whitelist selection. is_path_whitelisted is
    # a no-op when the whitelist is empty, and uninstall does not route
    # through safe_remove, so this stays scoped to clean/optimize. See #710.
    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$path"; then
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "whitelist"
        return 1
    fi

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        return 0
    fi

    # Keep preview eligibility identical to real cleanup. This first check
    # rejects an already-present compiled model cache before the dry-run return;
    # the final-sink check below still catches one created during size probing.
    if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$path" 2> /dev/null; then
        debug_log "Skipped removal for compiled model cache: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "compiled model cache"
        return 1
    fi

    # Dry-run mode: log but don't delete
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        local dry_record_rc=0
        _record_file_ops_dry_run_target \
            "$path" "$precomputed_size_kb" || dry_record_rc=$?
        if mole_rc_timeout_or_signal "$dry_record_rc"; then
            _mole_record_clean_cancellation "$dry_record_rc"
            return "$dry_record_rc"
        fi
        [[ $dry_record_rc -eq 0 ]] || return "$dry_record_rc"
        if [[ "${MO_DEBUG:-}" == "1" ]]; then
            local file_type="file"
            [[ -d "$path" ]] && file_type="directory"
            [[ -L "$path" ]] && file_type="symlink"

            local file_size=""
            local file_age=""

            if [[ -e "$path" ]]; then
                local size_kb=0
                if [[ -n "$precomputed_size_kb" ]]; then
                    if [[ "$precomputed_size_kb" =~ ^[0-9]+$ ]]; then
                        size_kb="$precomputed_size_kb"
                    fi
                else
                    local size_rc=0
                    size_kb=$(get_path_size_kb "$path" "" readable 2> /dev/null) || size_rc=$?
                    if mole_rc_timeout_or_signal "$size_rc"; then
                        _mole_record_clean_cancellation "$size_rc"
                        return "$size_rc"
                    fi
                    [[ $size_rc -eq 0 ]] || size_kb=0
                fi
                if [[ "$size_kb" -gt 0 ]]; then
                    file_size=$(bytes_to_human "$((size_kb * 1024))")
                fi

                if [[ -f "$path" || -d "$path" ]] && ! [[ -L "$path" ]]; then
                    local mod_time=0
                    local stat_rc=0
                    mod_time=$("$STAT_BSD" -f%m "$path" 2> /dev/null) || stat_rc=$?
                    if mole_rc_timeout_or_signal "$stat_rc"; then
                        _mole_record_clean_cancellation "$stat_rc"
                        return "$stat_rc"
                    fi
                    [[ $stat_rc -eq 0 ]] || mod_time=0
                    local now
                    now=$(date +%s 2> /dev/null || echo "0")
                    if [[ "$mod_time" -gt 0 && "$now" -gt 0 ]]; then
                        file_age=$(((now - mod_time) / 86400))
                    fi
                fi
            fi

            debug_file_action "[DRY RUN] Would remove" "$path" "$file_size" "$file_age"
        else
            debug_log "[DRY RUN] Would remove: $path"
        fi
        return 0
    fi

    debug_log "Removing: $path"

    # Calculate size before deletion for logging.
    # Accept pre-computed size to skip redundant I/O when the caller already measured.
    local size_kb=0
    local size_human=""
    if oplog_enabled; then
        if [[ -n "$precomputed_size_kb" ]]; then
            if [[ "$precomputed_size_kb" =~ ^[0-9]+$ ]]; then
                size_kb="$precomputed_size_kb"
            fi
        elif [[ -e "$path" ]]; then
            local size_probe_rc=0
            local size_probe_timeout=""
            size_probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                "$deadline_seconds") || size_probe_rc=$?
            if [[ $size_probe_rc -eq 0 ]]; then
                size_kb=$(get_path_size_kb "$path" "$size_probe_timeout" readable 2> /dev/null) || size_probe_rc=$?
            fi
            if mole_rc_timeout "$size_probe_rc"; then
                # Sizing budget exhausted: still remove the item, with the
                # freed total under-reported, matching the batch-sizing policy.
                MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
            fi
            if [[ $size_probe_rc -ge 128 ]]; then
                _mole_record_clean_cancellation "$size_probe_rc"
                return "$size_probe_rc"
            fi
            [[ $size_probe_rc -eq 0 && "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
        fi
        if [[ "$size_kb" =~ ^[0-9]+$ ]] && [[ "$size_kb" -gt 0 ]]; then
            size_human=$(bytes_to_human "$((size_kb * 1024))" 2> /dev/null || echo "${size_kb}KB")
        fi
    fi

    # Recheck at the final sink. A daemon can create this compiled-model cache
    # while the preceding size probe walks the target, and deleting its parent
    # then breaks recognition until the owning process restarts.
    if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$path" 2> /dev/null; then
        debug_log "Skipped removal after compiled model cache appeared: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "compiled model cache"
        return 1
    fi

    # Recheck live-owner / open-SQLite state after size probing: a helper can
    # launch while du is walking the tree (same race class as the compiled
    # model cache check above).
    _mole_reset_process_snapshot
    local live_cache_guard_rc=0
    _mole_should_refuse_live_user_cache_path "$path" || live_cache_guard_rc=$?
    if [[ $live_cache_guard_rc -eq 0 ]]; then
        debug_log "Skipped removal after live user cache appeared: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "live user cache"
        return 1
    fi
    if mole_rc_timeout_or_signal "$live_cache_guard_rc"; then
        _mole_record_clean_cancellation "$live_cache_guard_rc"
        return "$live_cache_guard_rc"
    fi
    container_probe_parent="$_MOLE_CONTAINER_CACHE_PROBE_PARENT"
    container_probe_parent_id="$_MOLE_CONTAINER_CACHE_PROBE_PARENT_ID"
    container_probe_target_id="$_MOLE_CONTAINER_CACHE_PROBE_TARGET_ID"

    # Reverse-DNS and container caches were rechecked by the live-cache guard.
    # SQLite files elsewhere still need their own post-size handle probe.
    if _mole_is_sqlite_database_path "$path" &&
        ! _mole_user_cache_scope "$path" > /dev/null 2>&1; then
        _mole_snapshot_path_identity "$path" || return 1
        local sqlite_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
        local sqlite_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        local sqlite_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
        local sqlite_state=0
        _mole_sqlite_database_in_use "$path" || sqlite_state=$?
        if mole_rc_timeout_or_signal "$sqlite_state"; then
            _mole_record_clean_cancellation "$sqlite_state"
            return "$sqlite_state"
        fi
        if [[ $sqlite_state -ne 1 ]]; then
            debug_log "Skipped SQLite file after final open-file recheck: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "active or unknown SQLite database"
            return 1
        fi
        if ! _mole_path_matches_identity \
            "$path" "$sqlite_parent" "$sqlite_parent_id" "$sqlite_target_id"; then
            debug_log "Skipped SQLite file after identity changed during final open-file recheck: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "identity changed"
            return 1
        fi
        exact_probe_parent="$sqlite_parent"
        exact_probe_parent_id="$sqlite_parent_id"
        exact_probe_target_id="$sqlite_target_id"
    fi

    # Downloads are outside the user-cache owner guard above. Recheck the exact
    # file after sizing so a browser that resumed the transfer cannot race the
    # earlier validation into the unlink.
    if _mole_is_incomplete_download_path "$path"; then
        _mole_snapshot_path_identity "$path" || return 1
        local download_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
        local download_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        local download_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
        local download_open_state=0
        _mole_paths_have_open_handle "$path" || download_open_state=$?
        if mole_rc_timeout_or_signal "$download_open_state"; then
            _mole_record_clean_cancellation "$download_open_state"
            return "$download_open_state"
        fi
        if [[ $download_open_state -ne 1 ]]; then
            debug_log "Skipped incomplete download after final open-file recheck: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "active or unknown download"
            return 1
        fi
        if ! _mole_path_matches_identity \
            "$path" "$download_parent" "$download_parent_id" "$download_target_id"; then
            debug_log "Skipped incomplete download after identity changed during final open-file recheck: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "identity changed"
            return 1
        fi
        exact_probe_parent="$download_parent"
        exact_probe_parent_id="$download_parent_id"
        exact_probe_target_id="$download_target_id"
    fi

    if [[ -n "$expected_parent" ]] && ! _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        debug_log "Refusing removal after final path identity changed: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "identity changed"
        return 1
    fi

    # Last hop before rm, for callers whose exclusion depends on state this
    # function cannot express as a parent/target inode pair. A candidate list
    # that skipped a live owner root only proves where that root pointed when
    # the list was built; re-asking here closes the rest of the window rather
    # than leaving it open from discovery all the way to the unlink. Set
    # _MOLE_SAFE_REMOVE_FINAL_GUARD to a function name that takes the path and
    # returns non-zero to refuse.
    local final_sink_guard="${_MOLE_SAFE_REMOVE_FINAL_GUARD:-}"
    if [[ -n "$final_sink_guard" ]] && declare -f "$final_sink_guard" > /dev/null 2>&1; then
        local final_sink_guard_rc=0
        "$final_sink_guard" "$path" || final_sink_guard_rc=$?
        if [[ $final_sink_guard_rc -ne 0 ]]; then
            debug_log "Refusing removal after the final sink guard denied: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "sink guard denied"
            if mole_rc_timeout_or_signal "$final_sink_guard_rc"; then
                _mole_record_clean_cancellation "$final_sink_guard_rc"
                return "$final_sink_guard_rc"
            fi
            return 1
        fi
    fi

    # A caller-specific final guard may perform process or metadata probes.
    # Rebind the original object once more after that work so a replacement
    # during the guard cannot reach rm under the identity checked above.
    if [[ -n "$expected_parent" ]] && ! _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        debug_log "Refusing removal after path identity changed during the final sink guard: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "identity changed"
        return 1
    fi

    if [[ -n "$container_probe_parent" ]] && ! _mole_path_matches_identity \
        "$path" "$container_probe_parent" "$container_probe_parent_id" \
        "$container_probe_target_id"; then
        debug_log "Refusing removal after container cache identity changed: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "identity changed"
        return 1
    fi

    if [[ -n "$exact_probe_parent" ]] && ! _mole_path_matches_identity \
        "$path" "$exact_probe_parent" "$exact_probe_parent_id" \
        "$exact_probe_target_id"; then
        debug_log "Refusing removal after final open-file target identity changed: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "identity changed"
        return 1
    fi

    # Resolve the removal budget before the last ownership check so a
    # replacement during that work cannot inherit the earlier approval.
    local error_msg
    local rm_exit=0
    local section_deadline_spent=0
    local rm_timeout=""
    local shell_rm=false
    if declare -F rm > /dev/null 2>&1; then
        shell_rm=true
    else
        rm_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
            "$deadline_seconds") || rm_exit=$?
        [[ $rm_exit -eq 0 ]] || section_deadline_spent=1
    fi
    if [[ $rm_exit -eq 0 ]]; then
        _mole_owned_path_still_valid "$path" \
            "$expected_file_sha256" "$expected_absent_path" \
            "$expected_parent" "$expected_parent_id" "$expected_target_id" || return $?
        # Use || so set -e does not abort before the failure is classified.
        if [[ "$shell_rm" == true ]]; then
            error_msg=$(rm -rf "$path" 2>&1) || rm_exit=$? # SAFE: safe_remove validated and rebound this exact target above
        else
            error_msg=$(run_with_timeout "$rm_timeout" rm -rf "$path" < /dev/null 2>&1) || rm_exit=$? # SAFE: safe_remove validated and rebound this exact target above
        fi
    fi

    if mole_rc_timeout "$rm_exit"; then
        debug_log "Removal timed out: $path"
        if [[ $section_deadline_spent -eq 1 ]]; then
            # Not a slow removal: the caller's section deadline expired before
            # rm ran, and that section reports its own stop. Counting it here
            # would point the user at the per-item removal budget instead.
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "section time limit reached"
        else
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "removal timed out"
            # A slow disk can exceed the per-item removal budget. That is a
            # failed removal, not a user interrupt: count it and keep going so
            # one slow cache never cancels the remaining cleanup.
            MOLE_CLEAN_REMOVAL_TIMEOUTS=$((${MOLE_CLEAN_REMOVAL_TIMEOUTS:-0} + 1))
            _mole_record_removal_timeout_path "$path"
        fi
        return 124
    fi

    # Preserve interrupt semantics so callers can abort long-running deletions.
    if [[ $rm_exit -ge 128 ]]; then
        _mole_record_clean_cancellation "$rm_exit"
        return "$rm_exit"
    fi

    if [[ $rm_exit -eq 0 ]]; then
        # Log successful removal
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$path" "$size_human"
        return 0
    else
        # Check if it's a permission error
        if [[ "$error_msg" == *"Permission denied"* ]] || [[ "$error_msg" == *"Operation not permitted"* ]]; then
            MOLE_PERMISSION_DENIED_COUNT=${MOLE_PERMISSION_DENIED_COUNT:-0}
            MOLE_PERMISSION_DENIED_COUNT=$((MOLE_PERMISSION_DENIED_COUNT + 1))
            export MOLE_PERMISSION_DENIED_COUNT
            debug_log "Permission denied: $path, may need Full Disk Access"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "permission denied"
        else
            [[ "$silent" != "true" ]] && log_error "Failed to remove: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "error"
        fi
        return 1
    fi
}

# Safe symlink removal (for pre-validated symlinks only)
safe_remove_symlink() {
    local path="$1"
    local use_sudo="${2:-false}"
    local expected_parent="${3:-}"
    local expected_parent_id="${4:-}"
    local expected_target_id="${5:-}"
    local expected_file_sha256="${6:-}"
    local expected_absent_path="${7:-}"

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi

    if [[ ! -L "$path" ]]; then
        return 1
    fi

    if ! validate_path_for_deletion "$path"; then
        return 1
    fi

    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$path"; then
        debug_log "Skipped symlink removal for whitelisted path: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "whitelist"
        return 1
    fi

    if [[ "$use_sudo" == "true" ]] && _mole_privileged_path_has_mutable_ancestor "$path"; then
        if [[ ${EUID:-0} -ne 0 ]]; then
            use_sudo=false
        else
            debug_log "Refusing privileged symlink removal below mutable parent: $path"
            return 1
        fi
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        local dry_record_rc=0
        _record_file_ops_dry_run_target "$path" || dry_record_rc=$?
        if mole_rc_timeout_or_signal "$dry_record_rc"; then
            _mole_record_clean_cancellation "$dry_record_rc"
            return "$dry_record_rc"
        fi
        debug_log "[DRY RUN] Would remove symlink: $path"
        return 0
    fi

    if [[ -n "$expected_parent" ]] && ! _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        debug_log "Refusing symlink removal after final path identity changed: $path"
        return 1
    fi

    _mole_owned_path_still_valid "$path" \
        "$expected_file_sha256" "$expected_absent_path" \
        "$expected_parent" "$expected_parent_id" "$expected_target_id" || return $?

    local rm_exit=0
    if [[ "$use_sudo" == "true" ]]; then
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "sudo blocked in test mode"
            return 1
        fi
        sudo -n rm "$path" 2> /dev/null || rm_exit=$?
    else
        rm "$path" 2> /dev/null || rm_exit=$?
    fi

    if [[ $rm_exit -eq 0 ]]; then
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$path" "symlink"
        return 0
    else
        if mole_rc_timeout_or_signal "$rm_exit"; then
            _mole_record_clean_cancellation "$rm_exit"
            return "$rm_exit"
        fi
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "symlink removal failed"
        return 1
    fi
}

# A privileged path operation is only safe when every parent directory is
# immutable to unprivileged users. Checking `-w` alone is insufficient: a
# directory owner can chmod a 0555 parent after validation, replace a component,
# and redirect a later sudo rm/mv. Fail closed on non-root ownership, writable
# mode bits, symlinks, unreadable metadata, and effective ACL write access.
_mole_privileged_path_has_mutable_ancestor() {
    local path="$1"
    local probe="${path%/*}"
    local invoking_uid=""
    [[ -n "$probe" ]] || probe="/"
    invoking_uid=$(get_invoking_uid 2> /dev/null || true)
    [[ "$invoking_uid" =~ ^[0-9]+$ ]] || return 0

    while true; do
        if [[ -L "$probe" ]]; then
            return 0
        fi

        local owner_uid=""
        local mode=""
        owner_uid=$($STAT_BSD -f%u "$probe" 2> /dev/null || true)
        mode=$($STAT_BSD -f%Lp "$probe" 2> /dev/null || true)
        if [[ ! "$owner_uid" =~ ^[0-9]+$ || ! "$mode" =~ ^[0-7]+$ ]]; then
            return 0
        fi
        if [[ "$owner_uid" -ne 0 ]] || (((8#$mode & 0022) != 0)); then
            return 0
        fi
        if [[ "$invoking_uid" -ne 0 ]]; then
            if [[ ${EUID:-0} -eq "$invoking_uid" ]]; then
                [[ -w "$probe" ]] && return 0
            elif [[ ${EUID:-0} -eq 0 ]]; then
                # Under `sudo mo`, the shell's -w probe reflects root rather
                # than the invoking user. Drop authority for the ACL check so
                # immutable system parents do not become false positives.
                local acl_probe_rc=0
                _mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                    -n -u "#$invoking_uid" /bin/test -w "$probe" < /dev/null 2> /dev/null || acl_probe_rc=$?
                if [[ $acl_probe_rc -eq 0 ]]; then
                    return 0
                fi
                # Only test's ordinary false status proves the invoking user
                # cannot write here. Timeout, auth, and execution failures are
                # unknown and must classify the ancestor as mutable.
                if [[ $acl_probe_rc -ne 1 ]]; then
                    return 0
                fi
            else
                return 0
            fi
        fi

        [[ "$probe" == "/" ]] && break
        probe="${probe%/*}"
        [[ -n "$probe" ]] || probe="/"
    done
    return 1
}

# Safe sudo removal with symlink and parent-component protection
safe_sudo_remove() {
    local path="$1"
    local precomputed_size_kb="${2:-}"
    local deadline_seconds="${3:-}"
    local expected_parent="${4:-}"
    local expected_parent_id="${5:-}"
    local expected_target_id="${6:-}"
    local expected_file_sha256="${7:-}"
    local expected_absent_path="${8:-}"

    local pending_clean_cancel="${MOLE_CLEAN_CANCEL_STATUS:-0}"
    if [[ "${MOLE_CURRENT_COMMAND:-}" == "clean" ]] && mole_rc_timeout_or_signal "$pending_clean_cancel"; then
        return "$pending_clean_cancel"
    fi

    if ! validate_path_for_deletion "$path"; then
        if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$path"; then
            debug_log "Skipped sudo remove for protected path: $path"
            return "$MOLE_ERR_PROTECTED_PATH"
        else
            log_error "Path validation failed for sudo remove: $path"
        fi
        return 1
    fi

    if [[ ! -e "$path" ]]; then
        return 0
    fi

    if [[ -L "$path" ]]; then
        log_error "Refusing to sudo remove symlink: $path"
        return 1
    fi

    if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$path"; then
        debug_log "Skipped sudo remove for whitelisted path: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "whitelist"
        return 1
    fi

    # This policy must run before dry-run/test-mode returns so preview and real
    # privileged cleanup agree on the eligible target set.
    if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$path" 2> /dev/null; then
        debug_log "Skipped sudo removal for compiled model cache: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "compiled model cache"
        return "$MOLE_ERR_PROTECTED_PATH"
    fi

    if _mole_privileged_path_has_mutable_ancestor "$path"; then
        if [[ ${EUID:-0} -ne 0 ]]; then
            debug_log "Downgrading sudo remove below mutable parent: $path"
            safe_remove "$path" true "$precomputed_size_kb" "$deadline_seconds" \
                "$expected_parent" "$expected_parent_id" "$expected_target_id" \
                "$expected_file_sha256" "$expected_absent_path"
            return $?
        fi
        debug_log "Refusing sudo remove below mutable parent: $path"
        return 1
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        local dry_record_rc=0
        _record_file_ops_dry_run_target \
            "$path" "$precomputed_size_kb" || dry_record_rc=$?
        if mole_rc_timeout_or_signal "$dry_record_rc"; then
            _mole_record_clean_cancellation "$dry_record_rc"
            return "$dry_record_rc"
        fi
    fi

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            log_info "[DRY-RUN] Would sudo remove: $path"
            return 0
        fi
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "sudo blocked in test mode"
        return 1
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        if [[ "${MO_DEBUG:-}" == "1" ]]; then
            local file_type="file"
            [[ -d "$path" ]] && file_type="directory"

            local file_size=""
            local file_age=""

            local exists_rc=0
            _mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                -n test -e "$path" < /dev/null 2> /dev/null || exists_rc=$?
            if mole_rc_timeout_or_signal "$exists_rc"; then
                _mole_record_clean_cancellation "$exists_rc"
                return "$exists_rc"
            fi
            if [[ $exists_rc -eq 0 ]]; then
                local size_kb=0
                if [[ -n "$precomputed_size_kb" ]]; then
                    if [[ "$precomputed_size_kb" =~ ^[0-9]+$ ]]; then
                        size_kb="$precomputed_size_kb"
                    fi
                else
                    local size_rc=0
                    size_kb=$(_mole_bounded_sudo "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                        -n du -skP "$path" < /dev/null 2> /dev/null | awk '{print $1}') || size_rc=$?
                    if mole_rc_timeout_or_signal "$size_rc"; then
                        _mole_record_clean_cancellation "$size_rc"
                        return "$size_rc"
                    fi
                    [[ $size_rc -eq 0 ]] || size_kb=0
                fi
                if [[ "$size_kb" -gt 0 ]]; then
                    file_size=$(bytes_to_human "$((size_kb * 1024))")
                fi

                local type_probe_rc=0
                _mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                    -n test -f "$path" < /dev/null 2> /dev/null || type_probe_rc=$?
                if mole_rc_timeout_or_signal "$type_probe_rc"; then
                    _mole_record_clean_cancellation "$type_probe_rc"
                    return "$type_probe_rc"
                fi
                if [[ $type_probe_rc -ne 0 ]]; then
                    type_probe_rc=0
                    _mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                        -n test -d "$path" < /dev/null 2> /dev/null || type_probe_rc=$?
                    if mole_rc_timeout_or_signal "$type_probe_rc"; then
                        _mole_record_clean_cancellation "$type_probe_rc"
                        return "$type_probe_rc"
                    fi
                fi
                if [[ $type_probe_rc -eq 0 ]]; then
                    local mod_time=0
                    local stat_rc=0
                    mod_time=$(_mole_bounded_sudo "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                        -n "$STAT_BSD" -f%m "$path" < /dev/null 2> /dev/null) || stat_rc=$?
                    if mole_rc_timeout_or_signal "$stat_rc"; then
                        _mole_record_clean_cancellation "$stat_rc"
                        return "$stat_rc"
                    fi
                    [[ $stat_rc -eq 0 ]] || mod_time=0
                    local now
                    now=$(date +%s 2> /dev/null || echo "0")
                    if [[ "$mod_time" -gt 0 && "$now" -gt 0 ]]; then
                        local age_seconds=$((now - mod_time))
                        file_age=$(format_duration_human "$age_seconds")
                    fi
                fi
            fi

            log_info "[DRY-RUN] Would sudo remove: $file_type $path"
            [[ -n "$file_size" ]] && log_info "  Size: $file_size"
            [[ -n "$file_age" ]] && log_info "  Age: $file_age"
        else
            log_info "[DRY-RUN] Would sudo remove: $path"
        fi
        return 0
    fi

    local size_kb=0
    local size_human=""
    if oplog_enabled; then
        if [[ -n "$precomputed_size_kb" ]]; then
            if [[ "$precomputed_size_kb" =~ ^[0-9]+$ ]]; then
                size_kb="$precomputed_size_kb"
            fi
        else
            local exists_probe_rc=0
            local exists_probe_timeout=""
            exists_probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                "$deadline_seconds") || exists_probe_rc=$?
            if [[ $exists_probe_rc -eq 0 ]]; then
                _mole_bounded_sudo "$exists_probe_timeout" \
                    -n test -e "$path" < /dev/null 2> /dev/null || exists_probe_rc=$?
            fi
            if mole_rc_timeout "$exists_probe_rc"; then
                _mole_record_clean_cancellation 124
                return 124
            fi
            if [[ $exists_probe_rc -ge 128 ]]; then
                _mole_record_clean_cancellation "$exists_probe_rc"
                return "$exists_probe_rc"
            fi
            if [[ $exists_probe_rc -eq 0 ]]; then
                local size_probe_rc=0
                local size_probe_timeout=""
                size_probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                    "$deadline_seconds") || size_probe_rc=$?
                if [[ $size_probe_rc -eq 0 ]]; then
                    size_kb=$(_mole_bounded_sudo "$size_probe_timeout" \
                        -n du -skP "$path" < /dev/null 2> /dev/null | awk '{print $1}') || size_probe_rc=$?
                fi
                if mole_rc_timeout "$size_probe_rc"; then
                    MOLE_CLEAN_SIZING_TIMEOUTS=$((${MOLE_CLEAN_SIZING_TIMEOUTS:-0} + 1))
                fi
                if [[ $size_probe_rc -ge 128 ]]; then
                    _mole_record_clean_cancellation "$size_probe_rc"
                    return "$size_probe_rc"
                fi
                [[ $size_probe_rc -eq 0 && "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0
            fi
        fi
        if [[ "$size_kb" =~ ^[0-9]+$ ]] && [[ "$size_kb" -gt 0 ]]; then
            size_human=$(bytes_to_human "$((size_kb * 1024))" 2> /dev/null || echo "${size_kb}KB")
        fi
    fi

    # Keep the same last-mile policy as safe_remove: privileged cleanup must
    # also fail closed if a compiled-model cache appears during size probing.
    if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$path" 2> /dev/null; then
        debug_log "Skipped sudo removal after compiled model cache appeared: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "compiled model cache"
        return "$MOLE_ERR_PROTECTED_PATH"
    fi

    local output
    local ret=0
    if [[ -n "$expected_parent" ]] && ! _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        debug_log "Refusing privileged removal after final path identity changed: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "identity changed"
        return 1
    fi
    local remove_timeout=""
    local section_deadline_spent=0
    remove_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
        "$deadline_seconds") || ret=$?
    if [[ $ret -eq 0 ]]; then
        _mole_owned_path_still_valid "$path" \
            "$expected_file_sha256" "$expected_absent_path" \
            "$expected_parent" "$expected_parent_id" "$expected_target_id" || return $?
        output=$(_mole_bounded_sudo "$remove_timeout" \
            -n rm -rf "$path" < /dev/null 2>&1) || ret=$? # SAFE: safe_sudo_remove validated the exact immutable-ancestor target above
    else
        # The section's own wall-clock budget ran out, so rm never started.
        section_deadline_spent=1
    fi

    if [[ $ret -eq 0 ]]; then
        log_operation "${MOLE_CURRENT_COMMAND:-clean}" "REMOVED" "$path" "$size_human"
        return 0
    fi

    if mole_rc_timeout "$ret"; then
        if [[ $section_deadline_spent -eq 1 ]]; then
            # The section prints its own "time limit reached" line; counting it
            # here too would tell the user to raise the per-item removal budget,
            # which is not the budget that ran out.
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "SKIPPED" "$path" "section time limit reached"
        else
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "removal timed out"
            MOLE_CLEAN_REMOVAL_TIMEOUTS=$((${MOLE_CLEAN_REMOVAL_TIMEOUTS:-0} + 1))
            _mole_record_removal_timeout_path "$path"
        fi
        return 124
    fi
    if [[ $ret -ge 128 ]]; then
        _mole_record_clean_cancellation "$ret"
        return "$ret"
    fi

    case "$output" in
        *"a password is required"* | *"a terminal is required"* | *"Password:"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "auth required"
            return "$MOLE_ERR_AUTH_FAILED"
            ;;
        *"Operation not permitted"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "sip/mdm protected"
            return "$MOLE_ERR_SIP_PROTECTED"
            ;;
        *"Read-only file system"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "readonly filesystem"
            return "$MOLE_ERR_READONLY_FS"
            ;;
        *"Sorry, try again"* | *"incorrect passphrase"* | *"incorrect credentials"*)
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "auth failed"
            return "$MOLE_ERR_AUTH_FAILED"
            ;;
        *)
            log_error "Failed to remove, sudo: $path"
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$path" "sudo error"
            return 1
            ;;
    esac
}

diagnose_removal_failure() {
    local exit_code="$1"
    local app_name="${2:-application}"

    local reason=""
    local suggestion=""

    case "$exit_code" in
        "$MOLE_ERR_SIP_PROTECTED")
            reason="protected by macOS (SIP/MDM)"
            ;;
        "$MOLE_ERR_AUTH_FAILED")
            reason="authentication failed"
            if declare -F check_touchid_support > /dev/null 2>&1 && check_touchid_support > /dev/null 2>&1; then
                suggestion="Check your credentials or restart Terminal"
            else
                suggestion="Try 'mole touchid' to enable fingerprint auth"
            fi
            ;;
        "$MOLE_ERR_READONLY_FS")
            reason="filesystem is read-only"
            suggestion="Check if disk needs repair"
            ;;
        "$MOLE_ERR_PROTECTED_PATH")
            reason="protected by Mole safety rules"
            ;;
        "$MOLE_ERR_PRIVACY_DENIED")
            reason="macOS denied Trash access"
            suggestion="Try moving the item to Trash in Finder. Run with --debug for details"
            ;;
        "$MOLE_ERR_MUTABLE_PARENT")
            reason="Mole cannot safely use elevated deletion below a user-writable parent"
            suggestion="Move the app to Trash in Finder; Mole will leave protected containers and app data untouched"
            ;;
        *)
            reason="permission denied"
            if declare -F check_touchid_support > /dev/null 2>&1 && check_touchid_support > /dev/null 2>&1; then
                suggestion="Try running again or check file ownership"
            else
                suggestion="Try 'mole touchid' or check with 'ls -l'"
            fi
            ;;
    esac

    echo "$reason|$suggestion"
}
