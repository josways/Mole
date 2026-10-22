#!/bin/bash

set -euo pipefail

# Bundle-supplied display names can carry terminal control bytes. These render
# sites only sanitize the text they print; stored names and every matching or
# removal decision keep the original bytes.
_uninstall_display_text() {
    mole_terminal_safe_text "${1:-}"
}

# Ensure common.sh is loaded.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[[ -z "${MOLE_COMMON_LOADED:-}" ]] && source "$SCRIPT_DIR/lib/core/common.sh"

# Load Homebrew cask support (provides get_brew_cask_name, brew_uninstall_cask)
[[ -f "$SCRIPT_DIR/lib/uninstall/brew.sh" ]] && source "$SCRIPT_DIR/lib/uninstall/brew.sh"

# Load Steam launcher detection (identifies shortcut-only app bundles)
[[ -f "$SCRIPT_DIR/lib/uninstall/steam.sh" ]] && source "$SCRIPT_DIR/lib/uninstall/steam.sh"

source "$SCRIPT_DIR/lib/uninstall/review.sh"
source "$SCRIPT_DIR/lib/uninstall/config_refs.sh"

# Batch uninstall with a single confirmation.

is_uninstall_dry_run() {
    [[ "${MOLE_DRY_RUN:-0}" == "1" ]]
}

