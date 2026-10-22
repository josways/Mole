#!/bin/bash
# Internal deletion module. Load through file_ops.sh; do not initialize independently.
# Inputs, outcomes and failure behavior: docs/QUALITY_CONTRACTS.md.

# ============================================================================
# Unified deletion helper (Trash + permanent routing with forensic log)
# ============================================================================

# Capture the device, inode, and mtime contract accepted by mole_delete.
# Failure never falls back to a path-only identity.
mole_deletion_identity() {
    local path="$1"
    local duration identity
    duration=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "${2:-}") || return $?
    identity=$(run_with_timeout "$duration" "$STAT_BSD" -f%d:%i:%m "$path" < /dev/null 2> /dev/null) || return $?
    [[ "$identity" =~ ^[0-9]+:[0-9]+:-?[0-9]+$ ]] || return 1
    printf '%s\n' "$identity"
}

# Bind owner decisions to file contents across slow probes. The caller also
# supplies path identity so an atomic replacement cannot inherit approval.
mole_file_sha256() {
    local timeout="$MOLE_TIMEOUT_QUICK_DETECT_SEC"
    if [[ -n "${2:-}" ]]; then
        timeout=$(_mole_timeout_with_deadline "$timeout" "$2") || return $?
    fi
    local output=""
    output=$(run_with_timeout "$timeout" \
        shasum -a 256 -- "$1" < /dev/null 2> /dev/null) || return $?
    [[ "$output" =~ ^[0-9a-f]{64}[[:space:]] ]] || return 1
    printf '%s\n' "${output:0:64}"
}

_mole_expected_path_absent() {
    local path="${1:-}"
    [[ -z "$path" || (! -e "$path" && ! -L "$path") ]]
}

_mole_owned_path_still_valid() {
    local path="$1"
    local expected_file_sha256="${2:-}"
    local expected_absent_path="${3:-}"
    local expected_parent="${4:-}"
    local expected_parent_id="${5:-}"
    local expected_target_id="${6:-}"
    local deadline="${7:-}"
    if [[ -n "$expected_file_sha256" ]]; then
        local current_sha256="" hash_rc=0
        current_sha256=$(mole_file_sha256 "$path" "$deadline") || hash_rc=$?
        mole_rc_timeout_or_signal "$hash_rc" && return "$hash_rc"
        [[ $hash_rc -eq 0 && "$current_sha256" == "$expected_file_sha256" ]] || return "$MOLE_ERR_OWNER_UNVERIFIED"
    fi
    # Hashing reads a file descriptor while the sink acts on a pathname. A
    # replacement installed during the hash must not inherit its approval.
    if [[ -n "$expected_parent" ]] && ! _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        return "$MOLE_ERR_OWNER_UNVERIFIED"
    fi
    _mole_expected_path_absent "$expected_absent_path" || return "$MOLE_ERR_APP_REAPPEARED"
}

_mole_report_unverified_delete() {
    local path="$1"
    local mode="$2"
    local size_kb="$3"
    local reason="${4:-$MOLE_ERR_OWNER_UNVERIFIED}"
    local refusal_reason="ownership-unverified"
    local detail="agent ownership unverified"
    local explanation="the agent file changed or could not be inspected. Review the plist before retrying."
    if [[ $reason -eq $MOLE_ERR_APP_REAPPEARED ]]; then
        refusal_reason="app-reappeared"
        detail="selected app path reappeared"
        explanation="the selected app path exists again. Select the app and review its removal plan."
    fi
    _mole_delete_log "$mode" "$size_kb" "$refusal_reason" "$path"
    log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$path" "$detail"
    _mole_record_uninstall_refusal "$path" "$refusal_reason"
    if [[ "${_MOLE_UNINSTALL_REFUSALS_ACTIVE:-0}" != 1 ]]; then
        printf 'Kept %s: %s\n' "$path" "$explanation" >&2
    fi
}

