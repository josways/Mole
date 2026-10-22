#!/bin/bash
# Internal phase of batch_uninstall_applications; load through batch.sh.
# Reads/writes orchestrator locals via Bash dynamic scope.
# Contracts and phase transitions: docs/QUALITY_CONTRACTS.md.

# Phase 5+6: assemble the post-removal summary block (success line, failed
# apps, system extension / Background Items / still-running warnings) and emit
# it as a single summary block.
# Reads:  success_count, failed_count, failed_items, success_items,
#         total_size_freed, system_extension_warning_apps,
#         review_only_system_leftovers,
#         background_items_warning_apps, running_at_uninstall_apps
# shellcheck disable=SC2154  # Inputs are locals owned by batch_uninstall_applications.
_batch_render_summary() {
    # Summary
    local freed_display
    freed_display=$(bytes_to_human "$((total_size_freed * 1024))")

    local summary_status="success"
    local -a summary_details=()

    if [[ $success_count -gt 0 ]]; then
        local success_text="app"
        [[ $success_count -gt 1 ]] && success_text="apps"
        local success_line="Removed ${success_count} ${success_text}"
        if is_uninstall_dry_run; then
            success_line="Would remove ${success_count} ${success_text}"
        fi
        if [[ -n "$freed_display" ]]; then
            if is_uninstall_dry_run; then
                success_line+=", would free ${GREEN}${freed_display}${NC}"
            else
                success_line+=", freed ${GREEN}${freed_display}${NC}"
            fi
        fi

        # Format app list with max 3 per line.
        if [[ ${#success_items[@]} -gt 0 ]]; then
            local idx=0
            local is_first_line=true
            local current_line=""

            for success_path in "${success_items[@]}"; do
                local display_name
                display_name=$(basename "$success_path")
                display_name="${display_name%.[aA][pP][pP]}"
                # PlayCover bundles are named after their bundle id (#1715).
                if [[ "${success_path%/*}" == "$(mole_playcover_apps_dir)" && -n "${success_names[$idx]:-}" ]]; then
                    display_name="${success_names[$idx]}"
                fi
                local display_item="${GREEN}${display_name}${NC}"

                if ((idx % 3 == 0)); then
                    if [[ -n "$current_line" ]]; then
                        summary_details+=("$current_line")
                    fi
                    if [[ "$is_first_line" == true ]]; then
                        current_line="${success_line}: $display_item"
                        is_first_line=false
                    else
                        current_line="$display_item"
                    fi
                else
                    current_line="$current_line, $display_item"
                fi
                idx=$((idx + 1))
            done
            if [[ -n "$current_line" ]]; then
                summary_details+=("$current_line")
            fi
        else
            summary_details+=("$success_line")
        fi
    fi

    if [[ $failed_count -gt 0 ]]; then
        summary_status="warn"

        local failed_names=()
        for item in "${failed_items[@]}"; do
            local name=${item%%:*}
            failed_names+=("$name")
        done
        local failed_list="${failed_names[*]}"

        local reason_summary="could not be removed"
        local suggestion_text=""
        if [[ $failed_count -eq 1 ]]; then
            # Extract reason and suggestion from format: app:reason:suggestion
            local item="${failed_items[0]}"
            local without_app="${item#*:}"
            local first_reason="${without_app%%:*}"
            local first_suggestion="${without_app#*:}"

            # If suggestion is same as reason, there was no suggestion part
            # Also check if suggestion is empty
            if [[ "$first_suggestion" != "$first_reason" && -n "$first_suggestion" ]]; then
                suggestion_text="${GRAY}${ICON_REVIEW} ${first_suggestion}${NC}"
            fi

            case "$first_reason" in
                still*running*) reason_summary="is still running" ;;
                remove*failed*) reason_summary="could not be removed" ;;
                permission*denied*) reason_summary="permission denied" ;;
                owned*by*) reason_summary="$first_reason, try with sudo" ;;
                *) reason_summary="$first_reason" ;;
            esac
        fi
        summary_details+=("${ICON_LIST} Failed: ${RED}${failed_list}${NC} ${reason_summary}")
        if [[ -n "$suggestion_text" ]]; then
            summary_details+=("$suggestion_text")
        fi
    fi

    if [[ $success_count -eq 0 && $failed_count -eq 0 ]]; then
        summary_status="info"
        summary_details+=("No applications were uninstalled.")
    fi

    if [[ ${#review_only_system_leftovers[@]} -gt 0 ]]; then
        # Deliberately not a warning, and deliberately one line. The CLI never
        # removes system-level paths, so keeping them is the designed outcome
        # of a successful uninstall, not an incomplete one; marking the run
        # "incomplete" told users something went wrong when nothing had. The
        # exact paths were already listed above the confirmation prompt, so
        # repeating them plus a generic "review these" line only added noise to
        # the block the user reads last, with no action attached to it.
        local kept_count=${#review_only_system_leftovers[@]}
        local kept_label="paths"
        [[ $kept_count -eq 1 ]] && kept_label="path"
        summary_details+=("${ICON_REVIEW} Kept ${kept_count} system-level ${kept_label}, which Mole never removes")
    fi

    if [[ ${#system_extension_warning_apps[@]} -gt 0 ]]; then
        local ext_list=""
        local idx
        for ((idx = 0; idx < ${#system_extension_warning_apps[@]}; idx++)); do
            [[ $idx -gt 0 ]] && ext_list+=", "
            ext_list+="${system_extension_warning_apps[idx]}"
        done

        summary_details+=("${ICON_REVIEW} System extensions may remain after removal: ${YELLOW}${ext_list}${NC}")
        summary_details+=("${GRAY}${ICON_SUBLIST}${NC} Check ${GRAY}System Settings > General > Login Items & Extensions${NC} to remove leftover extensions")
    fi

    if [[ ${#background_items_warning_apps[@]} -gt 0 ]]; then
        local bg_list=""
        local idx
        for ((idx = 0; idx < ${#background_items_warning_apps[@]}; idx++)); do
            [[ $idx -gt 0 ]] && bg_list+=", "
            bg_list+="$(_uninstall_display_text "${background_items_warning_apps[idx]}")"
        done

        summary_details+=("${ICON_REVIEW} Background item still running for ${YELLOW}${bg_list}${NC}, turn it off in ${GRAY}System Settings > Login Items & Extensions${NC}")
    fi

    if [[ ${#running_at_uninstall_apps[@]} -gt 0 ]]; then
        local running_list=""
        local idx
        for ((idx = 0; idx < ${#running_at_uninstall_apps[@]}; idx++)); do
            [[ $idx -gt 0 ]] && running_list+=", "
            running_list+="$(_uninstall_display_text "${running_at_uninstall_apps[idx]}")"
        done

        summary_details+=("${ICON_REVIEW} Still running during uninstall, files removed but process kept alive: ${YELLOW}${running_list}${NC}")
        summary_details+=("${GRAY}${ICON_SUBLIST}${NC} Quit the app to free its in-memory copy; reinstalling before quitting may behave oddly")
    fi

    local title="Uninstall complete"
    if [[ "$summary_status" == "warn" ]]; then
        title="Uninstall incomplete"
    fi
    if is_uninstall_dry_run; then
        title="Uninstall dry run complete"
    fi

    # No blank line here: print_summary_block already opens with one.
    print_summary_block "$title" "${summary_details[@]}"
    printf '\n'
}