# High-performance sensitive data detection (pure Bash, no subprocess)
# Faster than grep for batch operations, especially when processing many apps
has_sensitive_data() {
    local files="$1"
    [[ -z "$files" ]] && return 1

    while IFS= read -r file; do
        [[ -z "$file" ]] && continue

        # Use Bash native pattern matching (faster than spawning grep)
        case "$file" in
            */.warp* | */.config/* | */themes/* | */settings/* | */User\ Data/* | \
                */.ssh/* | */.gnupg/* | */Documents/* | */Preferences/*.plist | \
                */Desktop/* | */Downloads/* | */Movies/* | */Music/* | */Pictures/* | \
                */.password* | */.token* | */.auth* | */keychain* | \
                */Passwords/* | */Accounts/* | */Cookies/* | \
                */.aws/* | */.docker/config.json | */.kube/* | \
                */credentials/* | */secrets/*)
                return 0 # Found sensitive data
                ;;
        esac
    done <<< "$files"

    return 1 # Not found
}

# Decode and validate base64 file list (safe for set -e).
decode_file_list() {
    local encoded="$1"
    local app_name="$2"
    local decoded

    # macOS uses -D, GNU uses -d. Always return 0 for set -e safety.
    if ! decoded=$(printf '%s' "$encoded" | base64 -D 2> /dev/null); then
        if ! decoded=$(printf '%s' "$encoded" | base64 -d 2> /dev/null); then
            log_error "Failed to decode file list for $app_name" >&2
            echo ""
            return 0 # Return success with empty string
        fi
    fi

    if [[ "$decoded" =~ $'\0' ]]; then
        log_warning "File list for $app_name contains null bytes, rejecting" >&2
        echo ""
        return 0 # Return success with empty string
    fi

    while IFS= read -r line; do
        if [[ -n "$line" && ! "$line" =~ ^/ ]]; then
            log_warning "Invalid path in file list for $app_name: $line" >&2
            echo ""
            return 0 # Return success with empty string
        fi
    done <<< "$decoded"

    echo "$decoded"
    return 0
}

# Decode a base64 blob of login-item helper bundle ids. Unlike
# decode_file_list, the lines are bundle ids, not absolute paths, so the
# leading-slash check there would reject every id, print a misleading
# "Invalid path" warning, and blank the whole list, silently skipping the
# launchctl bootout of the app's login item helpers. Per-line validation
# stays in bootout_login_item_helpers via mole_is_reverse_dns_bundle_id.
decode_bundle_id_list() {
    local encoded="$1"
    local app_name="$2"
    local decoded

    # macOS uses -D, GNU uses -d. Always return 0 for set -e safety.
    if ! decoded=$(printf '%s' "$encoded" | base64 -D 2> /dev/null); then
        if ! decoded=$(printf '%s' "$encoded" | base64 -d 2> /dev/null); then
            log_error "Failed to decode helper id list for $app_name" >&2
            echo ""
            return 0
        fi
    fi

    if [[ "$decoded" =~ $'\0' ]]; then
        log_warning "Helper id list for $app_name contains null bytes, rejecting" >&2
        echo ""
        return 0
    fi

    echo "$decoded"
    return 0
}
# Note: find_app_files() is in lib/core/app_protection.sh, calculate_total_size() is in lib/core/file_ops.sh.

# Only a background job that is still loaded in launchd, meaning the bootout
# was missed or failed, deserves a summary warning. BTM registration records
# are kept for uninstalled apps on purpose (they restore the user's
# enable/disable choice on a reinstall) and are pruned at the next login.
# Args: $1 - app bundle id, $2 - newline-separated helper bundle ids.
# Returns 0 when any of the labels is still loaded in the user's launchd
# domain. In test mode report "not loaded" so summaries stay quiet; unit
# tests exercise the real branch with MOLE_TEST_MODE=0 and a launchctl mock.
_uninstall_background_job_loaded() {
    local bundle_id="$1"
    local helper_ids="${2:-}"

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi

    local uid label
    uid=$(id -u)
    while IFS= read -r label; do
        [[ -n "$label" ]] || continue
        mole_is_reverse_dns_bundle_id "$label" || continue
        if launchctl print "gui/$uid/$label" > /dev/null 2>&1; then
            return 0
        fi
    done <<< "$(printf '%s\n%s\n' "$bundle_id" "$helper_ids")"

    return 1
}

# Emit the names of successfully-uninstalled apps that still have a background
# job loaded in launchd, meaning the bootout was missed or failed and the user
# must toggle it off manually. Deliberately does NOT consult sfltool dumpbtm:
# unprivileged dumpbtm pops the macOS "sfltool wants to make changes"
# admin-password dialog on every uninstall batch, and registered-but-unloaded
# BTM records are by-design residue macOS clears at next login.
# Args: <app_detail>... -- <success_path>...
# app_detail follows the pipe-encoded shape used inside batch_uninstall_applications.
_uninstall_match_loaded_background_items() {
    local -a details=()
    local -a success_paths=()
    local sep_seen=false
    local arg
    for arg in "$@"; do
        if [[ "$sep_seen" == false ]]; then
            if [[ "$arg" == "--" ]]; then
                sep_seen=true
            else
                details+=("$arg")
            fi
        else
            success_paths+=("$arg")
        fi
    done

    [[ ${#details[@]} -eq 0 || ${#success_paths[@]} -eq 0 ]] && return 0

    local detail app_name app_path bundle_id enc_helpers sp matched
    local _total_kb _encoded_files _encoded_system_files _has_sensitive_data
    local _needs_sudo _is_brew_cask _cask_name _encoded_diag_system
    local _encoded_review_system _sibling_guard _expected_app_identity
    local _original_bundle_id _encoded_live_sibling_fingerprint _expected_info_identity
    for detail in "${details[@]}"; do
        IFS='|' read -r app_name app_path bundle_id _total_kb _encoded_files _encoded_system_files \
            _has_sensitive_data _needs_sudo _is_brew_cask _cask_name _encoded_diag_system \
            _encoded_review_system enc_helpers _sibling_guard _expected_app_identity \
            _original_bundle_id _encoded_live_sibling_fingerprint \
            _expected_info_identity <<< "$detail"
        matched=false
        for sp in "${success_paths[@]}"; do
            [[ "$sp" == "$app_path" ]] && matched=true && break
        done
        [[ "$matched" != true ]] && continue

        # The sibling guard can demote bundle_id to "unknown" while helper ids
        # stay valid; _uninstall_background_job_loaded validates each label,
        # so no explicit unknown-skip is needed here.
        local helper_ids
        helper_ids=$(decode_bundle_id_list "${enc_helpers:-}" "$app_name")
        if _uninstall_background_job_loaded "$bundle_id" "$helper_ids"; then
            printf '%s\n' "$app_name"
        fi
    done
}

append_line() {
    local current="$1"
    local addition="$2"
    [[ -z "$addition" ]] && {
        printf '%s' "$current"
        return 0
    }
    if [[ -n "$current" ]]; then
        printf '%s\n%s' "$current" "$addition"
    else
        printf '%s' "$addition"
    fi
}

format_uninstall_preview_path() {
    local path="$1"
    # Replacement must come from a variable: bash 5.3+ tilde-expands a literal
    # unquoted ~ in the patsub replacement, turning this into a no-op.
    local tilde='~'
    local display_path="${path/#$HOME/$tilde}"
    local size_kb="0"
    local size_rc=0
    if [[ $# -gt 1 ]]; then
        size_kb="$2"
    else
        size_kb=$(get_path_size_kb "$path" 2> /dev/null) || size_rc=$?
        mole_rc_timeout_or_signal "$size_rc" && return "$size_rc"
        [[ $size_rc -eq 0 ]] || size_kb="0"
    fi

    if [[ "$size_kb" =~ ^[0-9]+$ && "$size_kb" -gt 0 ]]; then
        printf '%s %s, %s%s' "$display_path" "$GRAY" "$(bytes_to_human "$((size_kb * 1024))")" "$NC"
    else
        printf '%s' "$display_path"
    fi
}

# Each invocation measures fresh paths and publishes rows in the reviewed order.
# Workers only prepare display text; deletion authority is never shared here.
_uninstall_print_preview_paths() {
    local files="$1" prefix="$2" path text rc=0 finished="" pid index=0
    local -a paths=() pids=()
    while IFS= read -r path; do
        [[ -z "$path" || ! -e "$path" ]] || paths+=("$path")
    done <<< "$files"
    [[ ${#paths[@]} -gt 0 ]] || return 0
    if [[ ${#paths[@]} -le 3 ]]; then
        for path in "${paths[@]}"; do
            text=$(format_uninstall_preview_path "$path") || return $?
            printf '%b%s\n' "$prefix" "$text"
        done
        return 0
    fi
    local result_dir="" old_int old_term worker_rc=0
    result_dir=$(create_temp_dir) || return 1
    old_int=$(trap -p INT)
    old_term=$(trap -p TERM)
    trap 'rc=130' INT
    trap 'rc=143' TERM
    for path in "${paths[@]}"; do
        [[ $rc -eq 0 ]] || break
        (format_uninstall_preview_path "$path" > "$result_dir/$index") < /dev/null &
        pids+=("$!")
        index=$((index + 1))
        if [[ ${#pids[@]} -ge 4 ]]; then
            worker_rc=0
            finished=""
            mole_wait_for_any_worker finished "${pids[@]}" || worker_rc=$?
            [[ $rc -ne 0 || $worker_rc -eq 0 ]] || rc=$worker_rc
            for pid in "${!pids[@]}"; do
                [[ "${pids[$pid]}" != "$finished" ]] || unset 'pids[pid]'
            done
        fi
    done
    # Drain read-only, timeout-bounded measurements before removing their private
    # output directory, including on interruption. No producer outlives its files.
    for pid in "${pids[@]+"${pids[@]}"}"; do
        while true; do
            worker_rc=0
            wait "$pid" 2> /dev/null || worker_rc=$?
            [[ $rc -ne 0 || $worker_rc -eq 0 ]] || rc=$worker_rc
            if [[ $worker_rc -lt 128 ]] || ! kill -0 "$pid" 2> /dev/null; then
                break
            fi
        done
    done
    if [[ $rc -eq 0 ]]; then
        for ((index = 0; index < ${#paths[@]}; index++)); do
            if [[ ! -f "$result_dir/$index" ]]; then
                rc=1
                break
            fi
            text=$(< "$result_dir/$index")
            printf '%b%s\n' "$prefix" "$text"
        done
    fi
    rm -rf -- "$result_dir" # SAFE: private temporary worker-output directory created in this invocation
    trap - INT TERM
    # eval: restore the caller's signal traps captured above.
    [[ -z "$old_int" ]] || eval "$old_int"
    [[ -z "$old_term" ]] || eval "$old_term"
    return "$rc"
}

discover_login_item_helper_bundle_ids() {
    local app_path="$1"
    local login_items_root="$app_path/Contents/Library/LoginItems"
    local _MOLE_UNINSTALL_DISCOVERY_DEADLINE="${_MOLE_UNINSTALL_DISCOVERY_DEADLINE:-$((SECONDS + MOLE_TIMEOUT_DISK_VERIFY_SEC))}"
    [[ -d "$login_items_root" ]] || return 0

    local scan_file=""
    scan_file=$(create_temp_file) || return 1
    local scan_rc=0
    _mole_uninstall_materialize_find0 "$scan_file" \
        "$login_items_root" -maxdepth 1 -iname "*.app" \
        -print0 || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$scan_rc"
    fi

    local helper info bundle_id
    local result_rc=0
    while IFS= read -r -d '' helper; do
        info="$helper/Contents/Info.plist"
        [[ -f "$info" ]] || continue
        local plist_rc=0
        local plist_timeout=""
        plist_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            "$_MOLE_UNINSTALL_DISCOVERY_DEADLINE") || plist_rc=$?
        if [[ $plist_rc -eq 0 ]]; then
            bundle_id=$(run_with_timeout "$plist_timeout" plutil \
                -extract CFBundleIdentifier raw "$info" \
                2> /dev/null) || plist_rc=$?
        fi
        if mole_rc_timeout_or_signal "$plist_rc"; then
            result_rc=$plist_rc
            break
        fi
        if mole_is_reverse_dns_bundle_id "$bundle_id"; then
            printf '%s\n' "$bundle_id"
        fi
    done < "$scan_file"
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    if [[ $result_rc -ne 0 ]]; then
        return "$result_rc"
    fi
    return 0
}

bootout_login_item_helpers() {
    local helper_ids="$1"
    [[ -n "$helper_ids" ]] || return 0
    if is_uninstall_dry_run || [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        debug_log "[DRY RUN] Would bootout login item helpers"
        return 0
    fi

    local uid helper_id
    uid=$(id -u)
    while IFS= read -r helper_id; do
        [[ -n "$helper_id" ]] || continue
        mole_is_reverse_dns_bundle_id "$helper_id" || continue
        # A third-party helper's Info.plist could claim an Apple label; never
        # boot out the protected namespace regardless of what the bundle says.
        case "$helper_id" in
            com.apple.*) continue ;;
        esac
        local bootout_rc=0
        run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" launchctl \
            bootout "gui/$uid/$helper_id" > /dev/null 2>&1 || bootout_rc=$?
        mole_rc_timeout_or_signal "$bootout_rc" && return "$bootout_rc"
        if [[ $bootout_rc -eq 0 ]]; then
            log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "REMOVED" \
                "gui/$uid/$helper_id" "launchctl bootout"
        fi
    done <<< "$helper_ids"
    return 0
}

can_unload_launch_plist() {
    local plist="$1"
    [[ "$plist" == *.plist ]] || return 1
    case "$plist" in
        "$HOME"/Library/LaunchAgents/*.plist | /Library/LaunchAgents/*.plist | /Library/LaunchDaemons/*.plist) ;;
        *) return 1 ;;
    esac
    validate_path_for_deletion "$plist" > /dev/null 2>&1
}

unload_launch_plist() {
    local plist="$1"
    local needs_sudo="${2:-false}"
    local deadline="${3:-}"
    local bundle_id="${4:-}"
    local app_path="${5:-}"
    local _MOLE_UNINSTALL_DISCOVERY_DEADLINE="${deadline:-${_MOLE_UNINSTALL_DISCOVERY_DEADLINE:-}}"
    can_unload_launch_plist "$plist" || return 0
    [[ -f "$plist" && ! -L "$plist" ]] || return 0
    _mole_snapshot_path_identity "$plist" || return 0
    local expected_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local expected_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local expected_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
    local expected_sha256="" hash_rc=0
    expected_sha256=$(mole_file_sha256 "$plist" "$deadline") || hash_rc=$?
    mole_rc_timeout_or_signal "$hash_rc" && return "$hash_rc"
    [[ $hash_rc -eq 0 ]] || return 0
    local owner_rc=0
    mole_uninstall_launch_agent_owned_by_app "$plist" \
        "$bundle_id" "$app_path" || owner_rc=$?
    mole_rc_timeout_or_signal "$owner_rc" && return "$owner_rc"
    [[ $owner_rc -eq 0 ]] || return 0

    local unload_timeout="$MOLE_TIMEOUT_MEDIUM_PROBE_SEC"
    if [[ -n "$deadline" ]]; then
        unload_timeout=$(_mole_timeout_with_deadline "$unload_timeout" \
            "$deadline") || return $?
    fi

    # plutil reads a file descriptor, while launchctl later opens this path.
    # Rebind both content and identity after the owner probe.
    local bound_rc=0
    _mole_owned_path_still_valid "$plist" "$expected_sha256" "" \
        "$expected_parent" "$expected_parent_id" "$expected_target_id" \
        "$deadline" || bound_rc=$?
    mole_rc_timeout_or_signal "$bound_rc" && return "$bound_rc"
    [[ $bound_rc -eq 0 ]] || return 0
    if [[ "$needs_sudo" == "true" ]]; then
        local unload_rc=0
        run_with_timeout "$unload_timeout" sudo launchctl \
            unload "$plist" > /dev/null 2>&1 || unload_rc=$?
    else
        local unload_rc=0
        run_with_timeout "$unload_timeout" launchctl \
            unload "$plist" > /dev/null 2>&1 || unload_rc=$?
    fi
    mole_rc_timeout_or_signal "$unload_rc" && return "$unload_rc"
    if [[ $unload_rc -eq 0 ]]; then
        log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "REMOVED" "$plist" "launchctl unload"
    fi
    return 0
}

_uninstall_unload_launch_plists() {
    local root="$1"
    local needs_sudo="$2"
    local bundle_id="${3:-}"
    local app_path="${4:-}"
    local _MOLE_UNINSTALL_DISCOVERY_DEADLINE="${_MOLE_UNINSTALL_DISCOVERY_DEADLINE:-$((SECONDS + MOLE_TIMEOUT_DISK_VERIFY_SEC))}"
    [[ -d "$root" ]] || return 0

    local scan_file=""
    scan_file=$(create_temp_file) || return 1
    local scan_rc=0
    if [[ -n "$app_path" ]]; then
        _mole_uninstall_materialize_find0 "$scan_file" "$root" \
            -maxdepth 1 -name '*.plist' -print0 || scan_rc=$?
    elif [[ -n "$bundle_id" ]]; then
        _mole_uninstall_materialize_find0 "$scan_file" "$root" \
            -maxdepth 1 \( -name "${bundle_id}.plist" -o \
            -name "${bundle_id}.*.plist" \) -print0 || scan_rc=$?
    else
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return 0
    fi
    if [[ $scan_rc -ne 0 ]]; then
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$scan_rc"
    fi

    # Give bundle-ID candidates the first share of the common deadline. The
    # path-owned pass then visits all other labels without unloading twice.
    local -a phases=(path)
    [[ -n "$bundle_id" ]] && phases=(bundle path)
    [[ -z "$app_path" ]] && phases=(bundle)
    local phase plist plist_name bundle_candidate
    local result_rc=0
    for phase in "${phases[@]}"; do
        while IFS= read -r -d '' plist; do
            plist_name="${plist##*/}"
            bundle_candidate=false
            if [[ -n "$bundle_id" &&
                ("$plist_name" == "$bundle_id.plist" ||
                "$plist_name" == "$bundle_id."*.plist) ]]; then
                bundle_candidate=true
            fi
            [[ "$phase" == bundle && "$bundle_candidate" != true ]] && continue
            [[ "$phase" == path && "$bundle_candidate" == true ]] && continue
            local unload_rc=0
            unload_launch_plist "$plist" "$needs_sudo" \
                "$_MOLE_UNINSTALL_DISCOVERY_DEADLINE" \
                "$bundle_id" "$app_path" || unload_rc=$?
            if [[ $unload_rc -ge 128 ]]; then
                result_rc=$unload_rc
                break
            fi
            mole_rc_timeout "$unload_rc" && result_rc=$unload_rc
        done < "$scan_file"
        [[ $result_rc -ge 128 ]] && break
    done
    rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    if [[ $result_rc -ne 0 ]]; then
        return "$result_rc"
    fi
    return 0
}

# One stop_launch_services root. A signal stops the caller; a timeout is
# recorded in the caller's unload_timeout_rc so the remaining roots still run.
_stop_launch_services_root() {
    local root_rc=0
    _uninstall_unload_launch_plists "$@" || root_rc=$?
    [[ $root_rc -ge 128 ]] && return "$root_rc"
    # shellcheck disable=SC2034 # unload_timeout_rc belongs to stop_launch_services via dynamic scope.
    mole_rc_timeout "$root_rc" && unload_timeout_rc=$root_rc
    return 0
}