# Route a deletion through either macOS Trash or permanent rm, while logging
# every call for forensic review. Designed for destructive paths where undo
# matters (e.g. uninstall). Not used by cache-clean paths.
#
# Usage: mole_delete <path> [needs_sudo=false] [expected_dev_inode_mtime] [expected_file_sha256] [expected_absent_path]
#
# Environment:
#   MOLE_DELETE_MODE      "permanent" (default) or "trash"; other values fail
#   MOLE_DRY_RUN=1        Log intent, do not delete
#   MOLE_TEST_TRASH_DIR   Test-only override, honored only with MOLE_TEST_MODE=1
#                         or MOLE_TEST_NO_AUTH=1; Trash moves go here via `mv`
#                         instead of Finder/trash CLI. Required for bats.
#   MOLE_DELETE_LOG       Override the log file path (default:
#                         ~/Library/Logs/mole/deletions.log)
#
# Returns 0 on success and a nonzero MOLE_ERR_* code on failure. Always appends a tab-separated line to
# the deletions log: <iso_ts>\t<mode>\t<size_kb>\t<status>\t<path>.
# Control bytes in any field are written as \n, \r, \t or \xHH so a name cannot
# start a record; backslashes stay literal.
# size_kb is "unknown" when du could not measure the path (permission denied,
# disappeared mid-call); never silently coerced to 0KB so post-hoc forensics
# can tell measured-zero from measurement-failure.
mole_delete() {
    local path="$1"
    local needs_sudo="${2:-false}"
    local expected_identity="${3:-}"
    local expected_file_sha256="${4:-}"
    local expected_absent_path="${5:-}"
    local mode="${MOLE_DELETE_MODE:-permanent}"

    [[ -z "$path" ]] && return 1

    case "$mode" in
        permanent | trash) ;;
        *)
            _mole_delete_log "$mode" "unknown" "invalid-mode" "$path"
            if [[ -z "${_MOLE_INVALID_MODE_WARNED:-}" ]]; then
                _MOLE_INVALID_MODE_WARNED=1
                export _MOLE_INVALID_MODE_WARNED
                printf 'Error: invalid MOLE_DELETE_MODE: %s (expected "permanent" or "trash")\n' "$mode" >&2
            fi
            return 1
            ;;
    esac

    # Nothing to do if path does not exist (but a broken symlink still counts).
    if [[ ! -e "$path" && ! -L "$path" ]]; then
        return 0
    fi

    # Validation is delegated to the underlying safe_* helpers (which call
    # validate_path_for_deletion). Trash routing only applies to paths the
    # user could legitimately restore from, so we short-circuit invalid paths
    # up front to avoid a no-op Trash move followed by a validation failure.
    # The rejection itself is recorded in the forensic log so audit trails
    # can distinguish refused-by-policy from never-attempted.
    local validation_rc=0
    validate_path_for_deletion "$path" || validation_rc=$?
    if mole_rc_timeout_or_signal "$validation_rc"; then
        local validation_status="interrupted"
        mole_rc_timeout "$validation_rc" && validation_status="timed-out"
        _mole_delete_log "$mode" "unknown" "$validation_status" "$path"
        return "$validation_rc"
    fi
    if [[ $validation_rc -ne 0 ]]; then
        _mole_delete_log "$mode" "0" "rejected" "$path"
        log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$path" "${_MOLE_VALIDATION_REASON:-protected}"
        return 1
    fi

    if [[ "$needs_sudo" == "true" ]] && _mole_privileged_path_has_mutable_ancestor "$path"; then
        # Neither sudo rm/mv nor Finder authorization is safe here: both receive
        # a pathname that a non-root invoking user can replace after validation.
        # Finder also fails for some package-installed apps even after its native
        # authorization dialog (#1266). Keep both Trash and permanent modes
        # fail-closed and direct the user to perform the app move themselves.
        _mole_delete_log "$mode" "unknown" "mutable-parent" "$path"
        debug_log "Refusing privileged delete below mutable parent: $path"
        return "$MOLE_ERR_MUTABLE_PARENT"
    fi

    # Capture size before the delete so the log line is still useful when the
    # path is gone afterwards. Use "unknown" (not 0) on failure so the log
    # never lies about a multi-GB delete by recording it as 0KB.
    local size_kb="unknown"
    if [[ -e "$path" ]]; then
        local raw_size=""
        local du_rc=0
        if [[ "$needs_sudo" == "true" ]]; then
            if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
                du_rc=1
            else
                raw_size=$(run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                    sudo -n du -skP "$path" 2> /dev/null |
                    awk '{print $1; exit}') || du_rc=$?
            fi
        else
            raw_size=$(get_path_size_kb "$path" 2> /dev/null) || du_rc=$?
        fi
        if [[ "$du_rc" -eq 0 && "$raw_size" =~ ^[0-9]+$ ]]; then
            size_kb="$raw_size"
        fi
        # Ctrl-C and other signals are cancellation, not an unknown-size
        # measurement. Stop before any dry-run registration, Trash move, or
        # permanent removal so the user's interrupt cannot be ignored.
        if mole_rc_timeout_or_signal "$du_rc"; then
            local cancel_status="interrupted"
            mole_rc_timeout "$du_rc" && cancel_status="timed-out"
            _mole_delete_log "$mode" "$size_kb" "$cancel_status" "$path"
            return "$du_rc"
        fi
    fi

    local expected_parent=""
    local expected_parent_id=""
    local expected_target_id=""
    if [[ -n "$expected_identity" ]]; then
        if ! _mole_snapshot_path_identity "$path"; then
            _mole_delete_log "$mode" "$size_kb" "identity-changed" "$path"
            return 1
        fi
        expected_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
        expected_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
        expected_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
        local current_identity=""
        local identity_rc=0
        current_identity=$(mole_deletion_identity "$path") || identity_rc=$?
        if mole_rc_timeout_or_signal "$identity_rc"; then
            local identity_status="interrupted"
            mole_rc_timeout "$identity_rc" && identity_status="timed-out"
            _mole_delete_log "$mode" "$size_kb" "$identity_status" "$path"
            return "$identity_rc"
        fi
        if [[ $identity_rc -ne 0 || "$current_identity" != "$expected_identity" ||
            "$expected_target_id" != "${expected_identity%:*}" ||
            "$expected_target_id" != "${current_identity%:*}" ]]; then
            if [[ -n "$expected_file_sha256" ]]; then
                _mole_report_unverified_delete "$path" "$mode" "$size_kb"
            else
                _mole_delete_log "$mode" "$size_kb" "identity-changed" "$path"
                debug_log "Refusing deletion after selected path identity changed: $path"
            fi
            return 1
        fi
    fi

    if [[ -n "$expected_file_sha256" ]]; then
        [[ -n "$expected_identity" ]] || return 1
        local current_sha256="" hash_rc=0
        current_sha256=$(mole_file_sha256 "$path") || hash_rc=$?
        if mole_rc_timeout_or_signal "$hash_rc"; then
            local hash_status="interrupted"
            mole_rc_timeout "$hash_rc" && hash_status="timed-out"
            _mole_delete_log "$mode" "$size_kb" "$hash_status" "$path"
            return "$hash_rc"
        fi
        if [[ $hash_rc -ne 0 || "$current_sha256" != "$expected_file_sha256" ]]; then
            _mole_report_unverified_delete "$path" "$mode" "$size_kb"
            return 1
        fi
        if ! _mole_path_matches_identity "$path" "$expected_parent" \
            "$expected_parent_id" "$expected_target_id"; then
            _mole_report_unverified_delete "$path" "$mode" "$size_kb"
            return 1
        fi
    fi

    if ! _mole_expected_path_absent "$expected_absent_path"; then
        _mole_report_unverified_delete "$path" "$mode" "$size_kb" "$MOLE_ERR_APP_REAPPEARED"
        return 1
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        local preview_rc=0
        if [[ "$size_kb" =~ ^[0-9]+$ ]]; then
            _record_file_ops_dry_run_target "$path" "$size_kb" || preview_rc=$?
        else
            _record_file_ops_dry_run_target "$path" || preview_rc=$?
        fi
        if mole_rc_timeout_or_signal "$preview_rc"; then
            local preview_status="interrupted"
            mole_rc_timeout "$preview_rc" && preview_status="timed-out"
            _mole_delete_log "$mode" "$size_kb" "$preview_status" "$path"
            return "$preview_rc"
        fi
        debug_log "[DRY RUN] Would delete ($mode): $path"
        _mole_delete_log "$mode" "$size_kb" "dry-run" "$path"
        return 0
    fi

    if [[ "$needs_sudo" == "true" ]]; then
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
            _mole_delete_log "$mode" "$size_kb" "sudo-blocked-test-mode" "$path"
            return 1
        fi
    fi

    # Trash mode is a recoverable-delete contract. If Trash is unavailable,
    # fail closed instead of silently switching to permanent removal.
    if [[ "$mode" == "trash" ]]; then
        local trash_rc=0
        _mole_move_to_trash "$path" "$needs_sudo" \
            "$expected_parent" "$expected_parent_id" \
            "$expected_target_id" "$expected_file_sha256" \
            "$expected_absent_path" || trash_rc=$?
        if [[ $trash_rc -eq 0 ]]; then
            _mole_delete_log "trash" "$size_kb" "ok" "$path"
            log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "TRASHED" "$path" "${size_kb}KB"
            return 0
        fi
        if [[ $trash_rc -eq $MOLE_ERR_PRIVACY_DENIED ]]; then
            _mole_record_uninstall_refusal "$path" access-denied
            _mole_delete_log "trash" "$size_kb" "privacy-denied" "$path"
            log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$path" "privacy permission denied"
            if [[ -z "${_MOLE_PRIVACY_DENIED_WARNED:-}" ]]; then
                _MOLE_PRIVACY_DENIED_WARNED=1
                export _MOLE_PRIVACY_DENIED_WARNED
                declare -F stop_inline_spinner > /dev/null && stop_inline_spinner
                printf 'Error: macOS denied Trash access. Try moving the item to Trash in Finder. Run with --debug for details.\n' >&2
            fi
            debug_log "macOS privacy permission denied while moving to Trash: $path"
            return "$MOLE_ERR_PRIVACY_DENIED"
        fi
        if [[ $trash_rc -eq $MOLE_ERR_MUTABLE_PARENT ]]; then
            _mole_delete_log "trash" "$size_kb" "mutable-parent" "$path"
            log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$path" "mutable-parent"
            debug_log "Trash move stopped because a mutable parent was detected: $path"
            return "$MOLE_ERR_MUTABLE_PARENT"
        fi
        if [[ $trash_rc -eq $MOLE_ERR_OWNER_UNVERIFIED ||
            $trash_rc -eq $MOLE_ERR_APP_REAPPEARED ]]; then
            _mole_report_unverified_delete "$path" "$mode" "$size_kb" "$trash_rc"
            return 1
        fi
        if mole_rc_timeout_or_signal "$trash_rc"; then
            local trash_status="interrupted"
            mole_rc_timeout "$trash_rc" && trash_status="timed-out"
            _mole_delete_log "trash" "$size_kb" "$trash_status" "$path"
            return "$trash_rc"
        fi
        _mole_delete_log "trash" "$size_kb" "trash-failed" "$path"
        log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$path" "trash-failed"
        if [[ -z "${_MOLE_TRASH_UNAVAILABLE_WARNED:-}" ]]; then
            _MOLE_TRASH_UNAVAILABLE_WARNED=1
            export _MOLE_TRASH_UNAVAILABLE_WARNED
            declare -F stop_inline_spinner > /dev/null && stop_inline_spinner
            printf 'Error: Trash unavailable; refusing permanent delete. Use --permanent to delete immediately.\n' >&2
        fi
        debug_log "Trash move failed, refusing permanent delete: $path"
        return 1
    fi

    # Permanent path. Delegate to the existing safe_* helpers so path
    # validation, sudo handling, and existing log_operation calls remain
    # unchanged for callers that have always gone through rm -rf.
    local rc=0
    if [[ "$needs_sudo" == "true" ]] && _mole_privileged_path_has_mutable_ancestor "$path"; then
        # Recheck at the permanent-delete sink. The parent may have become
        # mutable while size accounting was running. This check covers both
        # regular paths and symlinks before either helper can downgrade.
        rc=$MOLE_ERR_MUTABLE_PARENT
    elif [[ -L "$path" ]]; then
        safe_remove_symlink "$path" "$needs_sudo" \
            "$expected_parent" "$expected_parent_id" \
            "$expected_target_id" "$expected_file_sha256" \
            "$expected_absent_path" || rc=$?
    elif [[ "$needs_sudo" == "true" ]]; then
        safe_sudo_remove "$path" "$size_kb" "" \
            "$expected_parent" "$expected_parent_id" \
            "$expected_target_id" "$expected_file_sha256" \
            "$expected_absent_path" || rc=$?
    else
        safe_remove "$path" "true" "$size_kb" "" \
            "$expected_parent" "$expected_parent_id" \
            "$expected_target_id" "$expected_file_sha256" \
            "$expected_absent_path" || rc=$?
    fi

    local status_label="ok"
    if [[ $rc -eq $MOLE_ERR_OWNER_UNVERIFIED ||
        $rc -eq $MOLE_ERR_APP_REAPPEARED ]]; then
        _mole_report_unverified_delete "$path" "$mode" "$size_kb" "$rc"
        return 1
    fi
    if [[ $rc -eq $MOLE_ERR_MUTABLE_PARENT ]]; then
        status_label="mutable-parent"
    elif mole_rc_timeout "$rc"; then
        status_label="timed-out"
    elif [[ $rc -ge 128 ]]; then
        status_label="interrupted"
    elif [[ $rc -ne 0 ]]; then
        status_label="error"
    fi
    _mole_delete_log "$mode" "$size_kb" "$status_label" "$path"
    return "$rc"
}

