#!/bin/bash
# Internal phase of batch_uninstall_applications; load through batch.sh.
# Reads/writes orchestrator locals via Bash dynamic scope.
# Contracts and phase transitions: docs/QUALITY_CONTRACTS.md.

# Phase 4: iterate app_details and perform the actual removal for each.
# Tracks per-app failures, warnings (system extensions, still-running
# processes, container leftovers), and the total bytes
# actually freed. Per-app failures do not halt the loop; the surrounding
# trap still terminates the whole pass on SIGINT/SIGTERM.
# Reads:  app_details
# Writes: success_count, failed_count, failed_items, success_items,
#         success_dock_targets, system_extension_warning_apps,
#         review_only_system_leftovers,
#         review_only_system_leftover_keys, running_at_uninstall_apps,
#         total_size_freed, brew_apps_removed,
#         files_cleaned, total_items (the latter two via dynamic scope)
# shellcheck disable=SC2154  # Inputs are locals owned by batch_uninstall_applications.
_batch_execute_removals() {
    # See format_uninstall_preview_path: literal ~ in a patsub replacement is
    # tilde-expanded by bash 5.3+, so route it through a variable.
    local tilde_display='~'
    local current_index=0
    for detail in "${app_details[@]}"; do
        current_index=$((current_index + 1))
        IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files has_sensitive_data needs_sudo is_brew_cask cask_name encoded_diag_system encoded_review_system encoded_login_item_helpers sibling_guard expected_app_identity original_bundle_id encoded_live_sibling_fingerprint expected_info_identity <<< "$detail"
        local related_files=$(decode_file_list "$encoded_files" "$app_name")
        local system_files=$(decode_file_list "$encoded_system_files" "$app_name")
        local diag_system=$(decode_file_list "$encoded_diag_system" "$app_name")
        local review_only_system_files=$(decode_file_list "$encoded_review_system" "$app_name")
        local login_item_helpers=$(decode_bundle_id_list "$encoded_login_item_helpers" "$app_name")
        local reason=""
        local suggestion=""
        # Dynamic scope keeps actual refusal evidence inside this app's attempt.
        local _MOLE_UNINSTALL_REFUSALS_ACTIVE=1
        local -a _MOLE_UNINSTALL_REFUSAL_PATHS=() _MOLE_UNINSTALL_REFUSAL_REASONS=()
        _batch_exec_app_name="$app_name"
        _batch_exec_stage="app verification"

        # Show progress before the pre-teardown verification, not after: the
        # same-bundle re-scan below can take tens of seconds on a large
        # receipt set, and silence right after the Enter confirm reads as a
        # dead prompt (#1340 family). Every downstream path already runs with
        # this spinner active and stops it before printing.
        local brew_tag=""
        [[ "$is_brew_cask" == "true" ]] && brew_tag=" ${CYAN}[Brew]${NC}"
        if [[ -t 1 ]]; then
            if [[ ${#app_details[@]} -gt 1 ]]; then
                start_inline_spinner "[$current_index/${#app_details[@]}] Uninstalling $(_uninstall_display_text "$app_name")${brew_tag}..."
            else
                start_inline_spinner "Uninstalling $(_uninstall_display_text "$app_name")${brew_tag}..."
            fi
        fi

        local app_plan_rc=0
        _batch_selected_app_plan_matches "$app_path" \
            "$expected_app_identity" "$expected_info_identity" || app_plan_rc=$?
        if mole_rc_timeout_or_signal "$app_plan_rc"; then
            return "$app_plan_rc"
        elif [[ $app_plan_rc -ne 0 ]]; then
            reason="selected app changed after preview"
            suggestion="Select the app again and review the new removal plan"
        fi

        # Rebuild the exact same-bundle installation snapshot immediately
        # before the first teardown side effect. This uses the original
        # resolved id even when the preview demoted bundle_id to "unknown" to
        # suppress shared leftovers. Any added, removed, replaced, or modified
        # sibling invalidates both the name guard and the reviewed plan.
        original_bundle_id="${original_bundle_id:-$bundle_id}"
        if [[ -z "$reason" ]] && mole_is_reverse_dns_bundle_id "$original_bundle_id"; then
            local preview_live_sibling_fingerprint=""
            if ! preview_live_sibling_fingerprint=$(
                _uninstall_decode_live_sibling_fingerprint \
                    "${encoded_live_sibling_fingerprint:-}"
            ); then
                reason="unable to verify the reviewed app installation set"
                suggestion="Select the app again and review the new removal plan"
            elif ! preview_live_sibling_fingerprint=$(
                _uninstall_live_fingerprint_without_successful_paths \
                    "$preview_live_sibling_fingerprint"
            ); then
                reason="unable to verify the reviewed app installation set"
                suggestion="Select the app again and review the new removal plan"
            fi

            local live_sibling_rc=0
            uninstall_live_bundle_has_other_install \
                "$original_bundle_id" "$app_path" || live_sibling_rc=$?
            if [[ $live_sibling_rc -eq 0 || $live_sibling_rc -eq 1 ]]; then
                if [[ "$preview_live_sibling_fingerprint" != "$_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT" ]]; then
                    reason="the app installation set changed after preview"
                    suggestion="Select the app again and review the new removal plan"
                fi
            elif [[ $live_sibling_rc -lt 128 &&
                "$sibling_guard" == "guard_login" &&
                -z "$encoded_files" ]]; then
                # The preview already narrowed this plan to the selected app
                # bundle alone because the scan could not prove absence, or
                # could not run at all (#1624). The
                # re-check hitting the same doubt confirms that state rather
                # than contradicting it, and a plan with no shared teardown
                # has nothing a live sibling could lose. Refusing here is what
                # made a deterministically slow or unreadable machine unable
                # to uninstall anything at all (#1340). guard_login alone is
                # not that proof: the surviving-sibling name-collision path
                # sets it while keeping name-keyed leftovers, so the empty
                # deletion list is the evidence that authorizes proceeding.
                :
            elif [[ $live_sibling_rc -ge 128 ]]; then
                return "$live_sibling_rc"
            else
                reason="unable to verify other apps with the same bundle id"
                suggestion="Check mounted volumes and application folders, then try again"
            fi
        fi

        # Stop Launch Agents/Daemons before removal.
        local has_system_files="false"
        [[ -n "$system_files" ]] && has_system_files="true"

        if [[ -z "$reason" ]]; then
            app_plan_rc=0
            _batch_selected_app_plan_matches "$app_path" \
                "$expected_app_identity" "$expected_info_identity" || app_plan_rc=$?
            if mole_rc_timeout_or_signal "$app_plan_rc"; then
                return "$app_plan_rc"
            elif [[ $app_plan_rc -ne 0 ]]; then
                reason="selected app changed after preview"
                suggestion="Select the app again and review the new removal plan"
            fi
        fi

        # Launch service unloads, LaunchServices unregistration, login item
        # removal, and helper bootout are best-effort teardown: a timeout
        # skips that step for this app, and only a signal stops the batch.
        # Treating a timeout as fatal aborted every uninstall on Macs where
        # osascript waits on the System Events automation prompt.
        if [[ -z "$reason" ]]; then
            local teardown_rc=0
            stop_launch_services \
                "$bundle_id" "$has_system_files" "$app_path" || teardown_rc=$?
            [[ $teardown_rc -ge 128 ]] && return "$teardown_rc"
            mole_rc_timeout "$teardown_rc" &&
                debug_log "Launch service unload timed out for $app_name; continuing"
            teardown_rc=0
            unregister_app_bundle "$app_path" || teardown_rc=$?
            [[ $teardown_rc -ge 128 ]] && return "$teardown_rc"
            mole_rc_timeout "$teardown_rc" &&
                debug_log "LaunchServices unregister timed out for $app_name; continuing"
        fi

        # Remove from Login Items. Skipped when the sibling guard flagged a
        # name collision: login items are matched by display name only, and
        # deleting "Xcode" by name would take out the surviving install's
        # login item along with the beta's.
        # PlayCover apps never register login items, and their display name
        # may belong to a native app.
        if [[ -z "$reason" && "${sibling_guard:-none}" != "guard_login" ]] &&
            [[ "${app_path%/*}" != "$(mole_playcover_apps_dir)" ]]; then
            local login_remove_rc=0
            remove_login_item "$app_name" "$bundle_id" || login_remove_rc=$?
            [[ $login_remove_rc -ge 128 ]] && return "$login_remove_rc"
            mole_rc_timeout "$login_remove_rc" &&
                debug_log "Login item removal timed out for $app_name; continuing"
        elif [[ -z "$reason" && "${sibling_guard:-none}" == "guard_login" ]]; then
            debug_log "Skipping login item removal for $app_name: name is shared with a surviving install"
        fi

        # Best-effort termination. macOS allows removing a running app bundle
        # (the running process keeps using its mmap'd code), so a stuck app
        # process must NOT block the uninstall. Track it so we can surface a
        # warning at the end without scaring the user with a "failed" status.
        # Skipped under the sibling guard: force_kill_app quits by bundle id
        # and matches processes by CFBundleExecutable, and both identifiers
        # can belong to the surviving install (Xcode-beta.app ships the
        # executable "Xcode"), so the kill ladder could SIGKILL the
        # survivor's running process instead.
        if [[ -z "$reason" && "${sibling_guard:-none}" == "none" ]]; then
            local kill_rc=0
            force_kill_app "$app_name" "$app_path" || kill_rc=$?
            [[ $kill_rc -ge 128 ]] && return "$kill_rc"
            if [[ $kill_rc -ne 0 ]]; then
                running_at_uninstall_apps+=("$app_name")
            fi
        elif [[ -z "$reason" ]]; then
            debug_log "Skipping process termination for $app_name: identifiers are shared with a surviving install"
        fi

        _batch_exec_stage="app removal"
        # Keep the spinner alive through the heavy work. For large apps the
        # main bundle delete alone can take many seconds; for apps with
        # 50-200 leftover files the per-file Trash moves add even more. The
        # message is updated so the user sees which phase is running rather
        # than a single static spinner.
        if [[ -t 1 && -z "$reason" ]]; then
            local _phase_size
            _phase_size=$(bytes_to_human "$((total_kb * 1024))")
            local _phase_prefix=""
            if [[ ${#app_details[@]} -gt 1 ]]; then
                _phase_prefix="[$current_index/${#app_details[@]}] "
            fi
            start_inline_spinner "${_phase_prefix}Removing ${app_name} (${_phase_size})..."
        fi

        local used_brew_successfully=false
        if [[ -z "$reason" ]]; then
            app_plan_rc=0
            _batch_selected_app_plan_matches "$app_path" \
                "$expected_app_identity" "$expected_info_identity" || app_plan_rc=$?
            if mole_rc_timeout_or_signal "$app_plan_rc"; then
                return "$app_plan_rc"
            elif [[ $app_plan_rc -ne 0 ]]; then
                reason="selected app changed after preview"
                suggestion="Select the app again and review the new removal plan"
            fi
        fi
        if [[ -z "$reason" ]]; then
            if [[ "$is_brew_cask" == "true" && -n "$cask_name" ]]; then
                # Mole removes only the reviewed paths below. A cask zap can
                # reach data that was not selected or even discovered.
                # Use brew_uninstall_cask helper (handles env vars, timeout, verification)
                local brew_uninstall_rc=0
                brew_uninstall_cask "$cask_name" "$app_path" \
                    "nozap" || brew_uninstall_rc=$?
                if [[ $brew_uninstall_rc -eq 0 ]]; then
                    used_brew_successfully=true
                elif mole_rc_timeout_or_signal "$brew_uninstall_rc"; then
                    return "$brew_uninstall_rc"
                else
                    # Only fall back to manual app removal when Homebrew no longer
                    # tracks the cask. Otherwise we would recreate the mismatch
                    # where brew still reports the app as installed after Mole
                    # removes the bundle manually.
                    local cask_state=2
                    if command -v is_brew_cask_installed > /dev/null 2>&1; then
                        if is_brew_cask_installed "$cask_name"; then
                            cask_state=0
                        else
                            cask_state=$?
                        fi
                    fi
                    [[ $cask_state -ge 128 ]] && return "$cask_state"

                    if [[ $cask_state -eq 1 ]]; then
                        app_plan_rc=0
                        _batch_selected_app_plan_matches "$app_path" \
                            "$expected_app_identity" "$expected_info_identity" || app_plan_rc=$?
                        if mole_rc_timeout_or_signal "$app_plan_rc"; then
                            return "$app_plan_rc"
                        elif [[ $app_plan_rc -ne 0 ]]; then
                            reason="selected app changed after preview"
                            suggestion="Select the app again and review the new removal plan"
                        else
                            local removal_rc=0
                            mole_delete "$app_path" "$needs_sudo" \
                                "$expected_app_identity" || removal_rc=$?
                            mole_rc_timeout_or_signal "$removal_rc" && return "$removal_rc"
                            if [[ $removal_rc -ne 0 ]]; then
                                if [[ $removal_rc -eq $MOLE_ERR_MUTABLE_PARENT ]]; then
                                    local diagnosis
                                    diagnosis=$(diagnose_removal_failure "$removal_rc" "$app_name")
                                    IFS='|' read -r reason suggestion <<< "$diagnosis"
                                else
                                    reason="brew cleanup incomplete, manual removal failed"
                                fi
                            fi
                        fi
                    elif [[ $cask_state -eq 0 ]]; then
                        reason="brew uninstall failed, package still installed"
                        suggestion="Run brew uninstall --cask $cask_name"
                    else
                        reason="brew uninstall failed, package state unknown"
                        suggestion="Run brew uninstall --cask $cask_name"
                    fi
                fi
            elif [[ "$needs_sudo" == true ]]; then
                if [[ -L "$app_path" ]]; then
                    local link_target
                    link_target=$(readlink "$app_path" 2> /dev/null)
                    if [[ -n "$link_target" ]]; then
                        local resolved_target="$link_target"
                        if [[ "$link_target" != /* ]]; then
                            local link_dir
                            link_dir=$(dirname "$app_path")
                            resolved_target=$(cd "$link_dir" 2> /dev/null && cd "$(dirname "$link_target")" 2> /dev/null && pwd)/$(basename "$link_target") 2> /dev/null || echo ""
                        fi
                        case "$resolved_target" in
                            /System/* | /usr/bin/* | /usr/lib/* | /bin/* | /sbin/* | /private/etc/*)
                                reason="protected system symlink, cannot remove"
                                ;;
                            *)
                                local removal_rc=0
                                mole_delete "$app_path" "true" \
                                    "$expected_app_identity" || removal_rc=$?
                                mole_rc_timeout_or_signal "$removal_rc" && return "$removal_rc"
                                if [[ $removal_rc -ne 0 ]]; then
                                    reason="failed to remove symlink"
                                fi
                                ;;
                        esac
                    else
                        local removal_rc=0
                        mole_delete "$app_path" "true" \
                            "$expected_app_identity" || removal_rc=$?
                        mole_rc_timeout_or_signal "$removal_rc" && return "$removal_rc"
                        if [[ $removal_rc -ne 0 ]]; then
                            reason="failed to remove symlink"
                        fi
                    fi
                else
                    if is_uninstall_dry_run; then
                        local removal_rc=0
                        mole_delete "$app_path" "false" \
                            "$expected_app_identity" || removal_rc=$?
                        mole_rc_timeout_or_signal "$removal_rc" && return "$removal_rc"
                        if [[ $removal_rc -ne 0 ]]; then
                            reason="dry-run path validation failed"
                        fi
                    else
                        local ret=0
                        mole_delete "$app_path" "true" \
                            "$expected_app_identity" || ret=$?
                        mole_rc_timeout_or_signal "$ret" && return "$ret"
                        if [[ $ret -ne 0 ]]; then
                            local diagnosis
                            diagnosis=$(diagnose_removal_failure "$ret" "$app_name")
                            IFS='|' read -r reason suggestion <<< "$diagnosis"
                        fi
                    fi
                fi
            else
                local removal_rc=0
                mole_delete "$app_path" "false" \
                    "$expected_app_identity" || removal_rc=$?
                mole_rc_timeout_or_signal "$removal_rc" && return "$removal_rc"
                if [[ $removal_rc -ne 0 ]]; then
                    if [[ $removal_rc -eq $MOLE_ERR_PRIVACY_DENIED ]]; then
                        local diagnosis
                        diagnosis=$(diagnose_removal_failure "$removal_rc" "$app_name")
                        IFS='|' read -r reason suggestion <<< "$diagnosis"
                    elif [[ ! -w "$(dirname "$app_path")" ]]; then
                        reason="parent directory not writable"
                    else
                        reason="remove failed, check permissions"
                    fi
                fi
            fi
        fi

        # Remove related files if app removal succeeded.
        _batch_exec_stage="leftover removal"
        if [[ -z "$reason" ]]; then
            if [[ -t 1 ]]; then
                local _phase_prefix=""
                if [[ ${#app_details[@]} -gt 1 ]]; then
                    _phase_prefix="[$current_index/${#app_details[@]}] "
                fi
                start_inline_spinner "${_phase_prefix}Cleaning files for ${app_name}..."
            fi
            local related_remove_rc=0
            remove_file_list "$related_files" "false" \
                "$bundle_id" "$app_path" > /dev/null || related_remove_rc=$?
            mole_rc_timeout_or_signal "$related_remove_rc" && return "$related_remove_rc"
            if [[ $related_remove_rc -eq $MOLE_ERR_OWNER_UNVERIFIED ]]; then
                # Reuse the preview's retained-family state for every later
                # side effect, including system-file removal and helper bootout.
                bundle_id="unknown"
                sibling_guard="guard_login"
                system_files=""
                diag_system=""
            fi

            # Identify leftovers (silent rm failures, e.g. container directories
            # macOS protects via com.apple.provenance xattr). Compute their
            # total size in a single du invocation rather than walking each
            # path; the source paths that DID move to Trash are already gone
            # and would just produce stderr noise we discard.
            local leftover_kb=0
            local -a leftover_paths=()
            if ! is_uninstall_dry_run; then
                while IFS= read -r _lf; do
                    [[ -n "$_lf" && -e "$_lf" ]] || continue
                    # Skip macOS-managed container stubs: containermanagerd protects
                    # the emptied root via com.apple.provenance xattr, so rm -rf
                    # always leaves it. A denied Trash move leaves the whole
                    # container instead, which must be reported and not counted.
                    if [[ $related_remove_rc -ne $MOLE_ERR_OWNER_UNVERIFIED &&
                        "$_lf" == */Library/Containers/* ]]; then
                        local _stub_rc=0
                        _uninstall_container_is_stub "$_lf" || _stub_rc=$?
                        [[ $_stub_rc -eq 0 ]] && continue
                        mole_rc_signal "$_stub_rc" && return "$_stub_rc"
                    fi
                    leftover_paths+=("$_lf")
                done <<< "$related_files"

                if [[ ${#leftover_paths[@]} -gt 0 ]]; then
                    local _du_output="" _du_total=""
                    local _du_rc=0
                    _du_output=$(LC_ALL=C run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" \
                        du -skcP "${leftover_paths[@]}" 2> /dev/null) || _du_rc=$?
                    mole_rc_timeout_or_signal "$_du_rc" && return "$_du_rc"
                    # An unreadable survivor can leave a valid partial total.
                    # Only accept du's final total, never a truncated path row.
                    if [[ $_du_rc -eq 0 || $_du_rc -eq 1 ]]; then
                        _du_total=$(printf '%s\n' "$_du_output" | awk -F '\t' \
                            'END {if (NF == 2 && $1 ~ /^[0-9]+$/ && $2 == "total") print $1}')
                        [[ "$_du_total" =~ ^[0-9]+$ ]] && leftover_kb=$_du_total
                    fi
                fi
            fi

            _batch_exec_stage="system file removal"
            if [[ -t 1 ]]; then
                start_inline_spinner "${_phase_prefix}Cleaning system files for ${app_name}..."
            fi
            if [[ "$used_brew_successfully" == "true" ]]; then
                local system_remove_rc=0
                if [[ -n "$diag_system" ]]; then
                    remove_file_list "$diag_system" "true" \
                        "$bundle_id" "$app_path" > /dev/null || system_remove_rc=$?
                fi
                mole_rc_timeout_or_signal "$system_remove_rc" && return "$system_remove_rc"
            else
                local system_all="$system_files"
                if [[ -n "$diag_system" ]]; then
                    if [[ -n "$system_all" ]]; then
                        system_all+=$'\n'
                    fi
                    system_all+="$diag_system"
                fi
                local system_remove_rc=0
                if [[ -n "$system_all" ]]; then
                    remove_file_list "$system_all" "true" \
                        "$bundle_id" "$app_path" > /dev/null || system_remove_rc=$?
                fi
                mole_rc_timeout_or_signal "$system_remove_rc" && return "$system_remove_rc"
            fi
            if [[ $system_remove_rc -eq $MOLE_ERR_OWNER_UNVERIFIED ]]; then
                bundle_id="unknown"
                sibling_guard="guard_login"
            fi

            # Preferences, including ByHost, belong to the reviewed file plan.
            # A defaults-domain reset or a second scan would bypass data choices.

            # Login item helper ids are read from the selected bundle and are
            # identical across same-bundle-id siblings, so booting them out
            # under the guard would stop the surviving install's running
            # helper.
            if [[ "${sibling_guard:-none}" == "none" ]]; then
                local bootout_rc=0
                bootout_login_item_helpers "$login_item_helpers" || bootout_rc=$?
                [[ $bootout_rc -ge 128 ]] && return "$bootout_rc"
                mole_rc_timeout "$bootout_rc" &&
                    debug_log "Login item helper bootout timed out for $app_name; continuing"
            else
                debug_log "Skipping login item helper bootout for $app_name: helper ids are shared with a surviving install"
            fi

            # All per-app side effects done; tear the spinner down before
            # any echo so the success line does not collide with the spinner.
            [[ -t 1 ]] && stop_inline_spinner

            # Show per-app progress only for multi-app batches. For a single
            # app the summary block right below already names it on the
            # "Removed 1 app" line, so a standalone success line above the
            # box would just duplicate it.
            if [[ -t 1 && ${#app_details[@]} -gt 1 ]]; then
                echo -e "${GREEN}${ICON_SUCCESS}${NC} [$current_index/${#app_details[@]}] ${app_name}"
            fi

            # Include retained ownership refusals from every removal pass once.
            # A dry run applies the same reason filter as a real run: it never
            # stops the app, so a live-cache refusal there describes a state
            # the real run will not be in, and V1.58.0 never listed it.
            local refusal_path refusal_index
            for ((refusal_index = 0; refusal_index < ${#_MOLE_UNINSTALL_REFUSAL_PATHS[@]}; refusal_index++)); do
                refusal_path="${_MOLE_UNINSTALL_REFUSAL_PATHS[$refusal_index]}"
                case "${_MOLE_UNINSTALL_REFUSAL_REASONS[$refusal_index]}" in
                    ownership-unverified | app-reappeared | shared-owner | owner-unknown) ;;
                    *) continue ;;
                esac
                [[ -e "$refusal_path" || -L "$refusal_path" ]] || continue
                if [[ ${#leftover_paths[@]} -eq 0 ]] ||
                    ! mole_identity_in_list "$refusal_path" "${leftover_paths[@]}"; then
                    leftover_paths+=("$refusal_path")
                fi
            done

            # Warn about files that could not be removed and exclude them from freed total.
            if [[ ${#leftover_paths[@]} -gt 0 ]]; then
                # A retained family shares one cause, so name it once instead
                # of repeating it for every path of the family.
                local family_kept_count=0 family_kept_label="" family_kept_first=""
                for _lpath in "${leftover_paths[@]}"; do
                    local kept_reason=""
                    for ((refusal_index = 0; refusal_index < ${#_MOLE_UNINSTALL_REFUSAL_PATHS[@]}; refusal_index++)); do
                        if [[ "${_MOLE_UNINSTALL_REFUSAL_PATHS[$refusal_index]}" == "$_lpath" ]]; then
                            kept_reason="${_MOLE_UNINSTALL_REFUSAL_REASONS[$refusal_index]}"
                        fi
                    done
                    local kept_label="Could not remove"
                    case "$kept_reason" in
                        protected) kept_label="Kept (protected by Mole)" ;;
                        live-cache) kept_label="Kept (app may be active)" ;;
                        access-denied) kept_label="macOS denied access" ;;
                        ownership-unverified) kept_label="Kept (agent ownership unverified; review the plist)" ;;
                        app-reappeared) kept_label="Kept (selected app path exists again; select the app again)" ;;
                        shared-owner) kept_label="Kept (shared with another installed app)" ;;
                        owner-unknown) kept_label="Kept (other copies of the app could not be checked)" ;;
                    esac
                    case "$kept_reason" in
                        app-reappeared | shared-owner | owner-unknown)
                            if [[ $family_kept_count -eq 0 || "$family_kept_label" == "$kept_label" ]]; then
                                [[ $family_kept_count -gt 0 ]] || family_kept_first="$_lpath"
                                family_kept_label="$kept_label"
                                family_kept_count=$((family_kept_count + 1))
                                continue
                            fi
                            ;;
                    esac
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} $kept_label: ${_lpath/#$HOME/$tilde_display}"
                done
                if [[ $family_kept_count -eq 1 ]]; then
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} $family_kept_label: ${family_kept_first/#$HOME/$tilde_display}"
                elif [[ $family_kept_count -gt 1 ]]; then
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} $family_kept_label: $family_kept_count paths"
                fi
                total_kb=$((total_kb - leftover_kb))
                ((total_kb < 0)) && total_kb=0
            fi

            # System-level matches stay review-only. Recheck them after the
            # app and user-owned files are gone so the final summary names
            # only exact paths that still exist.
            if ! is_uninstall_dry_run; then
                local _review_path _review_key
                while IFS= read -r _review_path; do
                    [[ -n "$_review_path" && (-e "$_review_path" || -L "$_review_path") ]] || continue
                    _review_key=$(mole_normalize_path "$_review_path")
                    if [[ ${#review_only_system_leftover_keys[@]} -eq 0 ]] ||
                        ! mole_identity_in_list "$_review_key" "${review_only_system_leftover_keys[@]}"; then
                        review_only_system_leftover_keys+=("$_review_key")
                        review_only_system_leftovers+=("$_review_path")
                    fi
                done <<< "$review_only_system_files"
            fi

            total_size_freed=$((total_size_freed + total_kb))
            success_count=$((success_count + 1))
            [[ "$used_brew_successfully" == "true" ]] && brew_apps_removed=$((brew_apps_removed + 1))
            files_cleaned=$((files_cleaned + 1))
            total_items=$((total_items + 1))
            success_items+=("$app_path")
            success_names+=("$app_name")
            success_dock_targets+=("$app_path|$bundle_id")
            # Check for orphaned system extensions (camera, network, endpoint security, etc.)
            if mole_is_reverse_dns_bundle_id "$bundle_id" && [[ -d /Library/SystemExtensions ]]; then
                local system_extension_path=""
                local has_bundle_system_extension=false
                while IFS= read -r -d '' system_extension_path; do
                    if mole_name_starts_with_bundle_id_boundary "$system_extension_path" "$bundle_id"; then
                        has_bundle_system_extension=true
                        break
                    fi
                done < <(command find /Library/SystemExtensions -maxdepth 3 -name "*.systemextension" -print0 2> /dev/null)
                if [[ "$has_bundle_system_extension" == "true" ]]; then
                    system_extension_warning_apps+=("$app_name")
                fi
            fi
        else
            # Stop spinner before printing the failure line so the error
            # message is not painted over by the spinner's next tick.
            [[ -t 1 ]] && stop_inline_spinner
            if [[ -t 1 ]]; then
                if [[ ${#app_details[@]} -gt 1 ]]; then
                    echo -e "${ICON_ERROR} [$current_index/${#app_details[@]}] ${app_name} ${GRAY}, $reason${NC}"
                else
                    echo -e "${ICON_ERROR} ${app_name} failed: $reason"
                fi
                if [[ -n "${suggestion:-}" ]]; then
                    echo -e "${GRAY}   ${ICON_REVIEW} ${suggestion}${NC}"
                fi
            fi

            failed_count=$((failed_count + 1))
            failed_items+=("$app_name:$reason:${suggestion:-}")
        fi
    done
}