# Unload Launch Agents/Daemons for an app.
# Plist deletion is owned by remove_file_list so every removal goes through the
# same validated path list and Trash/permanent deletion mode.
# Security: bundle_id is validated to be reverse-DNS format before use in find patterns
stop_launch_services() {
    local bundle_id="$1"
    local has_system_files="${2:-false}"
    local app_path="${3:-}"

    if is_uninstall_dry_run; then
        debug_log "[DRY RUN] Would unload launch services for bundle: $bundle_id"
        return 0
    fi

    # An exact bundle-ID label or a program inside the selected bundle can
    # authorize teardown. A demoted ID still permits the app-path check.
    local bundle_id_usable=true
    if [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]]; then
        bundle_id_usable=false
    elif ! mole_is_reverse_dns_bundle_id "$bundle_id"; then
        # Validate bundle_id format: must be reverse-DNS style (e.g.,
        # com.example.app). This prevents glob injection attacks if bundle_id
        # contains special characters.
        debug_log "Invalid bundle_id format for LaunchAgent search: $bundle_id"
        bundle_id_usable=false
    fi

    # A timed-out root is remembered and the remaining roots still run, so
    # one slow plist cannot leave another root's jobs loaded. Signals stop.
    local unload_timeout_rc=0

    local launch_bundle_id=""
    [[ "$bundle_id_usable" == "true" ]] && launch_bundle_id="$bundle_id"
    if [[ -z "$launch_bundle_id" && -z "$app_path" ]]; then
        return 0
    fi

    if [[ -d ~/Library/LaunchAgents ]]; then
        _stop_launch_services_root \
            "$HOME/Library/LaunchAgents" false "$launch_bundle_id" "$app_path" || return $?
    fi

    if [[ "$has_system_files" == "true" && "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]]; then
        if [[ -d /Library/LaunchAgents ]]; then
            _stop_launch_services_root \
                /Library/LaunchAgents true "$launch_bundle_id" "$app_path" || return $?
        fi
        if [[ -d /Library/LaunchDaemons ]]; then
            _stop_launch_services_root \
                /Library/LaunchDaemons true "$launch_bundle_id" "$app_path" || return $?
        fi
    fi
    return "$unload_timeout_rc"
}

# Unregister app bundle from LaunchServices before deleting files.
# This helps remove stale app entries from Spotlight's app results list.
unregister_app_bundle() {
    local app_path="$1"

    [[ -n "$app_path" && -e "$app_path" ]] || return 0
    [[ "$app_path" == *.[aA][pP][pP] ]] || return 0

    local lsregister
    lsregister=$(get_lsregister_path)
    [[ -x "$lsregister" ]] || return 0

    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && return 0

    local unregister_rc=0
    run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$lsregister" \
        -u "$app_path" > /dev/null 2>&1 || unregister_rc=$?
    mole_rc_timeout_or_signal "$unregister_rc" && return "$unregister_rc"
    return 0
}

# Compact LaunchServices after uninstall without forcing every app and extension
# to re-register. A domain-wide rebuild can terminate active app extensions,
# including Network Extension packet tunnels such as Shadowrocket's.
refresh_launch_services_after_uninstall() {
    local lsregister
    lsregister=$(get_lsregister_path)
    [[ -x "$lsregister" ]] || return 0

    [[ "${MOLE_DRY_RUN:-0}" == "1" ]] && return 0

    # Best-effort and bounded: stale records are collected, while the targeted
    # -u call above handles the app bundle that was actually removed.
    run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" "$lsregister" -gc > /dev/null 2>&1 || true
    return 0
}

# Remove macOS Login Items for an app
remove_login_item() {
    local app_name="$1"
    local bundle_id="$2"

    if is_uninstall_dry_run; then
        debug_log "[DRY RUN] Would remove login item: ${app_name:-$bundle_id}"
        return 0
    fi

    # Skip if no identifiers provided
    [[ -z "$app_name" && -z "$bundle_id" ]] && return 0

    # Strip .app suffix if present (login items don't include it)
    local clean_name="${app_name%.[aA][pP][pP]}"

    # Remove from Login Items using index-based deletion (handles broken items)
    if [[ -n "$clean_name" ]]; then
        # Skip AppleScript during tests to avoid permission dialogs
        if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]]; then
            # Escape double quotes and backslashes for AppleScript
            local escaped_name="${clean_name//\\/\\\\}"
            escaped_name="${escaped_name//\"/\\\"}"

            local login_item_rc=0 deleted_count=""
            deleted_count=$(
                run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" osascript 2> /dev/null <<- EOF
				set deletedCount to 0
				tell application "System Events"
				    try
				        set itemCount to count of login items
				        -- Delete in reverse order to avoid index shifting
				        repeat with i from itemCount to 1 by -1
				            try
				                set itemName to name of login item i
				                if itemName is "$escaped_name" then
				                    delete login item i
				                    set deletedCount to deletedCount + 1
				                end if
				            end try
				        end repeat
				    end try
				end tell
				return deletedCount
			EOF
            ) || login_item_rc=$?
            mole_rc_timeout_or_signal "$login_item_rc" && return "$login_item_rc"
            if [[ $login_item_rc -eq 0 && "$deleted_count" =~ ^[1-9][0-9]*$ ]]; then
                log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "REMOVED" "$clean_name" "login item"
            fi
        fi
    fi
}

# A container survives a removal in two shapes: an emptied root that
# containermanagerd keeps (only its metadata plist left), or the whole
# container because macOS denied the move. Only the first is a stub. An
# unlistable or slow root is not proof of emptiness. Returns 0 for a stub,
# 1 otherwise, and a signal status unchanged.
_uninstall_container_is_stub() {
    local container="$1"
    [[ -f "$container/.com.apple.containermanagerd.metadata.plist" ]] || return 1
    local entry="" scan_rc=0
    entry=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" find "$container" \
        -mindepth 1 -maxdepth 1 ! -name ".com.apple.containermanagerd.metadata.plist" \
        -print -quit 2> /dev/null) || scan_rc=$?
    mole_rc_signal "$scan_rc" && return "$scan_rc"
    [[ $scan_rc -eq 0 && -z "$entry" ]]
}

