#!/bin/bash
# Internal phase of batch_uninstall_applications; load through batch.sh.
# Reads/writes orchestrator locals via Bash dynamic scope.
# Contracts and phase transitions: docs/QUALITY_CONTRACTS.md.

# Internal helpers for batch_uninstall_applications. They read and write
# locals declared in the orchestrator's scope via bash dynamic scoping; do
# not call them outside batch_uninstall_applications.

# Phase 1: scan every selected app, classify into running/sudo/brew/blocked
# buckets, build pipe-encoded app_details records, accumulate the total
# estimated size, and warn about apps that require an official uninstaller or
# a manual Finder removal.
# Reads:  selected_apps
# Writes: running_apps, sudo_apps, brew_cask_apps, blocked_apps,
#         manual_removal_apps, leftover_notes, app_details, total_estimated_size
_batch_refresh_selected_app_bundle_id() {
    local app_path="$1"
    local fallback_bundle_id="$2"

    [[ -d "$app_path" ]] || return 1
    if declare -f uninstall_resolve_eligible_bundle_id > /dev/null 2>&1; then
        uninstall_resolve_eligible_bundle_id "$app_path" "$fallback_bundle_id"
        return $?
    fi

    # Standalone module tests do not source the inventory resolver. Keep their
    # narrow fallback, while production always takes the eligibility path above.
    [[ -n "$fallback_bundle_id" ]] || return 1
    printf '%s\n' "$fallback_bundle_id"
}