_mole_valid_invoking_home() {
    local user_home=""
    if declare -f get_invoking_home > /dev/null 2>&1; then
        user_home=$(get_invoking_home)
    else
        user_home="${MOLE_USER_HOME:-${HOME:-}}"
    fi

    if [[ -z "$user_home" || "$user_home" != /* || "$user_home" == "/" || "$user_home" == "/var/root" ]]; then
        debug_log "Refusing direct Trash move: invalid invoking user home: ${user_home:-<empty>}"
        return 1
    fi

    printf '%s\n' "${user_home%/}"
}

_mole_path_is_immediate_child_of() {
    local path="${1%/}"
    local parent="${2%/}"
    [[ "$path" == "$parent/"* ]] || return 1

    local child="${path#"$parent"/}"
    [[ -n "$child" && "$child" != */* ]]
}

_mole_path_is_application_bundle() {
    local path="${1%/}"
    _mole_path_is_immediate_child_of "$path" "/Applications" &&
        [[ "${path##*/}" == *.[aA][pP][pP] ]]
}

# Finder and third-party Trash helpers can fail on app bundles and TCC-managed
# app data even after authentication. Route only these exact one-level targets
# through the direct, recoverable Trash mover.
_mole_path_requires_direct_trash() {
    local path="${1%/}"
    if _mole_path_is_application_bundle "$path"; then
        return 0
    fi

    local user_home
    user_home=$(_mole_valid_invoking_home) || return 1
    _mole_path_is_immediate_child_of "$path" "$user_home/Library/Containers" && return 0
    _mole_path_is_immediate_child_of "$path" "$user_home/Library/Group Containers" && return 0
    _mole_path_is_immediate_child_of "$path" "$user_home/Library/Application Scripts" && return 0
    return 1
}