# Remove files (handles symlinks, optional sudo).
# Security: All paths pass validate_path_for_deletion() before any deletion.
# Performance: when MOLE_DELETE_MODE=trash and the batch is sudo-free and
# symlink-free, eligible paths share one guarded helper invocation. The helper
# binds physical parent/target identities and uses direct Trash renames, avoiding
# Finder/AppleScript startup per item without trusting a stale lexical batch.
remove_file_list() {
    local file_list="$1"
    local use_sudo="${2:-false}"
    local bundle_id="${3:-}"
    local app_path="${4:-}"
    local count=0
    local mode="${MOLE_DELETE_MODE:-permanent}"

    # The app move can take long enough for another installation to appear.
    # Recheck at the leftover boundary, not only at preview or before moving
    # the app. A conflicting owner or incomplete inventory keeps the whole
    # data family; no name-derived row is strong enough to override it.
    # A replacement at the selected path is a new owner too. That test needs
    # no inventory, so it also covers plans narrowed to a bundle id that is
    # unknown or not reverse-DNS; only the sibling scan needs the id.
    # The cause is recorded per retained path so the summary can name it:
    # app-reappeared, shared-owner (a live sibling), or owner-unknown (the
    # inventory could not prove absence).
    if [[ -n "$app_path" ]]; then
        local owner_rc=1
        local owner_reason=""
        if ! is_uninstall_dry_run && [[ -e "$app_path" || -L "$app_path" ]]; then
            owner_rc=0
            owner_reason="app-reappeared"
        elif mole_is_reverse_dns_bundle_id "$bundle_id"; then
            owner_rc=0
            uninstall_live_bundle_has_other_install "$bundle_id" "$app_path" || owner_rc=$?
            [[ $owner_rc -ge 128 ]] && return "$owner_rc"
            if [[ $owner_rc -eq 0 ]]; then
                owner_reason="shared-owner"
            elif [[ $owner_rc -ne 1 ]]; then
                owner_reason="owner-unknown"
            fi
        fi
        if [[ -n "$owner_reason" ]]; then
            debug_log "Keeping uninstall leftovers: $owner_reason"
            local retained_path
            while IFS= read -r retained_path; do
                [[ -n "$retained_path" ]] || continue
                if [[ "$owner_reason" == "app-reappeared" ]]; then
                    _mole_report_unverified_delete "$retained_path" "$mode" unknown "$MOLE_ERR_APP_REAPPEARED"
                else
                    _mole_record_uninstall_refusal "$retained_path" "$owner_reason"
                fi
            done <<< "$file_list"
            printf '0\n'
            return "$MOLE_ERR_OWNER_UNVERIFIED"
        fi
    fi

    local -a trash_batch=()
    local -a fallback_paths=()
    _MOLE_TRASH_BATCH_SNAPSHOT_PATHS=()
    _MOLE_TRASH_BATCH_SNAPSHOT_PARENTS=()
    _MOLE_TRASH_BATCH_SNAPSHOT_PARENT_IDS=()
    _MOLE_TRASH_BATCH_SNAPSHOT_TARGET_IDS=()

    while IFS= read -r file; do
        [[ -n "$file" && -e "$file" ]] || continue

        local validation_rc=0
        validate_path_for_deletion "$file" || validation_rc=$?
        mole_rc_timeout_or_signal "$validation_rc" && return "$validation_rc"
        if [[ $validation_rc -ne 0 ]]; then
            log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$file" "${_MOLE_VALIDATION_REASON:-protected}"
            continue
        fi

        local launch_agent=false
        local launch_agent_identity=""
        local launch_agent_sha256=""
        local launch_absent_path=""
        case "${file%/*}" in
            "$HOME"/Library/LaunchAgents | /Library/LaunchAgents | /Library/LaunchDaemons)
                launch_agent=true
                # A replacement app at the selected path is a new owner. The
                # original bundle has already moved before leftover removal.
                if [[ -n "$app_path" && (-e "$app_path" || -L "$app_path") ]] &&
                    ! is_uninstall_dry_run; then
                    _mole_report_unverified_delete "$file" "$mode" "unknown" \
                        "$MOLE_ERR_APP_REAPPEARED"
                    continue
                fi
                if ! is_uninstall_dry_run; then
                    launch_absent_path="$app_path"
                fi
                local identity_rc=0
                launch_agent_identity=$(mole_deletion_identity "$file") || identity_rc=$?
                mole_rc_timeout_or_signal "$identity_rc" && return "$identity_rc"
                if [[ $identity_rc -ne 0 ]]; then
                    _mole_report_unverified_delete "$file" "$mode" "unknown"
                    continue
                fi
                local hash_rc=0
                launch_agent_sha256=$(mole_file_sha256 "$file") || hash_rc=$?
                mole_rc_timeout_or_signal "$hash_rc" && return "$hash_rc"
                if [[ $hash_rc -ne 0 ]]; then
                    _mole_report_unverified_delete "$file" "$mode" "unknown"
                    continue
                fi
                local owner_rc=0
                mole_uninstall_launch_agent_owned_by_app "$file" \
                    "$bundle_id" "$app_path" || owner_rc=$?
                mole_rc_timeout_or_signal "$owner_rc" && return "$owner_rc"
                if [[ $owner_rc -ne 0 ]]; then
                    _mole_report_unverified_delete "$file" "$mode" "unknown"
                    continue
                fi
                ;;
        esac

        if [[ "$use_sudo" == "true" ]] && is_uninstall_dry_run; then
            debug_log "[DRY RUN] Would sudo remove: $file"
            ((++count))
            continue
        fi

        # Agent ownership is checked immediately before its own sink. Do not
        # queue it behind unrelated Trash batch work after that check.
        if [[ "$launch_agent" == true ]]; then
            local delete_rc=0
            mole_delete "$file" "$use_sudo" "$launch_agent_identity" \
                "$launch_agent_sha256" "$launch_absent_path" || delete_rc=$?
            mole_rc_timeout_or_signal "$delete_rc" && return "$delete_rc"
            [[ $delete_rc -eq 0 ]] && count=$((count + 1))
            continue
        fi

        # Symlinks, sudo-required paths, app bundles, and TCC-managed app data
        # stay on the per-file mole_delete path. The latter targets bypass
        # third-party Trash tools and Finder inside _mole_move_to_trash.
        if [[ "$mode" == "trash" && "$use_sudo" != "true" && ! -L "$file" ]] &&
            ! _mole_path_requires_direct_trash "$file" &&
            ! is_uninstall_dry_run; then
            if _mole_snapshot_path_identity "$file"; then
                trash_batch+=("$file")
                _MOLE_TRASH_BATCH_SNAPSHOT_PATHS+=("$file")
                _MOLE_TRASH_BATCH_SNAPSHOT_PARENTS+=("$_MOLE_PATH_SNAPSHOT_PARENT")
                _MOLE_TRASH_BATCH_SNAPSHOT_PARENT_IDS+=("$_MOLE_PATH_SNAPSHOT_PARENT_ID")
                _MOLE_TRASH_BATCH_SNAPSHOT_TARGET_IDS+=("$_MOLE_PATH_SNAPSHOT_TARGET_ID")
            else
                debug_log "Skipped Trash batch path with unstable identity: $file"
                log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "SKIPPED" "$file" "path identity unavailable"
            fi
        else
            fallback_paths+=("$file")
        fi
    done <<< "$file_list"

    if [[ ${#trash_batch[@]} -gt 0 ]]; then
        local batch_rc=0
        _mole_move_to_trash_batch "${trash_batch[@]}" || batch_rc=$?
        if [[ $batch_rc -eq 0 && ${#_MOLE_TRASH_BATCH_MOVED_PATHS[@]} -eq 0 ]]; then
            # Test doubles and compatible older helpers report all-or-nothing
            # success without populating the optional moved-path ledger.
            _MOLE_TRASH_BATCH_MOVED_PATHS=("${trash_batch[@]}")
        fi
        local _bp _bsize
        if [[ ${#_MOLE_TRASH_BATCH_MOVED_PATHS[@]} -gt 0 ]]; then
            for _bp in "${_MOLE_TRASH_BATCH_MOVED_PATHS[@]}"; do
                _bsize="unknown"
                _mole_delete_log "trash" "$_bsize" "ok" "$_bp"
                log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "TRASHED" "$_bp" "batch"
                count=$((count + 1))
            done
        fi
        if [[ $batch_rc -ne 0 ]]; then
            # Do not hand paths whose identity changed to a second lexical sink.
            # A failed direct move leaves that item in place for manual review.
            debug_log "Trash batch stopped; unmoved paths were preserved"
        fi
        mole_rc_timeout_or_signal "$batch_rc" && return "$batch_rc"
    fi

    if [[ ${#fallback_paths[@]} -gt 0 ]]; then
        local fb
        for fb in "${fallback_paths[@]}"; do
            # mole_delete routes through Trash when MOLE_DELETE_MODE=trash
            # (uninstall default) and only uses safe_* permanent removal when
            # the caller explicitly selected permanent mode. See #723.
            local delete_rc=0
            mole_delete "$fb" "$use_sudo" || delete_rc=$?
            mole_rc_timeout_or_signal "$delete_rc" && return "$delete_rc"
            [[ $delete_rc -eq 0 ]] && count=$((count + 1))
        done
    fi

    echo "$count"
}

# Distinct installs can share one bundle id (Xcode.app and Xcode-beta.app are
# both com.apple.dt.Xcode). When a sibling install with the same bundle id
# stays on disk and is not part of the current selection, bundle-id-derived
# leftovers (caches, preferences, containers, launch services) still belong to
# the surviving install and must not be touched by this uninstall.
#
# Siblings under /Volumes/* count on purpose. Exact mirror clones never reach
# this check (the scan dedupe collapses same-basename rows and keeps the live
# path), so a /Volumes row here means a same-bundle app the scan considers a
# distinct install. Apps genuinely run from an external volume use the same
# $HOME bundle-id data, and skipping that data is the safe failure mode: worst
# case a few leftover files stay behind, versus deleting state a real install
# still uses.
# Reads apps_data and selected_apps from the caller's scope via dynamic
# scoping; both may be unset when batch.sh is exercised standalone in tests.
# Lowercase a bundle id for sibling comparison.
#
# Bundle ids are case-PRESERVING but not case-SENSITIVE for the paths a cask
# zap stanza and the name-derived cleanup actually touch: on a default APFS
# volume `~/Library/Preferences/com.Foo.Bar.plist` and `com.foo.bar.plist` are
# the same file. Comparing the ids literally therefore let a survivor whose id
# differs only in case slip the guard, and the uninstall then wiped the data
# both apps share.
#
# `mole_ascii_lowercase` rather than `${var,,}`: this repo still supports bash
# 3.2. It folds exactly the bytes `LC_ALL=C tr` did, without the fork that cost
# a few milliseconds per candidate in the sibling scans.
uninstall_normalize_bundle_id() {
    local normalized
    mole_ascii_lowercase normalized "$1"
    printf '%s' "$normalized"
}

# The scanner claims dot-continuation IDs and channel-stripped app names.
# Any independent installed bundle matching either form can still own those
# rows. This is a retention predicate, never permission to claim new data.
# Runs once per installed app in every sibling scan, so it stays fork-free and
# takes ids in any case.
uninstall_bundles_share_remnants() {
    local selected_id="$1" other_id="$2" selected_path="$3" other_path="$4"
    local selected_lower other_lower
    mole_ascii_lowercase selected_lower "$selected_id"
    mole_ascii_lowercase other_lower "$other_id"
    if [[ "$selected_lower" == "$other_lower" ||
        "$selected_lower" == "$other_lower."* || "$other_lower" == "$selected_lower."* ]]; then
        return 0
    fi
    local selected_name="${selected_path##*/}" other_name="${other_path##*/}"
    selected_name="${selected_name%.[aA][pP][pP]}"
    other_name="${other_name%.[aA][pP][pP]}"
    _uninstall_strip_version_suffix_into selected_name "$selected_name"
    _uninstall_strip_version_suffix_into other_name "$other_name"
    [[ ${#selected_name} -ge 2 && ${#other_name} -ge 2 ]] || return 1
    mole_ascii_lowercase selected_name "$selected_name"
    mole_ascii_lowercase other_name "$other_name"
    [[ "$selected_name" == "$other_name" ]]
}

# A preview-time inventory cannot authorize bundle-id teardown: an app may be
# mounted, installed, or copied into place while the confirmation screen is
# open. This bounded scan is deliberately stricter than UI discovery. Every
# root must complete, and every candidate bundle id must be readable, before
# absence is trusted.
_MOLE_UNINSTALL_LIVE_APP_ROOTS=(
    "/Applications"
    "$HOME/Applications"
    "/System/Applications"
    "/Library/Input Methods"
    "$HOME/Library/Input Methods"
    "$HOME/Library/Application Support/Setapp/Applications"
    "$HOME/Library/Containers/io.playcover.PlayCover/Applications"
    "/opt/homebrew/Caskroom"
    "/usr/local/Caskroom"
)
_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT="/Volumes"

# A same-bundle scan that ran but could not read every path. Distinct from both
# success and failure on purpose: the listing it produced is real, so it can
# still prove a sibling exists, but it can never prove one does not. Callers
# must treat it as "a sibling may be there" and narrow the plan accordingly.
# 3 is safe to add to the 0/1/124/128+ set these scans already speak.
readonly MOLE_UNINSTALL_SCAN_PARTIAL=3

# The first path a partial same-bundle scan could not read, so the preview can
# name it instead of saying "some paths". One per app; reset by the caller.
_MOLE_UNINSTALL_SCAN_UNREADABLE=""

# Prints the path from the first "find: <path>: Permission denied" (or
# "Operation not permitted") line of a find error file, ignoring the
# timeout-backend preamble. Returns 1 when no such line exists.
_uninstall_first_unreadable_path() {
    local error_file="$1" line="" path=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            'find: '*': Permission denied')
                path="${line#find: }"
                path="${path%: Permission denied}"
                ;;
            'find: '*': Operation not permitted')
                path="${line#find: }"
                path="${path%: Operation not permitted}"
                ;;
            *) continue ;;
        esac
        [[ -n "$path" ]] || continue
        printf '%s\n' "$path"
        return 0
    done < "$error_file"
    return 1
}

_uninstall_materialize_complete_find0() {
    local output_file="$1"
    local deadline_seconds="$2"
    shift 2

    : > "$output_file" || return 1
    local scan_timeout=""
    local scan_rc=0
    scan_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
        "$deadline_seconds") || scan_rc=$?
    if [[ $scan_rc -eq 0 ]]; then
        # Keep find's stderr. It is the only way to tell "could not read one
        # path" apart from "did not run": find exits 1 for an unreadable
        # subdirectory even though it traversed and printed everything else,
        # and macOS 26 hands out that error routinely under TCC. Discarding it
        # made every such run look like a dead scan, which aborted the whole
        # uninstall over a directory that had nothing to do with the app
        # (#1339, #1340).
        local scan_errors=""
        scan_errors=$(create_temp_file) || return 2
        run_with_timeout "$scan_timeout" "$FIND_BSD" "$@" -print0 \
            < /dev/null > "$output_file" 2> "$scan_errors" || scan_rc=$?
        if [[ "${MO_DEBUG:-0}" == "1" && $scan_rc -ne 0 ]]; then
            local scan_error_detail=""
            # Timeout-backend startup messages precede find's actual error.
            # Keep the first cause line instead of reporting that preamble.
            while IFS= read -r scan_error_detail || [[ -n "$scan_error_detail" ]]; do
                case "$scan_error_detail" in
                    '[TIMEOUT] Perl fallback, '* | '[TIMEOUT] Running with '* | '[TIMEOUT] Shell fallback, '*)
                        scan_error_detail=""
                        continue
                        ;;
                esac
                [[ -z "$scan_error_detail" ]] || break
            done < "$scan_errors"
            # A caller that passes several start points names them as one.
            debug_log "Sibling application listing failed (exit $scan_rc): $(mole_terminal_safe_text "${_mole_find0_label:-$1}"): $(mole_terminal_safe_text "${scan_error_detail:0:512}")"
        fi
        if [[ $scan_rc -eq 1 && -s "$scan_errors" ]]; then
            # Partial view: the listing is real but not exhaustive, so it can
            # support "something is there" and never "nothing is there".
            scan_rc="$MOLE_UNINSTALL_SCAN_PARTIAL"
            if [[ -z "$_MOLE_UNINSTALL_SCAN_UNREADABLE" ]]; then
                _MOLE_UNINSTALL_SCAN_UNREADABLE=$(_uninstall_first_unreadable_path "$scan_errors") || true
            fi
        fi
        rm -f -- "$scan_errors" 2> /dev/null || true # SAFE: exact tracked temp file created above
    fi
    if [[ $scan_rc -ne 0 && $scan_rc -ne $MOLE_UNINSTALL_SCAN_PARTIAL ]]; then
        : > "$output_file" || true
        return "$scan_rc"
    fi
    return "$scan_rc"
}

_uninstall_live_candidate_is_selected() {
    local candidate="$1"
    local selected_path="$2"
    [[ "$candidate" == "$selected_path" ]] && return 0
    if [[ (-e "$candidate" || -L "$candidate") &&
        (-e "$selected_path" || -L "$selected_path") &&
        "$candidate" -ef "$selected_path" ]]; then
        return 0
    fi
    return 1
}

_uninstall_live_candidate_is_nested_app() {
    local root="$1"
    local candidate="$2"
    [[ "$candidate" == "$root" ]] && return 1
    local relative="${candidate#"$root"/}"
    [[ "$relative" != "$candidate" ]] || return 0
    local parent="${relative%/*}"
    [[ "$parent" != "$relative" ]] || return 1

    local component
    while [[ -n "$parent" && "$parent" != "." ]]; do
        component="${parent%%/*}"
        [[ "$component" == *.[aA][pP][pP] ]] && return 0
        [[ "$parent" == */* ]] || break
        parent="${parent#*/}"
    done
    return 1
}

# The most recent complete sibling scan. The fingerprint is a newline-separated,
# sorted set of base64(path):app-identity:Info.plist-identity records. Paths stay
# separately available so the preview can prove that every live sibling was
# represented in the inventory used to build its deletion plan.
_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
_MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()

_uninstall_insert_sorted_live_record() {
    local record="$1"
    local -a inserted=()
    local item
    local did_insert=false

    # shellcheck disable=SC2154 # live_records is provided by the caller via dynamic scope.
    for item in "${live_records[@]+"${live_records[@]}"}"; do
        [[ "$item" == "$record" ]] && return 0
        if [[ "$did_insert" == false && "$record" < "$item" ]]; then
            inserted+=("$record")
            did_insert=true
        fi
        inserted+=("$item")
    done
    [[ "$did_insert" == false ]] && inserted+=("$record")
    live_records=("${inserted[@]}")
}

_uninstall_live_sibling_path_is_duplicate() {
    local candidate="$1"
    local existing
    # shellcheck disable=SC2154 # live_paths is provided by the caller via dynamic scope.
    for existing in "${live_paths[@]+"${live_paths[@]}"}"; do
        [[ "$candidate" == "$existing" ]] && return 0
        if [[ (-e "$candidate" || -L "$candidate") &&
            (-e "$existing" || -L "$existing") &&
            "$candidate" -ef "$existing" ]]; then
            return 0
        fi
    done
    return 1
}

_uninstall_live_sibling_record() {
    local app="$1"
    local info="$2"
    local deadline_seconds="$3"
    local identity_timeout=""
    local identity_rc=0
    identity_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || identity_rc=$?

    local app_identity=""
    local info_identity=""
    if [[ $identity_rc -eq 0 ]]; then
        app_identity=$(run_with_timeout "$identity_timeout" "$STAT_BSD" \
            -f%d:%i:%m "$app" 2> /dev/null) || identity_rc=$?
    fi
    if [[ $identity_rc -eq 0 ]]; then
        identity_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || identity_rc=$?
    fi
    if [[ $identity_rc -eq 0 ]]; then
        info_identity=$(run_with_timeout "$identity_timeout" "$STAT_BSD" \
            -f%d:%i:%m "$info" 2> /dev/null) || identity_rc=$?
    fi
    [[ $identity_rc -eq 0 ]] || return "$identity_rc"
    [[ "$app_identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 2
    [[ "$info_identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 2

    local encoded_path=""
    encoded_path=$(printf '%s' "$app" | base64 | tr -d '\n') || return 2
    printf '%s:%s:%s\n' "$encoded_path" "$app_identity" "$info_identity"
}

_uninstall_materialize_complete_pkg_apps() {
    local output_file="$1"
    local deadline_seconds="$2"
    : > "$output_file" || return 2
    declare -f pkg_receipt_nonstandard_app_paths > /dev/null 2>&1 || return 2

    local remaining=""
    local remaining_rc=0
    remaining=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$deadline_seconds") || remaining_rc=$?
    [[ $remaining_rc -eq 0 ]] || return "$remaining_rc"

    # Allow the on-disk receipt cache (#1383). A cold walk of every non-Apple
    # package on an Xcode machine can burn the whole discovery budget. A
    # complete caller only accepts a cache keyed by the receipt list plus each
    # receipt plist's mtime, so an install, upgrade or reinstall invalidates
    # it; only a scan that read every receipt is written, and it keeps every
    # receipt-owned .app path, present or not. A stale miss is still fail-closed:
    # timeout/incomplete paths degrade to MOLE_UNINSTALL_SCAN_PARTIAL and
    # narrow the plan rather than deleting shared leftovers.
    local producer_rc=0
    MOLE_PKG_RECEIPT_LIST_TIMEOUT="$remaining" \
        MOLE_PKG_RECEIPT_SCAN_TIMEOUT="$remaining" \
        pkg_receipt_nonstandard_app_paths \
        --require-complete > "$output_file" || producer_rc=$?
    if [[ $producer_rc -ne 0 ]]; then
        : > "$output_file" || true
        return "$producer_rc"
    fi
    return 0
}

_uninstall_collect_live_sibling_candidate() {
    local app="$1"
    local selected_path="$2"
    local bundle_id_lower="$3"
    local deadline_seconds="$4"
    local missing_info_is_unknown="$5"

    _uninstall_live_candidate_is_selected "$app" "$selected_path" && return 1
    local info="$app/Contents/Info.plist"
    # PlayCover bundles are flat, with the plist at the bundle root (#1715).
    mole_is_playcover_app "$app" && info="$app/Info.plist"
    if [[ ! -f "$info" ]]; then
        # iOS and iPadOS apps installed on Apple Silicon have no Contents/ at
        # all: the real plist sits at Wrapper/<name>.app/Info.plist. Reading
        # only the Contents/ path classified every one of them as unreadable,
        # and a single such app aborted the uninstall of every other app on
        # the machine (#1339). They are ordinary installs, not a mystery.
        local wrapped=""
        for wrapped in "$app"/Wrapper/*.[aA][pP][pP]/Info.plist; do
            if [[ -f "$wrapped" ]]; then
                info="$wrapped"
                break
            fi
        done
        if [[ ! -f "$info" ]]; then
            if [[ "$missing_info_is_unknown" == true ]]; then
                debug_log "Sibling receipt app has no verifiable Info.plist: $(mole_terminal_safe_text "$app")"
                return 2
            fi
            return 1
        fi
    fi

    local plist_timeout=""
    local plist_rc=0
    plist_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || plist_rc=$?
    local app_bundle=""
    if [[ $plist_rc -eq 0 ]]; then
        app_bundle=$(run_with_timeout "$plist_timeout" plutil \
            -extract CFBundleIdentifier raw "$info" \
            2> /dev/null) || plist_rc=$?
    fi
    if [[ $plist_rc -ne 0 || -z "$app_bundle" ]]; then
        if mole_rc_timeout_or_signal "$plist_rc"; then
            debug_log "Sibling bundle ID probe incomplete (exit $plist_rc): $(mole_terminal_safe_text "$info")"
            return "$plist_rc"
        fi
        # A plist that parses and simply carries no CFBundleIdentifier is a
        # complete answer, not a failed probe: vendor uninstallers and Steam
        # launchers ship bundles like that, and one with no id cannot share an
        # id with the target. Ask plutil whether the file parsed rather than
        # reading its exit code, which is 1 for a missing key, a corrupt file,
        # and an unreadable file alike (measured), or its message, which is
        # prose. Only a file that will not parse stays unknown.
        local lint_rc=0
        local lint_timeout=""
        local lint_budget_rc=0
        lint_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || lint_budget_rc=$?
        if [[ $lint_budget_rc -eq 0 ]]; then
            run_with_timeout "$lint_timeout" plutil -lint "$info" \
                > /dev/null 2>&1 || lint_rc=$?
            if mole_rc_timeout_or_signal "$lint_rc"; then
                debug_log "Sibling plist validation incomplete (exit $lint_rc): $(mole_terminal_safe_text "$info")"
                return "$lint_rc"
            fi
            [[ $lint_rc -eq 0 ]] && return 1
            debug_log "Sibling plist cannot be validated (exit $lint_rc): $(mole_terminal_safe_text "$info")"
        else
            debug_log "Sibling plist validation budget exhausted (exit $lint_budget_rc): $(mole_terminal_safe_text "$info")"
        fi
        return 2
    fi
    uninstall_bundles_share_remnants "$bundle_id_lower" "$app_bundle" "$selected_path" "$app" || return 1
    _uninstall_live_sibling_path_is_duplicate "$app" && return 1

    local live_record=""
    local record_rc=0
    live_record=$(_uninstall_live_sibling_record \
        "$app" "$info" "$deadline_seconds") || record_rc=$?
    if [[ $record_rc -ne 0 ]]; then
        debug_log "Sibling identity snapshot failed (exit $record_rc): $(mole_terminal_safe_text "$app")"
        return "$record_rc"
    fi
    # shellcheck disable=SC2154 # live_paths/live_records are caller-owned snapshot arrays.
    live_paths+=("$app")
    _uninstall_insert_sorted_live_record "$live_record"
    return 0
}

# Return 0 only for a network share whose server is gone: the mount table
# lists the entry as smbfs, nfs, afpfs or webdav, and a bounded lstat of its
# mount point fails with ENOENT. A share that is slow, reconnecting, or fails
# with any other error stays in scope, and signals propagate.
_uninstall_volume_is_unreachable_share() {
    local entry="$1"
    local network_mounts="$2"
    local deadline_seconds="$3"
    local fs_type listed=false
    [[ -n "$network_mounts" ]] || return 1
    for fs_type in smbfs nfs afpfs webdav; do
        if [[ "$network_mounts" == *" on $entry ($fs_type,"* || "$network_mounts" == *" on $entry ($fs_type)"* ]]; then
            listed=true
            break
        fi
    done
    [[ "$listed" == true ]] || return 1
    local probe_timeout="" probe_rc=0
    probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || return 1
    # shellcheck disable=SC2016 # Perl expands $ARGV and $! itself.
    run_with_timeout "$probe_timeout" /usr/bin/perl -e \
        'lstat($ARGV[0]) and exit 1; exit($!{ENOENT} ? 0 : 1)' "$entry" \
        < /dev/null > /dev/null 2>&1 || probe_rc=$?
    [[ $probe_rc -ge 128 ]] && return "$probe_rc"
    [[ $probe_rc -eq 0 ]]
}

# A folder under /Volumes that sits on the same device as /Volumes itself is
# not a mount point, so no disk is attached there (Time Machine leaves root
# 0111 "Backups of <Mac>" folders behind after network backups, #1735). When
# it is also unreadable it is left out instead of making the scan incomplete;
# an unreadable mounted volume still does. Unknown metadata keeps the entry.
_uninstall_volume_is_unmounted_unreadable_folder() {
    local entry="$1"
    local deadline_seconds="$2"
    [[ -d "$entry" && ! -L "$entry" ]] || return 1
    [[ ! -r "$entry" || ! -x "$entry" ]] || return 1
    local probe_timeout="" devices="" probe_rc=0
    probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || return 1
    devices=$(run_with_timeout "$probe_timeout" "$STAT_BSD" -f '%d' \
        "$entry" "$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT" < /dev/null 2> /dev/null) || probe_rc=$?
    [[ $probe_rc -ge 128 ]] && return "$probe_rc"
    [[ $probe_rc -eq 0 && "$devices" == *$'\n'* ]] || return 1
    local entry_device="${devices%%$'\n'*}"
    local root_device="${devices#*$'\n'}"
    [[ "$entry_device" =~ ^[0-9]+$ && "$entry_device" == "$root_device" ]]
}

# Return 0 for one or more other live installs, 1 only for a complete
# proof of absence, 2 for incomplete/unknown state, and preserve signals.
# A deadline timeout degrades to MOLE_UNINSTALL_SCAN_PARTIAL: out of budget
# means the scan is incomplete, not that the user cancelled, and machine-wide
# work such as receipt enumeration can outlive the budget on a healthy Mac
# (#1340). A successful scan always refreshes the fingerprint globals.
uninstall_live_bundle_has_other_install() {
    local bundle_id="$1"
    local selected_path="$2"
    _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT=""
    _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=()
    _MOLE_UNINSTALL_SCAN_UNREADABLE=""
    mole_is_reverse_dns_bundle_id "$bundle_id" || return 1

    local deadline_seconds=$((SECONDS + (2 * MOLE_TIMEOUT_DISK_VERIFY_SEC)))
    local bundle_id_lower
    bundle_id_lower=$(uninstall_normalize_bundle_id "$bundle_id")
    local scan_indeterminate=false
    local scan_file=""
    scan_file=$(create_temp_file) || return 2
    local pkg_paths_file=""
    pkg_paths_file=$(create_temp_file) || {
        rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return 2
    }

    local pkg_scan_rc=0
    _uninstall_materialize_complete_pkg_apps "$pkg_paths_file" \
        "$deadline_seconds" || pkg_scan_rc=$?
    if mole_rc_timeout "$pkg_scan_rc"; then
        debug_log "Sibling package receipt scan timed out (exit $pkg_scan_rc)"
        # Receipt enumeration walks every pkgutil receipt on the machine, and
        # a single vendor receipt can hold tens of thousands of paths, so it
        # can outlive the budget on a healthy Mac (#1340). That is the same
        # doubt as an unreadable path: the receipts we did not reach may name
        # a sibling, so carry the doubt forward instead of ending the run.
        scan_indeterminate=true
    elif [[ $pkg_scan_rc -ne 0 ]]; then
        debug_log "Sibling package receipt scan failed (exit $pkg_scan_rc)"
        rm -f -- "$scan_file" "$pkg_paths_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
        [[ $pkg_scan_rc -ge 128 ]] && return "$pkg_scan_rc"
        return 2
    fi

    local -a live_roots=()
    local configured_root
    for configured_root in "${_MOLE_UNINSTALL_LIVE_APP_ROOTS[@]+"${_MOLE_UNINSTALL_LIVE_APP_ROOTS[@]}"}"; do
        live_roots+=("$configured_root")
    done
    if [[ -d "$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT" ]]; then
        local volume_roots_file=""
        volume_roots_file=$(create_temp_file) || {
            rm -f -- "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
            return 2
        }
        local volume_scan_rc=0
        local snapshot_root="$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT/com.apple.TimeMachine.localsnapshots"
        local skip_snapshot_root=false
        if [[ -d "$snapshot_root" && ! -L "$snapshot_root" && ! -L "$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT" ]]; then
            # Only exclude Apple's internal snapshot namespace, not a mounted
            # disk with the same name. Unknown metadata keeps the normal scan.
            local snapshot_metadata="" snapshot_rc=0 metadata_timeout
            metadata_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || snapshot_rc=$?
            if [[ $snapshot_rc -eq 0 ]]; then
                snapshot_metadata=$(run_with_timeout "$metadata_timeout" "$STAT_BSD" -f '%u:%d' \
                    "$snapshot_root" "$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT" < /dev/null 2> /dev/null) || snapshot_rc=$?
            fi
            if [[ $snapshot_rc -ge 128 ]]; then
                rm -f -- "$volume_roots_file" "$scan_file" "$pkg_paths_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
                return "$snapshot_rc"
            fi
            if [[ $snapshot_rc -eq 0 && "$snapshot_metadata" == *$'\n'* ]]; then
                local snapshot_identity="${snapshot_metadata%%$'\n'*}"
                local volume_identity="${snapshot_metadata#*$'\n'}"
                if [[ "$snapshot_identity" == 0:* && "$volume_identity" == "$snapshot_identity" &&
                    "${snapshot_identity#0:}" =~ ^[0-9]+$ ]]; then
                    skip_snapshot_root=true
                fi
            fi
        fi
        # A network share whose server is gone stays in the mount table, but
        # its mount point reports "No such file or directory", and find fails
        # on it before -prune is evaluated. Nothing on an unreachable share can
        # be a live install, so it is left out; any other unreadable volume
        # still makes the scan incomplete. An unknown mount table excludes
        # nothing.
        local network_mounts="" mount_rc=0 mount_timeout
        mount_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || mount_rc=$?
        if [[ $mount_rc -eq 0 ]]; then
            network_mounts=$(run_with_timeout "$mount_timeout" /sbin/mount -t smbfs,nfs,afpfs,webdav \
                < /dev/null 2> /dev/null) || mount_rc=$?
        fi
        if [[ $mount_rc -ge 128 ]]; then
            rm -f -- "$volume_roots_file" "$scan_file" "$pkg_paths_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
            return "$mount_rc"
        fi
        [[ $mount_rc -eq 0 ]] || network_mounts=""
        # Scan each volume one level down: the same depth-two candidates as a
        # single two-level walk of the volumes root, without its excluded
        # entries ever being visited.
        local -a volume_starts=()
        local volume_entry restore_glob_options="" share_rc=0
        if [[ ! -r "$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT" || ! -x "$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT" ]]; then
            # An empty glob here would read as "no volumes" and prove absence.
            debug_log "Sibling volumes root cannot be listed: $(mole_terminal_safe_text "$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT")"
            scan_indeterminate=true
        else
            restore_glob_options=$(shopt -p dotglob nullglob || true)
            shopt -s dotglob nullglob
            for volume_entry in "$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT"/*; do
                if [[ "$skip_snapshot_root" == true && "$volume_entry" == "$snapshot_root" ]]; then
                    continue
                fi
                share_rc=0
                _uninstall_volume_is_unreachable_share "$volume_entry" "$network_mounts" \
                    "$deadline_seconds" || share_rc=$?
                if [[ $share_rc -eq 0 ]]; then
                    debug_log "Skipping unreachable network share: $(mole_terminal_safe_text "$volume_entry")"
                    continue
                elif [[ $share_rc -ge 128 ]]; then
                    eval "$restore_glob_options"
                    rm -f -- "$volume_roots_file" "$scan_file" "$pkg_paths_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
                    return "$share_rc"
                fi
                share_rc=0
                _uninstall_volume_is_unmounted_unreadable_folder "$volume_entry" \
                    "$deadline_seconds" || share_rc=$?
                if [[ $share_rc -eq 0 ]]; then
                    debug_log "Skipping unreadable folder that is not a mounted volume: $(mole_terminal_safe_text "$volume_entry")"
                    continue
                elif [[ $share_rc -ge 128 ]]; then
                    eval "$restore_glob_options"
                    rm -f -- "$volume_roots_file" "$scan_file" "$pkg_paths_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
                    return "$share_rc"
                fi
                volume_starts+=("$volume_entry")
            done
            eval "$restore_glob_options"
        fi
        if [[ ${#volume_starts[@]} -gt 0 ]]; then
            local _mole_find0_label="$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT"
            _uninstall_materialize_complete_find0 "$volume_roots_file" \
                "$deadline_seconds" "${volume_starts[@]}" \
                -mindepth 1 -maxdepth 1 \
                \( \
                \( -type d -name Applications \) -o \
                \( \( -type d -o -type l \) -iname '*.app' \) \
                \) || volume_scan_rc=$?
        fi
        if [[ $volume_scan_rc -eq $MOLE_UNINSTALL_SCAN_PARTIAL ]] || mole_rc_timeout "$volume_scan_rc"; then
            debug_log "Sibling volume discovery incomplete (exit $volume_scan_rc)"
            # Some volume was unreadable, or the budget ran out before every
            # volume was listed. Keep the roots we did see and carry the
            # doubt forward: absence can no longer be proven from here.
            scan_indeterminate=true
        elif [[ $volume_scan_rc -ne 0 ]]; then
            debug_log "Sibling volume discovery failed (exit $volume_scan_rc)"
            rm -f -- "$volume_roots_file" "$scan_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
            [[ $volume_scan_rc -ge 128 ]] && return "$volume_scan_rc"
            return 2
        fi
        local volume_root
        while IFS= read -r -d '' volume_root; do
            local volume_relative="${volume_root#"$_MOLE_UNINSTALL_LIVE_VOLUMES_ROOT"/}"
            [[ "$volume_relative" != "$volume_root" && "$volume_relative" == */* ]] || continue
            live_roots+=("$volume_root")
        done < "$volume_roots_file"
        rm -f -- "$volume_roots_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
    fi

    local root app
    local -a live_records=()
    local -a live_paths=()
    local result=1
    for root in "${live_roots[@]+"${live_roots[@]}"}"; do
        # Default find does not traverse a symlink used as its starting root.
        # An empty listing there cannot prove that no sibling app survives.
        if [[ -L "$root" ]]; then
            debug_log "Sibling application root is a symlink; installation state is unknown: $(mole_terminal_safe_text "$root")"
            result=2
            break
        fi
        [[ -e "$root" ]] || continue
        if [[ ! -d "$root" || ! -r "$root" ]]; then
            debug_log "Sibling application root is not a readable directory: $(mole_terminal_safe_text "$root")"
            result=2
            break
        fi
        # Match the inventory's bounded app-root traversal. Receipt-backed
        # non-standard paths are supplied separately as exact candidates.
        local scan_rc=0
        _uninstall_materialize_complete_find0 "$scan_file" \
            "$deadline_seconds" "$root" -maxdepth 3 \
            \( -type d -name '.*' ! -iname '*.app' ! -path "$root" -prune \) -o \
            \( \( -type d -o -type l \) -iname '*.app' \) || scan_rc=$?
        if [[ $scan_rc -eq $MOLE_UNINSTALL_SCAN_PARTIAL ]]; then
            debug_log "Sibling application root scan incomplete (exit $scan_rc): $(mole_terminal_safe_text "$root")"
            # Unreadable subpaths under an app root. The apps this listing did
            # find are still real, so keep going and let the doubt decide the
            # verdict at the end rather than discarding the whole scan.
            scan_indeterminate=true
        elif [[ $scan_rc -ne 0 ]]; then
            debug_log "Sibling application root scan failed (exit $scan_rc): $(mole_terminal_safe_text "$root")"
            mole_rc_timeout_or_signal "$scan_rc" && result=$scan_rc || result=2
            break
        fi

        while IFS= read -r -d '' app; do
            # Nested helpers belong to their containing app, not a distinct
            # installation root.
            _uninstall_live_candidate_is_nested_app "$root" "$app" && continue
            local candidate_rc=0
            _uninstall_collect_live_sibling_candidate \
                "$app" "$selected_path" "$bundle_id_lower" \
                "$deadline_seconds" false || candidate_rc=$?
            if [[ $candidate_rc -eq 0 ]]; then
                result=0
            elif [[ $candidate_rc -ne 1 ]]; then
                mole_rc_timeout_or_signal "$candidate_rc" && result=$candidate_rc || result=2
                break
            fi
        done < "$scan_file"
        { [[ $result -eq 2 ]] || mole_rc_timeout_or_signal "$result"; } && break
    done

    if [[ $result -ne 2 ]] && ! mole_rc_timeout_or_signal "$result"; then
        local pkg_app
        while IFS= read -r pkg_app; do
            [[ -n "$pkg_app" ]] || continue
            local candidate_rc=0
            _uninstall_collect_live_sibling_candidate \
                "$pkg_app" "$selected_path" "$bundle_id_lower" \
                "$deadline_seconds" true || candidate_rc=$?
            if [[ $candidate_rc -eq 0 ]]; then
                result=0
            elif [[ $candidate_rc -ne 1 ]]; then
                mole_rc_timeout_or_signal "$candidate_rc" && result=$candidate_rc || result=2
                break
            fi
        done < "$pkg_paths_file"
    fi

    rm -f -- "$scan_file" "$pkg_paths_file" 2> /dev/null || true # SAFE: exact tracked temp files created above
    if [[ $result -eq 0 ]]; then
        local IFS=$'\n'
        _MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT="${live_records[*]}"
        _MOLE_UNINSTALL_LIVE_SIBLING_PATHS=("${live_paths[@]}")
    fi
    # Absence is a claim only an exhaustive scan can make. A partial one that
    # found nothing means "not seen", which for a delete decision has to read
    # as "may exist" so the caller keeps the narrow plan.
    if [[ "$scan_indeterminate" == true && "$result" -eq 1 ]]; then
        result="$MOLE_UNINSTALL_SCAN_PARTIAL"
    fi
    # A per-root or per-candidate probe that ran out of budget is the same
    # incomplete scan, not a user cancellation: nothing above maps 124 to a
    # key press. Signals returned earlier stay untouched.
    if mole_rc_timeout "$result"; then
        result="$MOLE_UNINSTALL_SCAN_PARTIAL"
    fi
    return "$result"
}

_uninstall_decode_live_sibling_fingerprint() {
    local encoded="$1"
    [[ -z "$encoded" ]] && return 0
    local decoded=""
    if ! decoded=$(printf '%s' "$encoded" | base64 -D 2> /dev/null); then
        decoded=$(printf '%s' "$encoded" | base64 -d 2> /dev/null) || return 1
    fi
    printf '%s' "$decoded"
}

_uninstall_live_fingerprint_without_successful_paths() {
    local fingerprint="$1"
    local record encoded_path decoded_path success_path
    local keep
    local output=""
    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        encoded_path="${record%%:*}"
        decoded_path=""
        if ! decoded_path=$(printf '%s' "$encoded_path" | base64 -D 2> /dev/null); then
            decoded_path=$(printf '%s' "$encoded_path" | base64 -d 2> /dev/null) || return 1
        fi
        keep=true
        # shellcheck disable=SC2154 # success_items is owned by the batch executor via dynamic scope.
        for success_path in "${success_items[@]+"${success_items[@]}"}"; do
            if [[ "$decoded_path" == "$success_path" &&
                ! -e "$success_path" && ! -L "$success_path" ]]; then
                keep=false
                break
            fi
        done
        if [[ "$keep" == true ]]; then
            [[ -n "$output" ]] && output+=$'\n'
            output+="$record"
        fi
    done <<< "$fingerprint"
    printf '%s' "$output"
}

uninstall_bundle_id_has_surviving_sibling() {
    local bundle_id="$1"
    local app_path="$2"

    [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] && return 1

    local bundle_id_lower
    bundle_id_lower=$(uninstall_normalize_bundle_id "$bundle_id")

    local row other_path other_bundle
    # shellcheck disable=SC2154 # apps_data is provided by bin/uninstall.sh via dynamic scope.
    for row in "${apps_data[@]+"${apps_data[@]}"}"; do
        IFS='|' read -r _ other_path _ other_bundle _ _ _ <<< "$row"
        uninstall_bundles_share_remnants "$bundle_id_lower" "$other_bundle" "$app_path" "$other_path" || continue
        [[ "$other_path" == "$app_path" ]] && continue
        [[ -d "$other_path" ]] || continue

        local sel selected_path is_selected=false
        for sel in "${selected_apps[@]+"${selected_apps[@]}"}"; do
            IFS='|' read -r _ selected_path _ _ _ _ <<< "$sel"
            if [[ "$selected_path" == "$other_path" ]]; then
                is_selected=true
                break
            fi
        done
        [[ "$is_selected" == true ]] && continue

        return 0
    done

    return 1
}

# Print the lowercased display names and .app basenames of every surviving
# same-bundle sibling (same filter as uninstall_bundle_id_has_surviving_sibling),
# one per line. Used to detect when the selected app's own names collide with
# the survivor's, in which case name-derived cleanup must be suppressed too.
uninstall_surviving_sibling_names() {
    local bundle_id="$1"
    local app_path="$2"

    [[ -z "$bundle_id" || "$bundle_id" == "unknown" ]] && return 0

    local bundle_id_lower
    bundle_id_lower=$(uninstall_normalize_bundle_id "$bundle_id")

    local row other_path other_name other_bundle
    for row in "${apps_data[@]+"${apps_data[@]}"}"; do
        IFS='|' read -r _ other_path other_name other_bundle _ _ _ <<< "$row"
        uninstall_bundles_share_remnants "$bundle_id_lower" "$other_bundle" "$app_path" "$other_path" || continue
        [[ "$other_path" == "$app_path" ]] && continue
        [[ -d "$other_path" ]] || continue

        local sel selected_path is_selected=false
        for sel in "${selected_apps[@]+"${selected_apps[@]}"}"; do
            IFS='|' read -r _ selected_path _ _ _ _ <<< "$sel"
            if [[ "$selected_path" == "$other_path" ]]; then
                is_selected=true
                break
            fi
        done
        [[ "$is_selected" == true ]] && continue

        local other_base="${other_path##*/}"
        other_base="${other_base%.[aA][pP][pP]}"

        # Emit each identifier plus its version-suffix-stripped base: a
        # survivor named "Foo Beta.app" also claims "Foo"-keyed dirs via the
        # stripper in find_app_files, so uninstalling "Foo.app" must treat
        # "foo" as taken.
        local candidate
        for candidate in "$other_name" "$other_base"; do
            [[ -z "$candidate" ]] && continue
            printf '%s\n' "$candidate" | LC_ALL=C tr '[:upper:]' '[:lower:]'
            uninstall_strip_version_suffix "$candidate" | LC_ALL=C tr '[:upper:]' '[:lower:]'
        done
    done

    return 0
}

# Mirror of the version-suffix stripping inside find_app_files. Needed here
# because find_app_files derives extra patterns from the stripped base name
# ("Zed Nightly" also matches "Zed" paths), so a collision check against the
# survivor must consider the stripped form as well.
uninstall_strip_version_suffix() {
    local stripped
    _uninstall_strip_version_suffix_into stripped "$1"
    printf '%s\n' "$stripped"
}

# Same strip, written into the variable named by $1 so a per-candidate caller
# pays no command substitution. The match is case-sensitive on purpose, like
# find_app_files; do not call it under nocasematch.
_uninstall_strip_version_suffix_into() {
    local _strip_value="$2"
    local version_suffixes="Nightly|Beta|Alpha|Dev|Canary|Preview|Insider|Edge|Stable|Release|RC|LTS"
    version_suffixes+="|Developer Edition|Technology Preview"
    if [[ "$_strip_value" =~ ^(.+)[[:space:]]+(${version_suffixes})$ ]]; then
        _strip_value="${BASH_REMATCH[1]}"
    fi
    printf -v "$1" '%s' "$_strip_value"
}

# The preview's "is this app running" probe. CFBundleExecutable comes from the
# bundle, and pgrep reads it as an ERE, so escape it to a literal before the
# probe: a crafted ".*" would otherwise report every process as this app. An
# empty or control-byte name cannot be probed safely, so it reports nothing
# here; force_kill_app has its own guard and refuses to signal that name.
_uninstall_app_running_by_executable() {
    local app_name="$1"
    local exec_name="$2"
    local escaped=""

    mole_is_shared_runtime_executable "$exec_name" && return 1
    escaped=$(_mole_process_pattern_literal "${exec_name:-$app_name}") || return 1
    pgrep -qx "$escaped" 2> /dev/null
}

# shellcheck source=lib/uninstall/batch_plan.sh
source "$SCRIPT_DIR/lib/uninstall/batch_plan.sh"
# shellcheck source=lib/uninstall/batch_preview.sh
source "$SCRIPT_DIR/lib/uninstall/batch_preview.sh"
# shellcheck source=lib/uninstall/batch_execute.sh
source "$SCRIPT_DIR/lib/uninstall/batch_execute.sh"
# shellcheck source=lib/uninstall/batch_summary.sh
source "$SCRIPT_DIR/lib/uninstall/batch_summary.sh"

# Batch uninstall with single confirmation. Orchestrates the four phases
# (scan, preview/confirm, execute, summary) and manages the cross-phase
# shared state, the SIGINT/SIGTERM trap, sudo keepalive, and the deferred
# Dock / LaunchServices refresh.
# brew autoremove prints one "Uninstalling <keg>... (<files>, <size>)" line per
# formula it removes. Homebrew does the removal, so record each keg here.
_batch_log_brew_autoremove() {
    local output="$1" line keg
    while IFS= read -r line; do
        line="${line#==> }"
        [[ "$line" == "Uninstalling "*"... ("* ]] || continue
        keg="${line#Uninstalling }"
        keg="${keg%%... (*}"
        [[ "$keg" == /* ]] || continue
        log_operation "${MOLE_CURRENT_COMMAND:-uninstall}" "REMOVED" "$keg" "brew autoremove"
    done <<< "$output"
}

batch_uninstall_applications() {
    local total_size_freed=0

    # shellcheck disable=SC2154
    if [[ ${#selected_apps[@]} -eq 0 ]]; then
        log_warning "No applications selected for uninstallation"
        return 0
    fi

    local old_trap_int old_trap_term
    old_trap_int=$(trap -p INT)
    old_trap_term=$(trap -p TERM)

    _cleanup_sudo_keepalive() {
        if command -v stop_sudo_session > /dev/null 2>&1; then
            stop_sudo_session
        fi
    }

    _restore_uninstall_traps() {
        _cleanup_sudo_keepalive
        if [[ -n "$old_trap_int" ]]; then
            # eval: restore previous trap captured by $(trap -p INT)
            eval "$old_trap_int"
        else
            trap - INT
        fi
        if [[ -n "$old_trap_term" ]]; then
            # eval: restore previous trap captured by $(trap -p TERM)
            eval "$old_trap_term"
        else
            trap - TERM
        fi
    }

    _abort_uninstall_batch() {
        # stop_inline_spinner erases the spinner line on stderr; silencing it
        # left "Uninstalling X..." on screen after an abort.
        stop_inline_spinner || true
        unset MOLE_UNINSTALL_MODE
        _restore_uninstall_traps
    }

    # SIGINT/SIGTERM during a phase helper would normally `return 130` out of
    # the helper only; without an explicit signal flag the orchestrator would
    # cheerfully run the next phase. The trap sets _batch_interrupted so the
    # orchestrator can check after each helper and bail out the way the
    # pre-refactor inline implementation did.
    local _batch_interrupted=0

    # Trap to clean up spinner, sudo keepalive, and uninstall mode on interrupt
    trap 'stop_inline_spinner 2>/dev/null; _cleanup_sudo_keepalive; unset MOLE_UNINSTALL_MODE; echo ""; _restore_uninstall_traps; _batch_interrupted=1; return 130' INT TERM

    # Pre-scan: running apps, sudo needs, size.
    local -a running_apps=()
    local -a sudo_apps=()
    local -a brew_cask_apps=()
    local -a blocked_apps=()
    local -a manual_removal_apps=()
    local -a leftover_notes=()
    local total_estimated_size=0
    local -a app_details=()

    local _batch_scan_stage="application inspection"
    local _batch_scan_app_name=""
    local _scan_rc=0
    _batch_scan_app_details || _scan_rc=$?
    if [[ $_batch_interrupted -eq 1 ]]; then
        _abort_uninstall_batch
        return 130
    fi
    if mole_rc_timeout_or_signal "$_scan_rc"; then
        _abort_uninstall_batch
        # A signal already echoed through the INT/TERM trap; a timeout has
        # said nothing yet, and a silent exit is unreportable (#1340).
        if mole_rc_timeout "$_scan_rc"; then
            log_error "The uninstall scan timed out before finishing; nothing was removed"
        fi
        return "$_scan_rc"
    elif [[ $_scan_rc -ne 0 ]]; then
        _abort_uninstall_batch
        log_error "Could not finish the uninstall scan ($_batch_scan_stage, exit $_scan_rc); nothing was removed"
        local brew_failure=""
        if [[ "$_batch_scan_stage" == "Homebrew ownership check" ]] &&
            brew_failure=$(_mole_brew_failure_line 2> /dev/null); then
            log_info "Homebrew itself failed: $brew_failure; fix Homebrew, then retry mo uninstall"
        elif [[ "$_batch_scan_stage" == "Homebrew ownership check" ]]; then
            log_info "'$_batch_scan_app_name' matches a Homebrew cask brew cannot read; run brew info --cask <cask>, fix or untap it, then retry mo uninstall --debug"
        else
            log_info "Run mo uninstall --debug to see which scan failed"
        fi
        return 1
    fi

    if [[ ${#app_details[@]} -eq 0 ]]; then
        _abort_uninstall_batch
        return 1
    fi

    local _confirm_rc=0
    _batch_preview_and_confirm || _confirm_rc=$?
    if [[ $_batch_interrupted -eq 1 ]]; then
        _abort_uninstall_batch
        return 130
    fi
    if mole_rc_timeout_or_signal "$_confirm_rc"; then
        _abort_uninstall_batch
        return "$_confirm_rc"
    fi
    case $_confirm_rc in
        0) ;;
        2)
            _abort_uninstall_batch
            return 0
            ;;
        3)
            _abort_uninstall_batch
            return 1
            ;;
        4)
            _abort_uninstall_batch
            return 0
            ;;
        *)
            _abort_uninstall_batch
            return 1
            ;;
    esac

    # Perform uninstallations with per-app progress feedback
    local success_count=0 failed_count=0
    local brew_apps_removed=0 # Track successful brew uninstalls for silent autoremove
    local -a failed_items=()
    local -a success_items=()
    local -a success_names=()
    local -a success_dock_targets=()
    local -a system_extension_warning_apps=()
    local -a review_only_system_leftovers=()
    local -a review_only_system_leftover_keys=()
    # Apps whose process was still running after the kill ladder. We do not
    # abort the uninstall for these: macOS allows deleting a running bundle
    # (the process keeps using its mmap'd code), but we warn the user so they
    # know to quit/relaunch the lingering process.
    local -a running_at_uninstall_apps=()

    local _batch_exec_app_name=""
    local _batch_exec_stage=""
    local _execute_rc=0
    _batch_execute_removals || _execute_rc=$?
    if [[ $_batch_interrupted -eq 1 ]]; then
        _abort_uninstall_batch
        return 130
    fi
    # A signal already echoed through the INT/TERM trap. Anything else must
    # name the app and step, or the run ends on a bare spinner line.
    if [[ $_execute_rc -ge 128 ]]; then
        _abort_uninstall_batch
        return "$_execute_rc"
    elif [[ $_execute_rc -ne 0 ]]; then
        _abort_uninstall_batch
        if mole_rc_timeout "$_execute_rc"; then
            log_error "Uninstall stopped at ${_batch_exec_app_name}: ${_batch_exec_stage} timed out; apps after it were not touched"
        else
            log_error "Uninstall stopped at ${_batch_exec_app_name} during ${_batch_exec_stage} (exit ${_execute_rc}); apps after it were not touched"
        fi
        log_info "Run mo uninstall --debug to see which step failed"
        return 1
    fi

    # Detect background jobs that survived the uninstall (System Settings >
    # Login Items & Extensions). Modern SMAppService helpers are not removable
    # via osascript and Apple has no public CLI to delete individual BTM
    # records, so we only detect + warn. Detection is launchctl-only: it needs
    # no privileges, while sfltool dumpbtm pops the macOS "sfltool wants to
    # make changes" admin-password dialog on every batch.
    local -a background_items_warning_apps=()
    if [[ ${#success_items[@]} -gt 0 ]] && ! is_uninstall_dry_run; then
        local _bg_line
        while IFS= read -r _bg_line; do
            [[ -n "$_bg_line" ]] && background_items_warning_apps+=("$_bg_line")
        done < <(_uninstall_match_loaded_background_items "${app_details[@]}" -- "${success_items[@]}")
    fi

    _batch_render_summary
    local references_rc=0
    _batch_report_configuration_references || references_rc=$?
    if [[ $references_rc -ne 0 ]]; then
        _abort_uninstall_batch
        return "$references_rc"
    fi

    # Run brew autoremove silently in background to avoid interrupting UX.
    if [[ $brew_apps_removed -gt 0 && "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        # This background job never needs terminal input. Keeping its stdin
        # attached lets the Perl timeout fallback hand off the controlling tty
        # and suspend the foreground uninstall prompt with SIGTTIN.
        (
            autoremove_output=$(HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTO_UPDATE=1 NONINTERACTIVE=1 \
                run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" brew autoremove 2>&1) || true
            _batch_log_brew_autoremove "$autoremove_output"
        ) > /dev/null 2>&1 < /dev/null &
        disown $! 2> /dev/null || true
    fi

    # Clean up Dock entries for uninstalled apps.
    if [[ $success_count -gt 0 && ${#success_dock_targets[@]} -gt 0 ]]; then
        if is_uninstall_dry_run; then
            log_info "[DRY RUN] Would refresh LaunchServices and update Dock entries"
        else
            # LaunchServices refresh uses run_with_timeout. It is best-effort
            # background work, so it must never own the tty.
            (
                remove_apps_from_dock "${success_dock_targets[@]}" > /dev/null 2>&1 || true
                refresh_launch_services_after_uninstall > /dev/null 2>&1 || true
            ) > /dev/null 2>&1 < /dev/null &
            disown $! 2> /dev/null || true
        fi
    fi

    _cleanup_sudo_keepalive

    # Disable uninstall mode
    unset MOLE_UNINSTALL_MODE

    _restore_uninstall_traps
    unset -f _abort_uninstall_batch
    unset -f _restore_uninstall_traps

    total_size_cleaned=$((total_size_cleaned + total_size_freed))
    unset failed_items
}
