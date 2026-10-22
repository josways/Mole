#!/bin/bash
# Internal deletion module. Load through file_ops.sh; do not initialize independently.
# Inputs, outcomes and failure behavior: docs/QUALITY_CONTRACTS.md.

# ============================================================================
# Safe Find and Delete Operations
# ============================================================================

# Safe file discovery and deletion with depth and age limits
safe_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"

    # Validate base directory exists and is not a symlink
    if [[ ! -d "$base_dir" ]]; then
        log_error "Directory does not exist: $base_dir"
        return 1
    fi

    if [[ -L "$base_dir" ]]; then
        log_error "Refusing to search symlinked directory: $base_dir"
        return 1
    fi

    # Validate type filter
    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter, must be 'f' or 'd'"
        return 1
    fi

    debug_log "Finding in $base_dir: $pattern, age: ${age_days}d, type: $type_filter"

    local find_args=("-maxdepth" "5" "-name" "$pattern" "-type" "$type_filter")
    if [[ "$age_days" -gt 0 ]]; then
        find_args+=("-mtime" "+$age_days")
    fi

    local scan_file=""
    if ! scan_file=$(create_temp_file 2> /dev/null); then
        return 1
    fi
    local scan_rc=0
    run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" find \
        "$base_dir" "${find_args[@]}" -print0 < /dev/null > "$scan_file" 2> /dev/null || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        debug_log "Cleanup scan failed for $base_dir (status $scan_rc)"
        return "$scan_rc"
    fi

    # Iterate only a completed result set so a timeout cannot authorize
    # deletion of the partial prefix.
    # Per-caller whitelist gates were missed in past releases (see #710, #724,
    # #738, #744, #757); enforcing here makes the protection structural so
    # new clean_* functions get whitelist enforcement for free.
    local delete_rc=0
    while IFS= read -r -d '' match; do
        if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$match"; then
            continue
        fi
        if declare -f is_path_whitelisted > /dev/null && is_path_whitelisted "$match"; then
            continue
        fi
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
            local match_size_kb=0
            local match_size_rc=0
            match_size_kb=$(get_path_size_kb "$match" "" readable 2> /dev/null) || match_size_rc=$?
            if mole_rc_timeout_or_signal "$match_size_rc"; then
                delete_rc=$match_size_rc
                break
            fi
            [[ $match_size_rc -eq 0 ]] || match_size_kb=0
            [[ "$match_size_kb" =~ ^[0-9]+$ ]] || match_size_kb=0
            record_dry_run_cleanup_target "$match" "$match_size_kb" 1 true || continue
        fi
        local remove_rc=0
        safe_remove "$match" true || remove_rc=$?
        if mole_rc_timeout_or_signal "$remove_rc"; then
            delete_rc=$remove_rc
            break
        fi
        if [[ $remove_rc -ne 0 && $delete_rc -eq 0 ]]; then
            delete_rc=$remove_rc
        fi
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    return "$delete_rc"
}