# Refresh the process evidence for one Trash target, then rebind its physical
# identity. The process table may be reused during discovery, but a distinct app
# can start before a later item reaches the move sink; stale evidence must never
# authorize that move.
_mole_trash_target_still_safe() {
    local path="$1"
    local expected_parent="${2:-}"
    local expected_parent_id="${3:-}"
    local expected_target_id="${4:-}"
    local expected_file_sha256="${5:-}"

    _mole_reset_process_snapshot
    local live_cache_guard_rc=0
    _mole_should_refuse_live_user_cache_path "$path" || live_cache_guard_rc=$?
    if [[ $live_cache_guard_rc -eq 0 ]]; then
        _mole_record_uninstall_refusal "$path" live-cache
        debug_log "Skipped Trash move after live user cache appeared: $path"
        log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$path" "live user cache"
        return 1
    fi
    if mole_rc_timeout_or_signal "$live_cache_guard_rc"; then
        _mole_record_clean_cancellation "$live_cache_guard_rc"
        return "$live_cache_guard_rc"
    fi

    if [[ -n "$expected_parent" ]]; then
        if ! _mole_bound_path_matches "$path" "$expected_parent" \
            "$expected_parent_id" "$expected_target_id"; then
            [[ -n "$expected_file_sha256" ]] && return "$MOLE_ERR_OWNER_UNVERIFIED"
            return 1
        fi
        return 0
    fi
    _mole_bound_path_matches "$path" "$_MOLE_CONTAINER_CACHE_PROBE_PARENT" \
        "$_MOLE_CONTAINER_CACHE_PROBE_PARENT_ID" \
        "$_MOLE_CONTAINER_CACHE_PROBE_TARGET_ID"
}

# Finder's Trash API can move package-installed app bundles that macOS App
# Management blocks from a direct mv. Run it only as the invoking user and only
# for an exact one-level /Applications/*.app target selected above.
_mole_move_app_to_trash_via_finder() {
    local path="$1"
    local expected_parent="${2:-}"
    local expected_parent_id="${3:-}"
    local expected_target_id="${4:-}"
    local expected_file_sha256="${5:-}"
    local expected_absent_path="${6:-}"
    local finder_rc=0

    _mole_path_is_application_bundle "$path" || return 1
    _mole_trash_target_still_safe "$path" "$expected_parent" \
        "$expected_parent_id" "$expected_target_id" "$expected_file_sha256" || return $?
    _mole_owned_path_still_valid "$path" \
        "$expected_file_sha256" "$expected_absent_path" \
        "$expected_parent" "$expected_parent_id" "$expected_target_id" || return $?

    local finder_output=""
    finder_output=$(
        run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" osascript - "$path" 2>&1 > /dev/null << 'APPLESCRIPT'
on run argv
    set p to POSIX file (item 1 of argv)
    tell application "Finder"
        delete p
    end tell
end run
APPLESCRIPT
    ) || finder_rc=$?

    if [[ $finder_rc -ne 0 ]]; then
        debug_log "Finder failed to move application to Trash (exit $finder_rc): $path: $finder_output"
        mole_rc_timeout_or_signal "$finder_rc" && return "$finder_rc"
        if [[ "$finder_output" == *"(-1743)"* && -z "${_MOLE_FINDER_AUTOMATION_WARNED:-}" ]]; then
            _MOLE_FINDER_AUTOMATION_WARNED=1
            _MOLE_PRIVACY_DENIED_WARNED=1
            export _MOLE_PRIVACY_DENIED_WARNED
            declare -F stop_inline_spinner > /dev/null && stop_inline_spinner
            printf 'Error: macOS blocked Finder automation. Allow your terminal app to control Finder in System Settings > Privacy & Security > Automation, then retry.\n' >&2
        fi
        return 1
    elif [[ -e "$path" || -L "$path" ]]; then
        debug_log "Finder returned success but the application remains: $path"
        return 1
    fi

    debug_log "Finder moved application to Trash: $path"
    return 0
}