_batch_selected_app_identity() {
    local app_path="$1"
    local identity=""
    local identity_rc=0
    identity=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$STAT_BSD" -f%d:%i:%m "$app_path" 2> /dev/null) || identity_rc=$?
    [[ $identity_rc -eq 0 ]] || return "$identity_rc"
    [[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
    printf '%s\n' "$identity"
}

_batch_selected_app_info_identity() {
    local app_path="$1"
    local info="$app_path/Contents/Info.plist"
    mole_is_playcover_app "$app_path" && info="$app_path/Info.plist"
    if [[ ! -e "$info" && ! -L "$info" ]]; then
        printf '%s\n' "missing"
        return 0
    fi

    local identity=""
    local identity_rc=0
    identity=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$STAT_BSD" -f%d:%i:%m "$info" 2> /dev/null) || identity_rc=$?
    [[ $identity_rc -eq 0 ]] || return "$identity_rc"
    [[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
    printf '%s\n' "$identity"
}

_batch_selected_app_plan_matches() {
    local app_path="$1"
    local expected_app_identity="$2"
    local expected_info_identity="$3"
    [[ -n "$expected_app_identity" && -n "$expected_info_identity" ]] || return 1

    local current_app_identity=""
    local current_info_identity=""
    local identity_rc=0
    current_app_identity=$(_batch_selected_app_identity \
        "$app_path") || identity_rc=$?
    [[ $identity_rc -eq 0 ]] || return "$identity_rc"
    current_info_identity=$(_batch_selected_app_info_identity \
        "$app_path") || identity_rc=$?
    [[ $identity_rc -eq 0 ]] || return "$identity_rc"
    [[ "$current_app_identity" == "$expected_app_identity" &&
        "$current_info_identity" == "$expected_info_identity" ]]
}

# shellcheck disable=SC2154  # Inputs are locals owned by batch_uninstall_applications.
_batch_scan_app_details() {
    local _MOLE_BREW_BATCH_LIST_READY=0 _MOLE_BREW_BATCH_LIST="" _MOLE_BREW_BATCH_LIST_RC=0
    local _MOLE_BREW_BATCH_ROOM_READY=0 _MOLE_BREW_BATCH_ROOM_FILE="" _MOLE_BREW_BATCH_ROOM_RC=0
    local inventory_dir="" scan_rc=0
    local _MOLE_UNINSTALL_DISCOVERY_DEADLINE=$((SECONDS + (2 * MOLE_TIMEOUT_DISK_VERIFY_SEC)))
    if [[ ${#selected_apps[@]} -gt 1 ]] && is_homebrew_available; then
        inventory_dir=$(create_temp_dir) || return 1
        _MOLE_BREW_BATCH_ROOM_FILE="$inventory_dir/caskroom"
        _mole_brew_prepare_batch_inventory || scan_rc=$?
    fi
    if [[ $scan_rc -eq 0 ]]; then
        _batch_scan_app_details_impl || scan_rc=$?
    fi
    if [[ -n "$inventory_dir" ]]; then
        rm -rf -- "$inventory_dir" # SAFE: private read-only Homebrew inventory directory created above
    fi
    return "$scan_rc"
}

# shellcheck disable=SC2154  # Inputs are locals owned by batch_uninstall_applications.
_batch_scan_app_details_impl() {
    # All selected-app discovery shares one wall-clock budget. Individual
    # producer probes clamp themselves to this deadline.
    local _MOLE_UNINSTALL_DISCOVERY_DEADLINE="${_MOLE_UNINSTALL_DISCOVERY_DEADLINE:-$((SECONDS + (2 * MOLE_TIMEOUT_DISK_VERIFY_SEC)))}"
    # Cache current user outside loop
    local current_user=$(whoami)

    if [[ -t 1 ]]; then start_inline_spinner "Scanning files..."; fi
    # shellcheck disable=SC2154 # selected_apps is provided by batch_uninstall_applications via dynamic scope.
    for selected_app in "${selected_apps[@]}"; do
        [[ -z "$selected_app" ]] && continue
        IFS='|' read -r _ app_path app_name bundle_id _ _ <<< "$selected_app"

        _batch_scan_stage="application identity check"
        local current_bundle_id=""
        local refresh_rc=0
        current_bundle_id=$(_batch_refresh_selected_app_bundle_id \
            "$app_path" "$bundle_id") || refresh_rc=$?
        if [[ $refresh_rc -ge 128 ]]; then
            return "$refresh_rc"
        elif [[ $refresh_rc -ne 0 ]]; then
            manual_removal_apps+=("$app_name")
            continue
        fi
        bundle_id="$current_bundle_id"
        local original_bundle_id="$bundle_id"

        # Bind the confirmation record to the exact bundle object that was
        # inspected. A path can be replaced while the preview is open; the
        # execution phase must reject that new inode instead of treating the
        # same pathname as user approval.
        local app_identity=""
        local app_identity_rc=0
        app_identity=$(_batch_selected_app_identity "$app_path") || app_identity_rc=$?
        if mole_rc_timeout_or_signal "$app_identity_rc"; then
            return "$app_identity_rc"
        elif [[ $app_identity_rc -ne 0 ]]; then
            manual_removal_apps+=("$app_name")
            continue
        fi
        local app_info_identity=""
        local app_info_identity_rc=0
        app_info_identity=$(_batch_selected_app_info_identity \
            "$app_path") || app_info_identity_rc=$?
        if mole_rc_timeout_or_signal "$app_info_identity_rc"; then
            return "$app_info_identity_rc"
        elif [[ $app_info_identity_rc -ne 0 ]]; then
            manual_removal_apps+=("$app_name")
            continue
        fi

        # Leftover matching is destructive and must use the current bundle
        # basename, not a display name cached when the selection list opened.
        local discovery_app_name="${app_path##*/}"
        discovery_app_name="${discovery_app_name%.[aA][pP][pP]}"

        local official_vendor=""
        if official_vendor=$(official_uninstaller_vendor "$bundle_id" "$app_name" "$app_path" 2> /dev/null); then
            blocked_apps+=("$app_name|$official_vendor")
            continue
        fi

        # Capture the complete same-bundle installation set that this preview
        # is based on. If a live sibling exists, current display names cannot
        # be trusted from the older inventory that opened the selection UI.
        # Narrow the plan to the selected app bundle only: no bundle-id/name
        # leftovers, login item, process, helper, or Homebrew zap teardown.
        # Execution compares the exact snapshot before its first side effect.
        _batch_scan_stage="other installation check"
        local live_sibling_rc=0
        local live_sibling_present=false
        uninstall_live_bundle_has_other_install \
            "$original_bundle_id" "$app_path" || live_sibling_rc=$?
        if [[ $live_sibling_rc -eq 0 ]]; then
            live_sibling_present=true
        elif [[ $live_sibling_rc -eq 1 ]]; then
            : # Complete absence proof; the empty fingerprint is authoritative.
        elif [[ $live_sibling_rc -eq $MOLE_UNINSTALL_SCAN_PARTIAL ]]; then
            # The scan ran but could not read every path, so it cannot rule a
            # sibling out. Treat that exactly like finding one: narrow the plan
            # and keep going. Aborting here is what left `mo uninstall` exiting
            # 1 with a debug-only line for apps whose scan touched anything TCC
            # protects (#1339, #1340).
            live_sibling_present=true
            # Printed with this app's preview, not here: the scan spinner owns
            # this line, and the note belongs next to the plan it explains.
            local unreadable_what="some paths unreadable"
            if [[ -n "${_MOLE_UNINSTALL_SCAN_UNREADABLE:-}" ]]; then
                # The note is printed with echo -e, so a backslash in the path stays literal.
                unreadable_what="cannot read $(mole_terminal_safe_text "$_MOLE_UNINSTALL_SCAN_UNREADABLE")"
                unreadable_what="${unreadable_what//\\/\\\\}"
            fi
            leftover_notes+=("$app_path|Shared leftovers kept ($unreadable_what)")
            debug_log "Same-bundle scan for $app_name could not read every path; shared leftovers kept"
        elif [[ $live_sibling_rc -ge 128 ]]; then
            return "$live_sibling_rc"
        else
            # The scan could not run at all (restricted receipts, an
            # unreadable app root, a receipt path without Info.plist). That
            # proves nothing either way, and the narrowed plan is safe
            # whether or not a sibling exists: it removes only the selected,
            # identity-bound bundle. Refusing here blocked every uninstall
            # on managed Macs (#1624).
            live_sibling_present=true
            leftover_notes+=("$app_path|Shared leftovers kept (other copies unchecked)")
            debug_log "Could not complete the live same-bundle scan for $app_name (exit $live_sibling_rc)"
        fi
        local preview_live_sibling_fingerprint="$_MOLE_UNINSTALL_LIVE_SIBLING_FINGERPRINT"

        # Receipt enumeration is machine-wide and can consume the whole shared
        # discovery budget on an Xcode Mac (#1383). Guarantee a minimum floor
        # for the selected-app remnant walk so a long sibling scan cannot
        # starve leftover matching and hard-abort the batch with 124.
        local remnant_floor=$((SECONDS + MOLE_TIMEOUT_HINT_SCAN_SEC))
        if ((_MOLE_UNINSTALL_DISCOVERY_DEADLINE < remnant_floor)); then
            debug_log "Extending uninstall discovery deadline by ${MOLE_TIMEOUT_HINT_SCAN_SEC}s for remnant scan of $app_name"
            _MOLE_UNINSTALL_DISCOVERY_DEADLINE=$remnant_floor
        fi

        local sibling_guard="none"
        if [[ "$live_sibling_present" == true ]]; then
            sibling_guard="guard_login"
            discovery_app_name=""
            if [[ $live_sibling_rc -eq 0 ]]; then
                debug_log "Bundle id $bundle_id is shared with a live sibling; removing only the selected app bundle for $app_name"
            else
                debug_log "Could not rule out other copies of bundle id $bundle_id (scan exit $live_sibling_rc); removing only the selected app bundle for $app_name"
            fi
            bundle_id="unknown"
        elif uninstall_bundle_id_has_surviving_sibling "$bundle_id" "$app_path"; then
            sibling_guard="guard"

            local survivor_names
            survivor_names=$(uninstall_surviving_sibling_names "$bundle_id" "$app_path")
            local discovery_lower discovery_base_lower display_lower
            discovery_lower=$(printf '%s' "$discovery_app_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
            discovery_base_lower=$(uninstall_strip_version_suffix "$discovery_app_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')
            display_lower=$(printf '%s' "$app_name" | LC_ALL=C tr '[:upper:]' '[:lower:]')

            local survivor_name login_name_collides=false
            while IFS= read -r survivor_name; do
                [[ -z "$survivor_name" ]] && continue
                # Equality catches the display-name collapse. The substring
                # direction catches the inverse case: uninstalling "Foo.app"
                # while "Foo-beta.app" survives. Name-based leftover matchers
                # use substrings, so a discovery name contained anywhere in a
                # survivor identifier can still reach survivor data.
                # Reverse containment (survivor inside discovery) stays
                # allowed: patterns keyed on the longer "Foo-beta" cannot
                # match the survivor's shorter "Foo"-keyed paths.
                if [[ "$discovery_lower" == "$survivor_name" || "$discovery_base_lower" == "$survivor_name" ||
                    "$survivor_name" == *"$discovery_lower"* || "$survivor_name" == *"$discovery_base_lower"* ]]; then
                    discovery_app_name=""
                fi
                # Login items are registered under the display name; when that
                # string also belongs to the survivor, deleting it by name
                # would remove the survivor's login item.
                if [[ "$display_lower" == "$survivor_name" ]]; then
                    login_name_collides=true
                fi
            done <<< "$survivor_names"
            if [[ -z "$discovery_app_name" ]]; then
                login_name_collides=true
            fi
            [[ "$login_name_collides" == true ]] && sibling_guard="guard_login"

            if [[ -n "$discovery_app_name" ]]; then
                debug_log "Bundle id $bundle_id shared with a surviving install; restricting $app_name leftovers to name/path matches for '$discovery_app_name'"
            else
                debug_log "Bundle id $bundle_id shared with a surviving install and names collide; removing only the app bundle for $app_name"
            fi
            bundle_id="unknown"
        fi

        # Check running app by bundle executable if available
        local exec_name=""
        local info_plist="$app_path/Contents/Info.plist"
        mole_is_playcover_app "$app_path" && info_plist="$app_path/Info.plist"
        if [[ -e "$info_plist" ]]; then
            exec_name=$(plutil -extract CFBundleExecutable raw "$info_plist" 2> /dev/null || echo "")
        fi
        # A shared runtime name such as Electron would report any other
        # unrenamed Electron app as this one.
        if _uninstall_app_running_by_executable "$app_name" "$exec_name"; then
            running_apps+=("$app_name")
        fi

        _batch_scan_stage="Homebrew ownership check"
        local cask_name="" is_brew_cask="false"
        if command -v get_brew_cask_name > /dev/null 2>&1; then
            local detected_cask=""
            local cask_detect_rc=0
            detected_cask=$(get_brew_cask_name "$app_path" 2> /dev/null) || cask_detect_rc=$?
            if mole_rc_timeout_or_signal "$cask_detect_rc"; then
                return "$cask_detect_rc"
            elif [[ $cask_detect_rc -ne 0 && $cask_detect_rc -ne 1 ]]; then
                # A cask brew cannot parse still lists cleanly under
                # `brew list --cask`, so the app name is the only handle the
                # abort message can give the user on which selection failed.
                _batch_scan_app_name="$app_name"
                return "$cask_detect_rc"
            fi
            if [[ -n "$detected_cask" ]]; then
                cask_name="$detected_cask"
                is_brew_cask="true"
            fi
        fi

        if [[ "$is_brew_cask" == "true" ]]; then
            brew_cask_apps+=("$app_name")
        fi

        # A Trash rename is authorized by the source and destination parents,
        # not by the app bundle's owner. Do not elevate solely because a
        # package-installed app is root-owned when its parent is user-writable;
        # file_ops can retry a TCC-blocked rename through unprivileged Finder.
        # Permanent removal still treats foreign ownership as requiring sudo.
        local needs_sudo=false
        local app_owner=$(get_file_owner "$app_path")
        local delete_mode="${MOLE_DELETE_MODE:-permanent}"
        if [[ ! -w "$(dirname "$app_path")" ]] ||
            { [[ "$delete_mode" != "trash" ]] &&
                { [[ "$app_owner" == "root" ]] ||
                    [[ -n "$app_owner" && "$app_owner" != "$current_user" ]]; }; }; then
            needs_sudo=true
        fi

        # A privileged path-based removal below an invoking-user-mutable
        # ancestor cannot bind the path we previewed to the object root later
        # removes. Reject it before leftover discovery, sudo authorization, or
        # any launch/login/process teardown. Homebrew casks stay on their
        # package-manager path and never use this direct-app preflight.
        if [[ "$needs_sudo" == true && "$is_brew_cask" != "true" ]] &&
            _mole_privileged_path_has_mutable_ancestor "$app_path"; then
            manual_removal_apps+=("$app_name")
            continue
        fi

        _batch_scan_stage="application size check"
        local app_size_kb="0"
        local app_size_rc=0
        app_size_kb=$(get_path_size_kb "$app_path") || app_size_rc=$?
        mole_rc_timeout_or_signal "$app_size_rc" && return "$app_size_rc"
        [[ $app_size_rc -eq 0 && "$app_size_kb" =~ ^[0-9]+$ ]] || app_size_kb=0
        local related_files="" diag_user="" diag_system=""
        # system_files is a newline-separated string, not an array.
        # shellcheck disable=SC2178,SC2128
        local system_files=""
        # discovery_app_name is empty only in the sibling-guard name-collision
        # case: every name-derived pattern would belong to the survivor, and
        # find_app_system_files has no empty-name guard (it would emit root
        # dirs like "/Library/Application Support/"). Skip discovery entirely
        # and remove just the app bundle.
        if [[ -n "$discovery_app_name" ]]; then
            # Under the sibling guard, also disable the regex-keyed toolchain
            # heuristics in find_app_files (DerivedData, DeviceSupport, ...):
            # they match "Xcode-beta" by substring and would still queue
            # caches the surviving install uses.
            local sibling_survives=0
            [[ "$sibling_guard" != "none" ]] && sibling_survives=1
            _batch_scan_stage="leftover scan"
            local discovery_rc=0
            related_files=$(MOLE_UNINSTALL_SIBLING_SURVIVES="$sibling_survives" \
                find_app_files "$bundle_id" "$discovery_app_name" \
                "$app_path") || discovery_rc=$?
            if mole_rc_timeout "$discovery_rc"; then
                # Out of budget after a heavy machine-wide probe (#1383): keep
                # the selected app removable and leave leftovers alone rather
                # than aborting the whole batch with "nothing was removed".
                related_files=""
                leftover_notes+=("$app_path|Leftovers kept (scan timed out)")
                debug_log "Leftover scan for $app_name timed out; only the app bundle will be removed"
            elif [[ $discovery_rc -ne 0 ]]; then
                return "$discovery_rc"
            fi
            # Diagnostic-report discovery prefers CFBundleExecutable from the
            # selected bundle, and same-bundle-id siblings ship the same
            # executable name ("Xcode" for Xcode-beta.app), so under the
            # guard it would collect the survivor's crash reports no matter
            # which name is passed in. Leaving crash logs behind is the
            # fail-safe direction. Skip follow-on probes when leftover
            # discovery already timed out so we do not burn the floor budget.
            if [[ "$sibling_guard" == "none" ]] && ! mole_rc_timeout "$discovery_rc"; then
                _batch_scan_stage="diagnostic report scan"
                local diag_rc=0
                diag_user=$(get_diagnostic_report_paths_for_app "$app_path" \
                    "$discovery_app_name" \
                    "$HOME/Library/Logs/DiagnosticReports") || diag_rc=$?
                if mole_rc_timeout "$diag_rc"; then
                    diag_user=""
                    debug_log "Diagnostic report scan timed out for $app_name"
                elif [[ $diag_rc -ne 0 ]]; then
                    return "$diag_rc"
                fi
                [[ -n "$diag_user" ]] && related_files=$(
                    [[ -n "$related_files" ]] && echo "$related_files"
                    echo "$diag_user"
                )
                diag_rc=0
                diag_system=$(get_diagnostic_report_paths_for_app "$app_path" \
                    "$discovery_app_name" "/Library/Logs/DiagnosticReports") || diag_rc=$?
                if mole_rc_timeout "$diag_rc"; then
                    diag_system=""
                    debug_log "System diagnostic report scan timed out for $app_name"
                elif [[ $diag_rc -ne 0 ]]; then
                    return "$diag_rc"
                fi
            fi
            if ! mole_rc_timeout "$discovery_rc"; then
                _batch_scan_stage="system leftover scan"
                local system_rc=0
                system_files=$(find_app_system_files \
                    "$bundle_id" "$discovery_app_name") || system_rc=$?
                if mole_rc_timeout "$system_rc"; then
                    system_files=""
                    debug_log "System leftover scan timed out for $app_name"
                elif [[ $system_rc -ne 0 ]]; then
                    return "$system_rc"
                fi
            fi
        fi
        # Preview and execution share the uninstall protection policy. Do not
        # probe live handles here: the sudo session is not established yet.
        local eligible_related_files="" related_path=""
        while IFS= read -r related_path; do
            [[ -n "$related_path" ]] || continue
            if MOLE_UNINSTALL_MODE=1 should_protect_path "$related_path"; then
                continue
            fi
            eligible_related_files=$(append_line "$eligible_related_files" "$related_path")
        done <<< "$related_files"
        related_files="$eligible_related_files"
        local review_only_system_files="$system_files"
        review_only_system_files=$(append_line "$review_only_system_files" "$diag_system")
        # System-level remnants are review-only in the CLI: shown in the preview
        # via review_only_system_files (encoded into encoded_review_system) but
        # never deleted. Blanking system_files/diag_system here is what enforces
        # that: _batch_execute_removals decodes the now-empty encoded_system_files
        # and encoded_diag_system fields and therefore skips them. Do NOT remove
        # this blanking, or system files would become deletable again.
        system_files=""
        diag_system=""
        # The review classifies personal data before measuring leftovers.
        # Until then this field carries only this invocation's bundle size.
        local total_kb=$app_size_kb
        total_estimated_size=$((total_estimated_size + total_kb))

        if [[ "$needs_sudo" == "true" ]]; then
            sudo_apps+=("$app_name")
        fi

        # Check for sensitive user data once.
        local has_sensitive_data="false"
        local sensitive_rc=0
        has_sensitive_data "$related_files" 2> /dev/null || sensitive_rc=$?
        if [[ $sensitive_rc -eq 0 ]]; then
            has_sensitive_data="true"
        elif mole_rc_timeout_or_signal "$sensitive_rc"; then
            return "$sensitive_rc"
        fi

        # Store details for later use (base64 keeps lists on one line).
        local encoded_files
        encoded_files=$(printf '%s' "$related_files" | base64 | tr -d '\n' || echo "")
        local encoded_system_files
        encoded_system_files=$(printf '%s' "$system_files" | base64 | tr -d '\n' || echo "")
        local encoded_diag_system
        encoded_diag_system=$(printf '%s' "$diag_system" | base64 | tr -d '\n' || echo "")
        local encoded_review_system
        encoded_review_system=$(printf '%s' "$review_only_system_files" | base64 | tr -d '\n' || echo "")
        local login_item_helpers=""
        local login_helpers_rc=0
        login_item_helpers=$(discover_login_item_helper_bundle_ids \
            "$app_path") || login_helpers_rc=$?
        if mole_rc_timeout "$login_helpers_rc"; then
            login_item_helpers=""
            debug_log "Login-item helper discovery timed out for $app_name"
        elif [[ $login_helpers_rc -ne 0 ]]; then
            return "$login_helpers_rc"
        fi
        local encoded_login_item_helpers
        encoded_login_item_helpers=$(printf '%s' "$login_item_helpers" | base64 | tr -d '\n' || echo "")
        local encoded_live_sibling_fingerprint
        encoded_live_sibling_fingerprint=$(printf '%s' "$preview_live_sibling_fingerprint" | base64 | tr -d '\n') || return 1
        app_details+=("$app_name|$app_path|$bundle_id|$total_kb|$encoded_files|$encoded_system_files|$has_sensitive_data|$needs_sudo|$is_brew_cask|$cask_name|$encoded_diag_system|$encoded_review_system|$encoded_login_item_helpers|$sibling_guard|$app_identity|$original_bundle_id|$encoded_live_sibling_fingerprint|$app_info_identity")
    done
    if [[ -t 1 ]]; then stop_inline_spinner; fi

    if [[ ${#blocked_apps[@]} -gt 0 ]]; then
        local blocked_detail blocked_name blocked_vendor
        for blocked_detail in "${blocked_apps[@]}"; do
            IFS='|' read -r blocked_name blocked_vendor <<< "$blocked_detail"
            log_warning "$(_uninstall_display_text "$blocked_name") requires the official $blocked_vendor uninstaller"
        done
    fi

    if [[ ${#manual_removal_apps[@]} -gt 0 ]]; then
        local manual_name
        for manual_name in "${manual_removal_apps[@]}"; do
            log_warning "$(_uninstall_display_text "$manual_name") cannot be removed safely by Mole from this location"
            log_info "Move it to Trash in Finder; Mole left protected containers and app data untouched"
        done
    fi
}
