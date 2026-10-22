#!/bin/bash
# Internal phase of batch_uninstall_applications; load through batch.sh.
# Reads/writes orchestrator locals via Bash dynamic scope.
# Contracts and phase transitions: docs/QUALITY_CONTRACTS.md.

# Phase 2+3: render the preview block listing every target with its size
# and per-file breakdown, prompt the user for confirmation, and establish
# a sudo session when admin access is needed. Returns:
#   0 - user confirmed and (if needed) sudo session established
#   2 - user cancelled (ESC / 'q' / unknown key)
#   1 - sudo authorization denied
# Reads:  app_details, brew_cask_apps, running_apps, sudo_apps,
#         leftover_notes, total_estimated_size
# shellcheck disable=SC2154  # Inputs are locals owned by batch_uninstall_applications.
_batch_preview_and_confirm() {
    local -a _review_original_details=("${app_details[@]}")
    local -a _review_auto_files=() _review_personal_files=() _review_app_sizes=()
    local -a _review_personal_paths=() _review_selected_paths=()
    _uninstall_prepare_data_review || return $?
    while true; do
        local size_display=$(bytes_to_human "$((total_estimated_size * 1024))")

        echo -e "\n${PURPLE_BOLD}Files to be removed:${NC}"

        local review_index=0
        for detail in "${app_details[@]}"; do
            IFS='|' read -r app_name app_path bundle_id total_kb encoded_files encoded_system_files has_sensitive_data needs_sudo_flag is_brew_cask cask_name encoded_diag_system encoded_review_system encoded_login_item_helpers sibling_guard _expected_app_identity _original_bundle_id _encoded_live_sibling_fingerprint _expected_info_identity <<< "$detail"
            local app_size_display=$(bytes_to_human "$((total_kb * 1024))")

            local brew_tag=""
            [[ "$is_brew_cask" == "true" ]] && brew_tag=" ${CYAN}[Brew]${NC}"
            local steam_managed=false
            if uninstall_app_is_steam_launcher "$app_path"; then
                steam_managed=true
                app_size_display="N/A (Steam-managed)"
            fi
            local display_app_name
            display_app_name=$(_uninstall_display_text "$app_name")
            echo -e "${BLUE}${ICON_CONFIRM}${NC} ${display_app_name}${brew_tag} ${GRAY}, ${app_size_display}${NC}"

            # Show detailed file list for ALL apps (brew casks leave user data behind)
            local system_files=$(decode_file_list "$encoded_system_files" "$app_name")
            local diag_system_display
            diag_system_display=$(decode_file_list "$encoded_diag_system" "$app_name")
            local review_system_display
            review_system_display=$(decode_file_list "$encoded_review_system" "$app_name")
            [[ -n "$diag_system_display" ]] && system_files=$(
                [[ -n "$system_files" ]] && echo "$system_files"
                echo "$diag_system_display"
            )

            if [[ "$steam_managed" == "true" ]]; then
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} Steam launcher only; game files managed by Steam are not included"
            fi
            local leftover_note
            for leftover_note in ${leftover_notes[@]+"${leftover_notes[@]}"}; do
                [[ "${leftover_note%%|*}" == "$app_path" ]] || continue
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} ${leftover_note#*|}"
            done

            local preview_path=""
            preview_path=$(format_uninstall_preview_path "$app_path" "${_review_app_sizes[review_index]}") || return $?
            echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $preview_path"

            # Selected personal data is listed under its own heading below,
            # so only the automatic leftovers sit beside the app.
            _uninstall_print_preview_paths "${_review_auto_files[review_index]}" "  ${GREEN}${ICON_SUCCESS}${NC} " || return $?
            review_index=$((review_index + 1))
            _uninstall_print_preview_paths "$system_files" "  ${BLUE}${ICON_WARNING}${NC} System: " || return $?
            _uninstall_print_preview_paths "$review_system_display" "  ${YELLOW}${ICON_WARNING}${NC} Review only: " || return $?
        done

        if [[ ${#_review_personal_paths[@]} -gt 0 ]]; then
            local kept_data="" removed_data="" personal_path
            for personal_path in "${_review_personal_paths[@]}"; do
                if mole_identity_in_list "$personal_path" "${_review_selected_paths[@]+"${_review_selected_paths[@]}"}"; then
                    removed_data=$(append_line "$removed_data" "$personal_path")
                else
                    kept_data=$(append_line "$kept_data" "$personal_path")
                fi
            done
            if [[ -n "$removed_data" ]]; then
                echo -e "\n${PURPLE_BOLD}Personal data to remove:${NC}"
                _uninstall_print_preview_paths "$removed_data" "  ${GREEN}${ICON_SUCCESS}${NC} " || return $?
            fi
            if [[ -n "$kept_data" ]]; then
                echo -e "\n${GRAY}Personal data kept:${NC}"
                while IFS= read -r personal_path; do
                    local kept_display="$personal_path" tilde='~'
                    kept_display="${kept_display/#$HOME/$tilde}"
                    printf '  %b%s%b\n' "${GRAY}${ICON_REVIEW} " "$(mole_terminal_safe_text "$kept_display")" "$NC"
                done <<< "$kept_data"
            fi
        fi

        # Confirmation before requesting sudo.
        local app_total=${#app_details[@]}
        local app_text="app"
        [[ $app_total -gt 1 ]] && app_text="apps"

        echo ""
        local removal_note="Remove ${app_total} ${app_text}"
        [[ -n "$size_display" ]] && removal_note+=", ${size_display}"
        [[ ${#_review_selected_paths[@]} -eq 0 ]] || removal_note+=", including personal data"
        if [[ ${#running_apps[@]} -gt 0 ]]; then
            removal_note+=" ${YELLOW}[Running]${NC}"
        fi
        [[ ${#_review_personal_paths[@]} -eq 0 ]] || echo -e "${GRAY}D${NC} choose personal data"

        # A read from a non-terminal fails and used to become an empty key,
        # which the case below treats as Enter: a script or agent could confirm
        # an uninstall nobody reviewed. Only a real terminal may answer; tests
        # opt in through the test flags and drive the prompt explicitly.
        if [[ ! -t 0 && "${MOLE_TEST_MODE:-0}" != "1" ]]; then
            echo ""
            # A dry run has nothing to confirm: the list above is the whole
            # answer, so a script or agent reading it gets a clean exit.
            if is_uninstall_dry_run; then
                log_info "Dry run complete; the list above is the plan and no apps were removed."
                return 4
            fi
            log_error "Uninstall confirmation needs an interactive terminal; no apps were removed."
            log_info "Run mo uninstall from an interactive terminal, or use mo uninstall --list to inspect apps"
            return 3
        fi

        echo -ne "${PURPLE}${ICON_ARROW}${NC} ${removal_note}  ${GREEN}Enter${NC} confirm, ${GRAY}ESC${NC} cancel: "

        drain_pending_input # Clean up any pending input before confirmation
        local key="" key_rc=0
        IFS= read -r -s -n1 key || key_rc=$?
        if [[ $key_rc -ne 0 ]]; then
            # Test fixtures drive the prompt through a pipe and may have
            # already consumed it; production only reaches here on a real
            # terminal, where EOF is not consent.
            if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
                key=""
            else
                echo ""
                log_error "Could not read the uninstall confirmation; no apps were removed."
                log_info "Run mo uninstall from an interactive terminal; nothing was changed"
                return 3
            fi
        fi
        drain_pending_input # Clean up any escape sequence remnants
        case "$key" in
            $'\e' | q | Q)
                echo ""
                echo ""
                return 2
                ;;
            d | D)
                [[ ${#_review_personal_paths[@]} -gt 0 ]] || return 2
                _uninstall_choose_personal_data || return $?
                continue
                ;;
            "" | $'\n' | $'\r' | y | Y)
                echo "" # Move to next line
                break
                ;;
            *)
                echo ""
                echo ""
                return 2
                ;;
        esac

    done

    # Enable uninstall mode - allows deletion of data-protected apps (VPNs, dev tools, etc.)
    # that user explicitly chose to uninstall. System-critical components remain protected.
    export MOLE_UNINSTALL_MODE=1

    # Establish sudo once before uninstalling apps that need admin access.
    # Homebrew cask removal can prompt via sudo during uninstall hooks, which
    # does not work reliably under Mole's timed non-interactive execution path.
    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]] &&
        { [[ ${#sudo_apps[@]} -gt 0 ]] || [[ ${#brew_cask_apps[@]} -gt 0 ]]; }; then
        local admin_prompt="Admin required to uninstall selected apps"
        if [[ ${#sudo_apps[@]} -gt 0 && ${#brew_cask_apps[@]} -eq 0 ]]; then
            admin_prompt="Admin required for system apps: ${sudo_apps[*]}"
        elif [[ ${#brew_cask_apps[@]} -gt 0 && ${#sudo_apps[@]} -eq 0 ]]; then
            admin_prompt="Admin required for Homebrew casks: ${brew_cask_apps[*]}"
        fi

        if ! ensure_sudo_session "$admin_prompt"; then
            echo ""
            log_error "Admin access denied"
            return 1
        fi
    fi
}