# Move a path to the macOS Trash. Test harnesses set MOLE_TEST_TRASH_DIR to
# redirect the move to a tmpdir, avoiding any Finder/osascript interaction.
_mole_move_to_trash() {
    local path="$1"
    local needs_sudo="${2:-false}"
    local expected_parent="${3:-}"
    local expected_parent_id="${4:-}"
    local expected_target_id="${5:-}"
    local expected_file_sha256="${6:-}"
    local expected_absent_path="${7:-}"

    # The override is test-only: an exported MOLE_TEST_TRASH_DIR in a real
    # run must not silently redirect a Trash move away from the user's Trash.
    if [[ -n "${MOLE_TEST_TRASH_DIR:-}" ]] &&
        [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        mkdir -p "$MOLE_TEST_TRASH_DIR" 2> /dev/null || return 1
        local dest="$MOLE_TEST_TRASH_DIR/$(basename "$path").$$.$(date +%s 2> /dev/null || echo 0)"
        _mole_trash_target_still_safe "$path" "$expected_parent" \
            "$expected_parent_id" "$expected_target_id" "$expected_file_sha256" || return $?
        _mole_owned_path_still_valid "$path" \
            "$expected_file_sha256" "$expected_absent_path" \
            "$expected_parent" "$expected_parent_id" "$expected_target_id" || return $?
        mv "$path" "$dest" 2> /dev/null
        return $?
    fi

    # Blocked in test mode so uninstall tests never hit Finder/AppleScript.
    if [[ "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    if [[ "$needs_sudo" == "true" ]]; then
        _mole_move_path_to_user_trash "$path" "$needs_sudo" \
            "$expected_parent" "$expected_parent_id" "$expected_target_id" \
            "$expected_file_sha256" "$expected_absent_path"
        return $?
    fi

    if _mole_path_requires_direct_trash "$path"; then
        local direct_rc=0
        _mole_move_path_to_user_trash "$path" false \
            "$expected_parent" "$expected_parent_id" \
            "$expected_target_id" "$expected_file_sha256" \
            "$expected_absent_path" || direct_rc=$?
        if [[ $direct_rc -eq $MOLE_ERR_PRIVACY_DENIED ]] &&
            _mole_path_is_application_bundle "$path"; then
            debug_log "Direct Trash move was denied; retrying application through Finder: $path"
            local finder_rc=0
            _mole_move_app_to_trash_via_finder "$path" \
                "$expected_parent" "$expected_parent_id" \
                "$expected_target_id" "$expected_file_sha256" \
                "$expected_absent_path" || finder_rc=$?
            [[ $finder_rc -eq 0 ]] && return 0
            mole_rc_timeout_or_signal "$finder_rc" && return "$finder_rc"
        fi
        return "$direct_rc"
    fi

    # Prefer the `trash` CLI (Homebrew formula) for normal user-owned paths.
    if command -v trash > /dev/null 2>&1; then
        local trash_rc=0
        _mole_trash_target_still_safe "$path" "$expected_parent" \
            "$expected_parent_id" "$expected_target_id" "$expected_file_sha256" || return $?
        _mole_owned_path_still_valid "$path" \
            "$expected_file_sha256" "$expected_absent_path" \
            "$expected_parent" "$expected_parent_id" "$expected_target_id" || return $?
        run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
            trash "$path" > /dev/null 2>&1 || trash_rc=$?
        [[ $trash_rc -eq 0 ]] && return 0
        mole_rc_timeout_or_signal "$trash_rc" && return "$trash_rc"
    fi

    # AppleScript fallback. Pass the path via argv so special chars (quotes,
    # backslashes) cannot break out of the quoted string.
    _mole_trash_target_still_safe "$path" "$expected_parent" \
        "$expected_parent_id" "$expected_target_id" "$expected_file_sha256" || return $?
    _mole_owned_path_still_valid "$path" \
        "$expected_file_sha256" "$expected_absent_path" \
        "$expected_parent" "$expected_parent_id" "$expected_target_id" || return $?
    run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
        osascript - "$path" > /dev/null 2>&1 << 'APPLESCRIPT'
on run argv
    set p to POSIX file (item 1 of argv)
    tell application "Finder"
        delete p
    end tell
end run
APPLESCRIPT
}

# /Library/Caches is mode 0777 on supported macOS releases, so it cannot anchor a
# privileged path operation. This prepares an exact root-owned parent under
# immutable /Library; mode 0711 lets the invoking user traverse into only the
# randomized staging directory handed to them later.
#
# Takes the root as an argument so the concurrency behaviour is reachable from a
# test without a real /Library write.
_mole_prepare_privileged_trash_stage_root() {
    local stage_root="$1"

    # Refuse an existing symlink before any ownership or mode operation. Only
    # root can mutate /Library, but a stale privileged symlink must not make
    # chown/chmod follow into an unrelated tree. Then mkdir -p rather than
    # test-then-mkdir: two concurrent Mole processes can both see a missing root,
    # and the loser of a plain mkdir would abort a Trash move that was safe.
    # Tolerating EEXIST costs nothing, because the verification below is what
    # actually decides whether this root can anchor the operation.
    if [[ -L "$stage_root" ]]; then
        return 1
    fi
    sudo -n /bin/mkdir -p "$stage_root" 2> /dev/null || return 1
    sudo -n /usr/sbin/chown 0:0 "$stage_root" 2> /dev/null || return 1
    sudo -n /bin/chmod -N "$stage_root" 2> /dev/null || return 1
    sudo -n /bin/chmod 711 "$stage_root" 2> /dev/null || return 1

    local root_uid=""
    local root_mode=""
    root_uid=$($STAT_BSD -f%u "$stage_root" 2> /dev/null || true)
    root_mode=$($STAT_BSD -f%Lp "$stage_root" 2> /dev/null || true)
    if [[ -L "$stage_root" || "$root_uid" != "0" || "$root_mode" != "711" ]]; then
        return 1
    fi
}

_mole_create_privileged_trash_stage() {
    local stage_root="/Library/MoleTrashStaging"
    local stage_dir=""

    _mole_prepare_privileged_trash_stage_root "$stage_root" || return 1

    stage_dir=$(sudo -n /usr/bin/mktemp -d "$stage_root/item.XXXXXX" 2> /dev/null) || return 1
    if [[ "$stage_dir" != "$stage_root"/item.* || ! -d "$stage_dir" || -L "$stage_dir" ]]; then
        return 1
    fi
    if _mole_privileged_path_has_mutable_ancestor "$stage_dir/item"; then
        sudo -n /bin/rm -rf "$stage_dir" 2> /dev/null || true # SAFE: exact empty staging directory created by mktemp above
        return 1
    fi
    printf '%s\n' "$stage_dir"
}

# The staging root is deliberately persistent. Removing it when it looked empty
# raced with a concurrent Mole process that had just validated it and was about
# to mktemp inside, turning a safe Trash move into a spurious failure.
#
# `mo remove` deliberately leaves it behind too. It is an empty root-owned
# directory, and removing it would add a privileged step to an uninstall that
# may need no privileges at all: a ~/.local-only install would meet a sudo
# prompt for nothing. Any non-empty state is a payload a failed Trash move
# preserved for the user, which uninstall must not touch either.

_mole_move_path_to_user_trash() {
    local path="$1"
    local needs_sudo="${2:-false}"
    local expected_parent="${3:-}"
    local expected_parent_id="${4:-}"
    local expected_target_id="${5:-}"
    local expected_file_sha256="${6:-}"
    local expected_absent_path="${7:-}"

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    local user_home
    user_home="${_MOLE_TRASH_BATCH_HOME:-}"
    [[ -n "$user_home" ]] || user_home=$(_mole_valid_invoking_home) || return 1

    if [[ -z "$path" ]] || [[ ! -e "$path" && ! -L "$path" ]]; then
        debug_log "Refusing direct Trash move: path does not exist: ${path:-<empty>}"
        return 1
    fi

    if [[ "$needs_sudo" == "true" ]] && _mole_privileged_path_has_mutable_ancestor "$path"; then
        debug_log "Refusing direct privileged Trash move below mutable parent: $path"
        return "$MOLE_ERR_MUTABLE_PARENT"
    fi

    local trash_dir="${user_home%/}/.Trash"
    local owner_uid="${_MOLE_TRASH_BATCH_UID:-}" owner_gid="${_MOLE_TRASH_BATCH_GID:-}"
    if [[ -z "$owner_uid" ]] && declare -f get_invoking_uid > /dev/null 2>&1; then
        owner_uid=$(get_invoking_uid)
    fi
    if [[ -z "$owner_gid" ]] && declare -f get_invoking_gid > /dev/null 2>&1; then
        owner_gid=$(get_invoking_gid)
    fi
    if [[ ! "$owner_uid" =~ ^[0-9]+$ || ! "$owner_gid" =~ ^[0-9]+$ ]]; then
        debug_log "Failed to resolve invoking user ownership for Trash"
        return 1
    fi

    # The destination must be the invoking user's Trash, even though sudo is
    # needed to unlink the original protected path.
    if [[ -L "$trash_dir" ]]; then
        debug_log "Refusing direct Trash move: invoking user Trash is a symlink: $trash_dir"
        return 1
    fi
    if [[ ! -d "$trash_dir" && ${EUID:-0} -eq 0 ]]; then
        sudo -n -u "#$owner_uid" mkdir -p "$trash_dir" 2> /dev/null || {
            debug_log "Failed to create invoking user Trash: $trash_dir"
            return 1
        }
    elif [[ ! -d "$trash_dir" ]] && ! mkdir -p "$trash_dir" 2> /dev/null; then
        debug_log "Failed to create invoking user Trash: $trash_dir"
        return 1
    fi
    if [[ ! -d "$trash_dir" || -L "$trash_dir" ]]; then
        debug_log "Refusing direct Trash move: invoking user Trash is not a normal directory: $trash_dir"
        return 1
    fi

    local trash_metadata="" trash_owner_uid="" trash_mode=""
    trash_metadata=$("$STAT_BSD" -f '%u:%Lp' "$trash_dir" 2> /dev/null) || return 1
    trash_owner_uid="${trash_metadata%%:*}"
    trash_mode="${trash_metadata#*:}"
    if [[ "$trash_owner_uid" != "$owner_uid" ]]; then
        debug_log "Refusing direct Trash move: invoking user does not own Trash: $trash_dir"
        return 1
    fi
    if [[ "$trash_mode" != 700 && ${EUID:-0} -eq 0 ]]; then
        if ! sudo -n -u "#$owner_uid" chmod 700 "$trash_dir" 2> /dev/null; then
            debug_log "Failed to set invoking user Trash permissions: $trash_dir"
            return 1
        fi
    elif [[ "$trash_mode" != 700 ]] && ! chmod 700 "$trash_dir" 2> /dev/null; then
        debug_log "Failed to set invoking user Trash permissions: $trash_dir"
        return 1
    fi

    # Avoid Finder-style ':' path weirdness and keep generated names filesystem-safe.
    local base
    base="$path"
    while [[ "$base" == */ && "$base" != / ]]; do base="${base%/}"; done
    base="${base##*/}"
    base="${base//:/__}"
    base="${base//\//__}"
    [[ -n "$base" && "$base" != "." && "$base" != ".." ]] || base="mole-trash-item"

    local dest="$trash_dir/$base"
    local ts suffix
    ts=""
    suffix=0

    while [[ -e "$dest" || -L "$dest" ]]; do
        suffix=$((suffix + 1))
        if [[ $suffix -gt 100 ]]; then
            debug_log "Failed to choose unique Trash destination for: $path"
            return 1
        fi
        [[ -n "$ts" ]] || ts=$(date +%s 2> /dev/null || echo 0)
        dest="$trash_dir/$base.$ts.$$.$suffix"
    done

    if [[ -n "$expected_parent" ]]; then
        if ! _mole_path_matches_identity \
            "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
            debug_log "Refusing Trash move after selected path identity changed: $path"
            return 1
        fi
    elif [[ -n "${_MOLE_TRASH_MOVE_EXPECTED_PATH:-}" && "$_MOLE_TRASH_MOVE_EXPECTED_PATH" == "$path" ]]; then
        if ! _mole_path_matches_identity \
            "$path" \
            "$_MOLE_TRASH_MOVE_EXPECTED_PARENT" \
            "$_MOLE_TRASH_MOVE_EXPECTED_PARENT_ID" \
            "$_MOLE_TRASH_MOVE_EXPECTED_TARGET_ID"; then
            debug_log "Refusing Trash move after source path identity changed: $path"
            return 1
        fi
    fi

    local move_output=""
    local move_rc=0
    if [[ "$needs_sudo" == "true" ]]; then
        # Never point a root mv directly into ~/.Trash: that directory is
        # intentionally controlled by the invoking user and can be replaced
        # after validation. First cross the privileged boundary into a
        # root-owned staging directory, then perform the final Trash move with
        # only the invoking user's authority.
        local stage_dir=""
        local stage_path=""
        stage_dir=$(_mole_create_privileged_trash_stage) || {
            debug_log "Failed to create immutable Trash staging directory"
            return 1
        }
        stage_path="$stage_dir/item"

        # The first move must be a same-filesystem rename. A cross-volume mv
        # degrades into copy-then-delete and can leave the only payload split
        # between source and staging if it fails midway.
        local source_device=""
        local stage_device=""
        local device_rc=0
        source_device=$($STAT_BSD -f%d "$path" 2> /dev/null) || device_rc=$?
        mole_rc_timeout_or_signal "$device_rc" && return "$device_rc"
        if [[ $device_rc -eq 0 ]]; then
            stage_device=$($STAT_BSD -f%d "$stage_dir" 2> /dev/null) || device_rc=$?
        fi
        mole_rc_timeout_or_signal "$device_rc" && return "$device_rc"
        if [[ ! "$source_device" =~ ^[0-9]+$ || "$source_device" != "$stage_device" ]]; then
            sudo -n /bin/rm -rf "$stage_dir" 2> /dev/null || true # SAFE: exact empty staging directory created by mktemp above
            debug_log "Refusing cross-volume privileged Trash staging: $path"
            return 1
        fi

        local stage_move_rc=0
        local stage_guard_rc=0
        _mole_trash_target_still_safe "$path" "$expected_parent" \
            "$expected_parent_id" "$expected_target_id" \
            "$expected_file_sha256" || stage_guard_rc=$?
        if [[ $stage_guard_rc -eq 0 ]]; then
            _mole_owned_path_still_valid "$path" \
                "$expected_file_sha256" "$expected_absent_path" \
                "$expected_parent" "$expected_parent_id" "$expected_target_id" || stage_guard_rc=$?
        fi
        if [[ $stage_guard_rc -ne 0 ]]; then
            sudo -n /bin/rm -rf "$stage_dir" 2> /dev/null || true # SAFE: exact empty root-owned stage created for this item above
            return "$stage_guard_rc"
        fi
        sudo -n /bin/mv "$path" "$stage_path" 2> /dev/null || stage_move_rc=$?
        if [[ $stage_move_rc -ne 0 ]]; then
            if mole_rc_timeout_or_signal "$stage_move_rc"; then
                if [[ -e "$stage_path" || -L "$stage_path" ]]; then
                    log_error "Trash move interrupted; item preserved for recovery at: $stage_path"
                fi
                return "$stage_move_rc"
            fi
            sudo -n /bin/rm -rf "$stage_dir" 2> /dev/null || true # SAFE: exact root-owned directory created by mktemp above
            debug_log "Failed to move path into immutable Trash staging: $path"
            return 1
        fi
        # Keep the stage root-owned while ownership is repaired. `-h` keeps chown
        # off symlink targets, and `-x` keeps it from descending into a nested
        # mount: the same-device gate above only compares the payload root with
        # the stage, so a disk image or FUSE volume mounted *inside* the payload
        # is still reachable, and chown -R would rewrite ownership on that
        # filesystem and can block on it. Once either payload ownership or stage
        # ownership changes, preserve on any later failure rather than
        # reintroducing user-owned content into the privileged source path.
        local handoff_rc=0
        sudo -n /bin/chmod 700 "$stage_dir" 2> /dev/null || handoff_rc=$?
        if [[ $handoff_rc -eq 0 ]]; then
            sudo -n /usr/sbin/chown -Rhx "$owner_uid:$owner_gid" \
                "$stage_path" 2> /dev/null || handoff_rc=$?
        fi
        if [[ $handoff_rc -eq 0 ]]; then
            sudo -n /usr/sbin/chown "$owner_uid:$owner_gid" \
                "$stage_dir" 2> /dev/null || handoff_rc=$?
        fi
        if [[ $handoff_rc -ne 0 ]]; then
            if mole_rc_timeout_or_signal "$handoff_rc"; then
                log_error "Trash move interrupted; item preserved for recovery at: $stage_path"
                return "$handoff_rc"
            fi
            log_error "Trash move failed; item preserved for recovery at: $stage_path"
            debug_log "Failed to hand Trash staging directory to invoking user"
            return 1
        fi

        if [[ ${EUID:-0} -eq 0 ]]; then
            move_output=$(sudo -n -u "#$owner_uid" /bin/mv -n "$stage_path" "$dest" 2>&1) || move_rc=$?
        else
            move_output=$(/bin/mv -n "$stage_path" "$dest" 2>&1) || move_rc=$?
        fi

        if [[ $move_rc -ne 0 || -e "$stage_path" || -L "$stage_path" ]]; then
            if mole_rc_timeout_or_signal "$move_rc"; then
                if [[ -e "$stage_path" || -L "$stage_path" ]]; then
                    log_error "Trash move interrupted; item preserved for recovery at: $stage_path"
                elif [[ -e "$dest" || -L "$dest" ]]; then
                    debug_log "Trash move completed before interruption was observed: $dest"
                fi
                return "$move_rc"
            fi
            move_rc=1
            # stage_dir is user-controlled after the ownership handoff above.
            # Never let root resolve stage_path again: it may have been replaced
            # between the failed user move and this branch. Preserve the item
            # in staging and report the exact recovery location instead.
            log_error "Trash move failed; item preserved for recovery at: $stage_path"
        else
            # The invoking user owns stage_dir but has no write bit on the
            # root-owned 0711 parent, so only a privileged rmdir can unlink it.
            sudo -n /bin/rmdir "$stage_dir" 2> /dev/null || true
        fi
    else
        _mole_trash_target_still_safe "$path" "$expected_parent" \
            "$expected_parent_id" "$expected_target_id" "$expected_file_sha256" || return $?
        _mole_owned_path_still_valid "$path" \
            "$expected_file_sha256" "$expected_absent_path" \
            "$expected_parent" "$expected_parent_id" "$expected_target_id" || return $?
        move_output=$(mv -n "$path" "$dest" 2>&1) || move_rc=$?
    fi
    if [[ $move_rc -ne 0 ]]; then
        mole_rc_timeout_or_signal "$move_rc" && return "$move_rc"
        debug_log "Failed to move path directly to invoking user Trash: $path -> $dest: $move_output"
        case "$move_output" in
            *"Operation not permitted"* | *"operation not permitted"* | \
                *"Permission denied"* | *"permission denied"*)
                _mole_record_uninstall_refusal "$path" access-denied
                return "$MOLE_ERR_PRIVACY_DENIED"
                ;;
        esac
        return 1
    fi
    if [[ -e "$path" || -L "$path" ]] || [[ ! -e "$dest" && ! -L "$dest" ]]; then
        debug_log "Failed to move path directly without overwriting destination: $path -> $dest"
        return 1
    fi

    debug_log "Moved path directly to invoking user Trash: $path -> $dest"
    return 0
}

# Batched Trash move for non-sudo, non-symlink paths. Removes the per-file
# Finder/AppleScript fan-out that made uninstalls feel frozen. The caller binds
# each item to its original physical parent and inode through the snapshot
# arrays below; this helper rechecks that identity before every direct move.
_MOLE_TRASH_BATCH_SNAPSHOT_PATHS=()
_MOLE_TRASH_BATCH_SNAPSHOT_PARENTS=()
_MOLE_TRASH_BATCH_SNAPSHOT_PARENT_IDS=()
_MOLE_TRASH_BATCH_SNAPSHOT_TARGET_IDS=()
_MOLE_TRASH_BATCH_MOVED_PATHS=()
_MOLE_TRASH_MOVE_EXPECTED_PATH=""
_MOLE_TRASH_MOVE_EXPECTED_PARENT=""
_MOLE_TRASH_MOVE_EXPECTED_PARENT_ID=""
_MOLE_TRASH_MOVE_EXPECTED_TARGET_ID=""

_MOLE_PATH_SNAPSHOT_PARENT=""
_MOLE_PATH_SNAPSHOT_PARENT_ID=""
_MOLE_PATH_SNAPSHOT_TARGET_ID=""

_mole_snapshot_path_identity() {
    local path="$1"
    _MOLE_PATH_SNAPSHOT_PARENT=""
    _MOLE_PATH_SNAPSHOT_PARENT_ID=""
    _MOLE_PATH_SNAPSHOT_TARGET_ID=""

    [[ -e "$path" || -L "$path" ]] || return 1
    local lexical_parent="${path%/*}"
    [[ -n "$lexical_parent" && "$lexical_parent" != "$path" ]] || lexical_parent="/"

    local physical_parent=""
    physical_parent=$(cd -P "$lexical_parent" 2> /dev/null && pwd -P) || return 1
    local parent_id=""
    local target_id=""
    local identities=""
    identities=$("$STAT_BSD" -f '%d:%i' "$physical_parent" "$path" 2> /dev/null) || return 1
    [[ "$identities" == *$'\n'* ]] || return 1
    parent_id="${identities%%$'\n'*}"
    target_id="${identities#*$'\n'}"
    [[ "$parent_id" =~ ^[0-9]+:[0-9]+$ && "$target_id" =~ ^[0-9]+:[0-9]+$ ]] || return 1

    _MOLE_PATH_SNAPSHOT_PARENT="$physical_parent"
    _MOLE_PATH_SNAPSHOT_PARENT_ID="$parent_id"
    _MOLE_PATH_SNAPSHOT_TARGET_ID="$target_id"
}

_mole_path_matches_identity() {
    local path="$1"
    local expected_parent="$2"
    local expected_parent_id="$3"
    local expected_target_id="$4"

    _mole_snapshot_path_identity "$path" || return 1
    [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$expected_parent" ]] || return 1
    [[ "$_MOLE_PATH_SNAPSHOT_PARENT_ID" == "$expected_parent_id" ]] || return 1
    [[ "$_MOLE_PATH_SNAPSHOT_TARGET_ID" == "$expected_target_id" ]]
}

_mole_bound_path_matches() {
    local path="$1"
    local expected_parent="${2:-}"
    local expected_parent_id="${3:-}"
    local expected_target_id="${4:-}"
    [[ -z "$expected_parent" ]] && return 0
    _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"
}

_mole_move_to_trash_batch() {
    local -a paths=("$@")
    [[ ${#paths[@]} -eq 0 ]] && return 0
    _MOLE_TRASH_BATCH_MOVED_PATHS=()

    local use_bound_snapshots=false
    if [[ ${#_MOLE_TRASH_BATCH_SNAPSHOT_PATHS[@]} -eq ${#paths[@]} &&
        ${#_MOLE_TRASH_BATCH_SNAPSHOT_PARENTS[@]} -eq ${#paths[@]} &&
        ${#_MOLE_TRASH_BATCH_SNAPSHOT_PARENT_IDS[@]} -eq ${#paths[@]} &&
        ${#_MOLE_TRASH_BATCH_SNAPSHOT_TARGET_IDS[@]} -eq ${#paths[@]} ]]; then
        use_bound_snapshots=true
    fi

    local -a expected_parents=()
    local -a expected_parent_ids=()
    local -a expected_target_ids=()
    local index p
    for ((index = 0; index < ${#paths[@]}; index++)); do
        p="${paths[$index]}"
        if [[ "$use_bound_snapshots" == "true" ]]; then
            [[ "${_MOLE_TRASH_BATCH_SNAPSHOT_PATHS[$index]}" == "$p" ]] || return 1
            expected_parents+=("${_MOLE_TRASH_BATCH_SNAPSHOT_PARENTS[$index]}")
            expected_parent_ids+=("${_MOLE_TRASH_BATCH_SNAPSHOT_PARENT_IDS[$index]}")
            expected_target_ids+=("${_MOLE_TRASH_BATCH_SNAPSHOT_TARGET_IDS[$index]}")
        else
            _mole_snapshot_path_identity "$p" || return 1
            expected_parents+=("$_MOLE_PATH_SNAPSHOT_PARENT")
            expected_parent_ids+=("$_MOLE_PATH_SNAPSHOT_PARENT_ID")
            expected_target_ids+=("$_MOLE_PATH_SNAPSHOT_TARGET_ID")
        fi
    done

    if [[ -n "${MOLE_TEST_TRASH_DIR:-}" ]] &&
        [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        mkdir -p "$MOLE_TEST_TRASH_DIR" 2> /dev/null || return 1
        local ts
        ts=$(date +%s 2> /dev/null || echo 0)
        local dest
        for ((index = 0; index < ${#paths[@]}; index++)); do
            p="${paths[$index]}"
            _mole_trash_target_still_safe \
                "$p" \
                "${expected_parents[$index]}" \
                "${expected_parent_ids[$index]}" \
                "${expected_target_ids[$index]}" || return $?
            dest="$MOLE_TEST_TRASH_DIR/$(basename "$p").$$.${ts}.$RANDOM"
            /bin/mv "$p" "$dest" 2> /dev/null || return $?
            _MOLE_TRASH_BATCH_MOVED_PATHS+=("$p")
        done
        return 0
    fi

    if [[ "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    # Stable invoking-user values are shared only for this batch. Destination
    # ownership, mode, live owners and source identity are checked per move.
    local _MOLE_TRASH_BATCH_HOME="" _MOLE_TRASH_BATCH_UID="" _MOLE_TRASH_BATCH_GID=""
    _MOLE_TRASH_BATCH_HOME=$(_mole_valid_invoking_home) || return 1
    _MOLE_TRASH_BATCH_UID=$(get_invoking_uid) || return 1
    _MOLE_TRASH_BATCH_GID=$(get_invoking_gid) || return 1

    # Avoid handing a stale lexical batch to a third-party Trash CLI or Finder.
    # Direct per-item renames keep the helper in one shell process and let us
    # recheck the bound parent/inode immediately before every move.
    local failed=0
    for ((index = 0; index < ${#paths[@]}; index++)); do
        p="${paths[$index]}"
        if ! _mole_path_matches_identity \
            "$p" \
            "${expected_parents[$index]}" \
            "${expected_parent_ids[$index]}" \
            "${expected_target_ids[$index]}"; then
            failed=1
            continue
        fi
        _MOLE_TRASH_MOVE_EXPECTED_PATH="$p"
        _MOLE_TRASH_MOVE_EXPECTED_PARENT="${expected_parents[$index]}"
        _MOLE_TRASH_MOVE_EXPECTED_PARENT_ID="${expected_parent_ids[$index]}"
        _MOLE_TRASH_MOVE_EXPECTED_TARGET_ID="${expected_target_ids[$index]}"
        local move_rc=0
        if _mole_move_path_to_user_trash "$p" false \
            "${expected_parents[$index]}" \
            "${expected_parent_ids[$index]}" \
            "${expected_target_ids[$index]}"; then
            _MOLE_TRASH_BATCH_MOVED_PATHS+=("$p")
        else
            move_rc=$?
            failed=1
        fi
        _MOLE_TRASH_MOVE_EXPECTED_PATH=""
        _MOLE_TRASH_MOVE_EXPECTED_PARENT=""
        _MOLE_TRASH_MOVE_EXPECTED_PARENT_ID=""
        _MOLE_TRASH_MOVE_EXPECTED_TARGET_ID=""
        mole_rc_timeout_or_signal "$move_rc" && return "$move_rc"
    done
    [[ $failed -eq 0 ]]
}