# Run privileged find with a wall-clock budget and closed stdin.
_mole_bounded_sudo_find() {
    local duration="${1:-${MOLE_TIMEOUT_DISK_VERIFY_SEC:-30}}"
    shift || true
    [[ $# -gt 0 ]] || return 2
    _mole_bounded_sudo "$duration" -n find "$@" < /dev/null
}

# Store a privileged scan only after the producer completed successfully. A
# timeout or any other failure truncates the destination so callers cannot act
# on a partial prefix.
_mole_materialize_bounded_sudo_find() {
    local output_file="$1"
    local duration="$2"
    shift 2
    [[ $# -gt 0 ]] || return 2

    : > "$output_file" || return 1
    local scan_rc=0
    _mole_bounded_sudo_find "$duration" "$@" > "$output_file" 2> /dev/null || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        : > "$output_file" || true
        return "$scan_rc"
    fi
    return 0
}

# Keep privileged batch state bounded in Bash. This is a function rather than a
# public setting so tests can exercise the limit without exposing another user
# knob or constructing thousands of command-substitution probes.
_mole_privileged_batch_max_items() {
    printf '4096\n'
}

# Safe sudo discovery and deletion
safe_sudo_find_delete() {
    local base_dir="$1"
    local pattern="$2"
    local age_days="${3:-7}"
    local type_filter="${4:-f}"
    local max_depth="${5:-5}"
    local deadline_seconds="${6:-}"
    local -a name_patterns=("$pattern")
    if [[ $# -gt 6 ]]; then
        name_patterns+=("${@:7}")
    fi

    # Callers use this count to distinguish a completed empty scan from actual
    # cleanup. It is reset for every invocation and updated only for confirmed
    # removals or accepted dry-run previews.
    MOLE_SAFE_SUDO_FIND_DELETE_COUNT=0

    if [[ "$type_filter" != "f" && "$type_filter" != "d" ]]; then
        log_error "Invalid type filter: $type_filter, must be 'f' or 'd'"
        return 1
    fi
    if [[ ! "$age_days" =~ ^[0-9]+$ ]]; then
        log_error "Invalid age: $age_days, must be a non-negative integer"
        return 1
    fi
    if [[ ! "$max_depth" =~ ^[1-5]$ ]]; then
        log_error "Invalid max depth: $max_depth, must be between 1 and 5"
        return 1
    fi
    if [[ -n "$deadline_seconds" && ! "$deadline_seconds" =~ ^[0-9]+$ ]]; then
        log_error "Invalid cleanup deadline: $deadline_seconds"
        return 1
    fi

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        debug_log "Skipping sudo find/delete in test mode: $base_dir"
        return 0
    fi

    # An already-expired overall budget authorizes no privileged probe at all.
    # Re-clamp every later probe because any preceding command can consume the
    # final second of the caller's section budget.
    _mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$deadline_seconds" > /dev/null || return $?

    # Keep the entire sudo-probing body independent of the caller's errexit
    # state. macOS 14's /bin/bash build fires the caller's errexit when a
    # sudo shell-function mock returns nonzero inside an if condition (the
    # same bash 3.2.57 on macOS 15+ does not), so the guard must sit above
    # the first sudo probe, not just around the scan/batch loop. The
    # predicates below intentionally return 1 for ordinary "not protected /
    # not whitelisted / no oplog" cases; callers still get explicit nonzero
    # returns from the validation gates, restored to their errexit state.
    local restore_errexit=0
    case $- in
        *e*)
            restore_errexit=1
            set +e
            ;;
    esac

    # Confirm noninteractive authorization before interpreting a failed path
    # predicate as "not present". Otherwise an expired credential looks like an
    # empty successful scan and callers can print a false cleanup result.
    local sudo_rc=0
    _mole_bounded_sudo_until "$deadline_seconds" "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        -n true < /dev/null > /dev/null 2>&1 || sudo_rc=$?
    if [[ $sudo_rc -ne 0 ]]; then
        [[ $restore_errexit -eq 1 ]] && set -e
        [[ $sudo_rc -ge 128 ]] && return "$sudo_rc"
        mole_rc_timeout "$sudo_rc" && return 124
        return "$MOLE_ERR_AUTH_FAILED"
    fi

    # Validate base directory (use sudo for permission-restricted dirs).
    local base_rc=0
    _mole_bounded_sudo_until "$deadline_seconds" "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        -n test -d "$base_dir" < /dev/null 2> /dev/null || base_rc=$?
    if [[ $base_rc -ne 0 ]]; then
        if [[ $base_rc -ge 128 ]]; then
            [[ $restore_errexit -eq 1 ]] && set -e
            return "$base_rc"
        fi
        if mole_rc_timeout "$base_rc"; then
            [[ $restore_errexit -eq 1 ]] && set -e
            return 124
        fi
        # `sudo test` uses status 1 both for a false predicate and for some
        # authorization failures. Recheck credentials before calling this a
        # missing directory; a credential may expire after the initial probe.
        local base_auth_rc=0
        _mole_bounded_sudo_until "$deadline_seconds" "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            -n true < /dev/null > /dev/null 2>&1 || base_auth_rc=$?
        if [[ $base_auth_rc -ne 0 ]]; then
            [[ $restore_errexit -eq 1 ]] && set -e
            [[ $base_auth_rc -ge 128 ]] && return "$base_auth_rc"
            mole_rc_timeout "$base_auth_rc" && return 124
            return "$MOLE_ERR_AUTH_FAILED"
        fi
        debug_log "Directory does not exist, skipping: $base_dir"
        [[ $restore_errexit -eq 1 ]] && set -e
        return 0
    fi

    local link_rc=0
    _mole_bounded_sudo_until "$deadline_seconds" "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        -n test -L "$base_dir" < /dev/null 2> /dev/null || link_rc=$?
    if [[ $link_rc -eq 0 ]]; then
        log_error "Refusing to search symlinked directory: $base_dir"
        [[ $restore_errexit -eq 1 ]] && set -e
        return 1
    fi
    if mole_rc_timeout "$link_rc"; then
        [[ $restore_errexit -eq 1 ]] && set -e
        return 124
    fi
    if [[ $link_rc -ge 128 ]]; then
        [[ $restore_errexit -eq 1 ]] && set -e
        return "$link_rc"
    fi
    if [[ $link_rc -eq 1 ]]; then
        local link_auth_rc=0
        _mole_bounded_sudo_until "$deadline_seconds" "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            -n true < /dev/null > /dev/null 2>&1 || link_auth_rc=$?
        if [[ $link_auth_rc -ne 0 ]]; then
            [[ $restore_errexit -eq 1 ]] && set -e
            [[ $link_auth_rc -ge 128 ]] && return "$link_auth_rc"
            mole_rc_timeout "$link_auth_rc" && return 124
            return "$MOLE_ERR_AUTH_FAILED"
        fi
    fi
    if [[ $link_rc -ne 1 ]]; then
        [[ $restore_errexit -eq 1 ]] && set -e
        return "$link_rc"
    fi

    debug_log "Finding, sudo, in $base_dir: $pattern, age: ${age_days}d, type: $type_filter"

    local find_args=("-maxdepth" "$max_depth")
    local match_all_names=false
    local name_pattern=""
    for name_pattern in "${name_patterns[@]}"; do
        if [[ "$name_pattern" == "*" ]]; then
            match_all_names=true
            break
        fi
    done
    if [[ "$match_all_names" != "true" ]]; then
        if [[ ${#name_patterns[@]} -eq 1 ]]; then
            find_args+=("-name" "${name_patterns[0]}")
        else
            find_args+=("(")
            local pattern_index=0
            for ((pattern_index = 0; pattern_index < ${#name_patterns[@]}; pattern_index++)); do
                [[ $pattern_index -gt 0 ]] && find_args+=("-o")
                find_args+=("-name" "${name_patterns[$pattern_index]}")
            done
            find_args+=(")")
        fi
    fi
    find_args+=("-type" "$type_filter")
    if [[ "$age_days" -gt 0 ]]; then
        find_args+=("-mtime" "+$age_days")
    fi

    # Materialize the completed scan before deleting anything. Process
    # substitution cannot expose the producer's exit status, so it previously
    # turned timeout 124 into an empty/partial successful scan and could delete
    # the partial prefix. A failed scan now authorizes no deletion.
    local scan_file=""
    if ! scan_file=$(create_temp_file 2> /dev/null); then
        [[ $restore_errexit -eq 1 ]] && set -e
        return 1
    fi
    local scan_rc=0
    local scan_timeout=""
    scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
        "$deadline_seconds") || scan_rc=$?
    if [[ $scan_rc -eq 0 ]]; then
        _mole_materialize_bounded_sudo_find "$scan_file" "$scan_timeout" \
            "$base_dir" "${find_args[@]}" -print0 || scan_rc=$?
    fi
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        debug_log "Privileged cleanup scan failed for $base_dir (status $scan_rc)"
        [[ $restore_errexit -eq 1 ]] && set -e
        return "$scan_rc"
    fi

    # Iterate results to respect both system protection and user whitelist.
    # See safe_find_delete for rationale (#757).
    #
    # Regular files are removed in one privileged xargs batch instead of one
    # safe_sudo_remove per match: the single-file path costs three sudo forks
    # per file (test -e, du, rm), which turns a sweep over a stale .logarchive
    # bundle (1000+ tracev3 files) into minutes. Every path still passes the
    # same per-file gates before entering the batch; only the rm is batched.
    # Directories and dry-run keep the single-file path so rm -rf handling
    # and preview output stay unchanged.
    local -a batch_files=()
    local -a batch_identities=()
    local max_batch_items=""
    max_batch_items=$(_mole_privileged_batch_max_items)
    [[ "$max_batch_items" =~ ^[1-9][0-9]*$ ]] || max_batch_items=4096
    local removed_count=0
    local delete_rc=0
    local deadline_reached=false
    local batch_aborted=false
    while IFS= read -r -d '' match; do
        if [[ -n "$deadline_seconds" && $SECONDS -ge $deadline_seconds ]]; then
            deadline_reached=true
            delete_rc=124
            break
        fi
        if should_protect_path "$match"; then
            continue
        fi
        # Fast-path the active family before the general validator below. The
        # validator remains authoritative and also normalizes dot aliases so
        # preview and real cleanup cannot diverge.
        if _mole_is_active_powerlog_database_path "$match"; then
            continue
        fi
        if declare -f is_path_whitelisted > /dev/null && is_path_whitelisted "$match"; then
            continue
        fi
        # Run the same final path policy before preview accounting and real
        # removal. This keeps aliases such as /./ and case variants out of
        # both surfaces instead of relying on a raw-string precheck.
        if ! validate_path_for_deletion "$match"; then
            continue
        fi
        if _mole_privileged_path_has_mutable_ancestor "$match"; then
            # A privileged path-based delete cannot safely cross a directory
            # the invoking user can rename or replace. Delete only with the
            # caller's own permissions; root invocations skip the path because
            # they have no unprivileged identity to fall back to.
            if [[ ${EUID:-0} -ne 0 ]]; then
                local mutable_rc=0
                safe_remove "$match" true "" "$deadline_seconds" || mutable_rc=$?
                if [[ $mutable_rc -eq 0 ]]; then
                    removed_count=$((removed_count + 1))
                elif mole_rc_timeout_or_signal "$mutable_rc"; then
                    delete_rc=$mutable_rc
                    break
                elif [[ $delete_rc -eq 0 ]]; then
                    delete_rc=$mutable_rc
                fi
            else
                debug_log "Skipping sudo delete below mutable parent: $match"
                [[ $delete_rc -eq 0 ]] && delete_rc=1
            fi
            continue
        fi
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
            local match_size_kb=0
            local match_size_known=false
            local raw_match_size=""
            local size_timeout=""
            local dry_size_rc=0
            size_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                "$deadline_seconds") || dry_size_rc=$?
            if [[ $dry_size_rc -eq 0 ]]; then
                raw_match_size=$(_mole_bounded_sudo "$size_timeout" \
                    -n du -skP "$match" < /dev/null 2> /dev/null | awk '{print $1; exit}') || dry_size_rc=$?
            fi
            if mole_rc_timeout_or_signal "$dry_size_rc"; then
                delete_rc=$dry_size_rc
                break
            elif [[ $dry_size_rc -eq 0 ]]; then
                if [[ "$raw_match_size" =~ ^[0-9]+$ ]]; then
                    match_size_kb="$raw_match_size"
                    match_size_known=true
                fi
            fi
            record_dry_run_cleanup_target "$match" "$match_size_kb" 1 "$match_size_known" || continue
        fi
        # -type f never emits symlinks; a path that is one now was swapped
        # after find saw it, and the single-file path refuses those.
        if [[ "$type_filter" == "f" && "${MOLE_DRY_RUN:-0}" != "1" && ! -L "$match" ]]; then
            local identity_timeout=""
            local match_identity=""
            local identity_rc=0
            identity_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                "$deadline_seconds") || identity_rc=$?
            if [[ $identity_rc -eq 0 ]]; then
                match_identity=$(_mole_bounded_sudo "$identity_timeout" \
                    -n "$STAT_BSD" -f%d:%i:%m "$match" < /dev/null 2> /dev/null) || identity_rc=$?
            fi
            if mole_rc_timeout_or_signal "$identity_rc"; then
                delete_rc=$identity_rc
                break
            fi
            if [[ $identity_rc -eq 0 && "$match_identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]]; then
                if [[ ${#batch_files[@]} -ge $max_batch_items ]]; then
                    debug_log "Privileged cleanup candidate limit reached for $base_dir"
                    delete_rc=1
                    batch_aborted=true
                    break
                fi
                batch_files+=("$match")
                batch_identities+=("$match_identity")
            elif [[ $delete_rc -eq 0 ]]; then
                delete_rc=${identity_rc:-1}
                [[ $delete_rc -ne 0 ]] || delete_rc=1
            fi
            continue
        fi
        local single_rc=0
        safe_sudo_remove "$match" "" "$deadline_seconds" || single_rc=$?
        if [[ $single_rc -eq 0 ]]; then
            removed_count=$((removed_count + 1))
        elif mole_rc_timeout_or_signal "$single_rc"; then
            delete_rc=$single_rc
            break
        elif [[ $delete_rc -eq 0 ]]; then
            delete_rc=$single_rc
        fi
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    if [[ -n "$deadline_seconds" && $SECONDS -ge $deadline_seconds ]]; then
        deadline_reached=true
        if [[ $delete_rc -lt 128 ]]; then
            delete_rc=124
        fi
    fi

    if [[ ${#batch_files[@]} -gt 0 && "$deadline_reached" != "true" && "$batch_aborted" != "true" ]] && ! mole_rc_timeout_or_signal "$delete_rc"; then
        local batch_rc=0
        local batch_result_file=""
        local batch_timeout=""
        if ! batch_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
            "$deadline_seconds"); then
            batch_rc=124
        elif ! batch_result_file=$(create_temp_file 2> /dev/null); then
            batch_rc=1
        else
            # The privileged worker acknowledges each completed unlink with a
            # NUL-delimited path. A later failure or timeout therefore cannot
            # erase the forensic record for an already completed prefix.
            local -a batch_worker_records=()
            local batch_index=0
            for ((batch_index = 0; batch_index < ${#batch_files[@]}; batch_index++)); do
                batch_worker_records+=("${batch_identities[$batch_index]}:${batch_files[$batch_index]}")
            done
            # shellcheck disable=SC2016 # $path expands inside privileged /bin/sh.
            printf '%s\0' "${batch_worker_records[@]}" |
                _mole_bounded_sudo "$batch_timeout" \
                    -n xargs -0 /bin/sh -c '
                        stat_tool=$1
                        age_days=$2
                        shift 2
                        for record do
                            dev=${record%%:*}
                            rest=${record#*:}
                            ino=${rest%%:*}
                            rest=${rest#*:}
                            mtime=${rest%%:*}
                            path=${rest#*:}
                            expected=$dev:$ino:$mtime
                            if [ "$age_days" -gt 0 ]; then
                                actual=$(/usr/bin/find "$path" -maxdepth 0 -type f -mtime "+$age_days" \
                                    -exec "$stat_tool" -f%d:%i:%m {} \; 2>/dev/null) || continue
                            else
                                actual=$($stat_tool -f%d:%i:%m "$path" 2>/dev/null) || continue
                            fi
                            [ "$actual" = "$expected" ] || continue
                            /bin/rm -f -- "$path" || exit 1
                            printf "%s\0" "$path"
                        done
                    ' sh "$STAT_BSD" "$age_days" > "$batch_result_file" 2> /dev/null || batch_rc=$?

            local batch_ts=""
            local batch_command=""
            if oplog_enabled; then
                batch_ts=$(get_timestamp)
                operation_log_command batch_command "${MOLE_CURRENT_COMMAND:-clean}"
            fi
            local batch_ack_count=0
            local -a removed_lines=()
            local batch_file=""
            while IFS= read -r -d '' batch_file; do
                batch_ack_count=$((batch_ack_count + 1))
                if [[ -n "$batch_ts" ]]; then
                    removed_lines+=("[$batch_ts] [$batch_command] REMOVED $batch_file (batch)")
                fi
            done < "$batch_result_file"
            rm -f -- "$batch_result_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

            removed_count=$((removed_count + batch_ack_count))
            if [[ ${#removed_lines[@]} -gt 0 ]]; then
                append_log_lines "$OPERATIONS_LOG_FILE" "${removed_lines[@]}"
            fi
            if [[ $batch_rc -eq 0 && $batch_ack_count -ne ${#batch_files[@]} ]]; then
                batch_rc=1
            fi
        fi

        if [[ $batch_rc -ne 0 && $delete_rc -eq 0 ]]; then
            delete_rc=$batch_rc
            log_operation "${MOLE_CURRENT_COMMAND:-clean}" "FAILED" "$base_dir" \
                "batch removal incomplete (status $batch_rc)"
        fi
    fi

    MOLE_SAFE_SUDO_FIND_DELETE_COUNT=$removed_count

    if [[ $restore_errexit -eq 1 ]]; then
        set -e
    fi

    return "$delete_rc"
}
