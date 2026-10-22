#!/bin/bash
# Mole - File Operations
# Safe file and directory manipulation with validation

set -euo pipefail

# Prevent multiple sourcing
if [[ -n "${MOLE_FILE_OPS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_FILE_OPS_LOADED=1

# Error codes for removal operations
readonly MOLE_ERR_SIP_PROTECTED=10
readonly MOLE_ERR_AUTH_FAILED=11
readonly MOLE_ERR_READONLY_FS=12
readonly MOLE_ERR_PROTECTED_PATH=13
readonly MOLE_ERR_PRIVACY_DENIED=14
readonly MOLE_ERR_MUTABLE_PARENT=15
readonly MOLE_ERR_OWNER_UNVERIFIED=16
readonly MOLE_ERR_APP_REAPPEARED=17

# Ensure dependencies are loaded
_MOLE_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${MOLE_BASE_LOADED:-}" ]]; then
    # shellcheck source=lib/core/base.sh
    source "$_MOLE_CORE_DIR/base.sh"
fi
if [[ -z "${MOLE_LOG_LOADED:-}" ]]; then
    # shellcheck source=lib/core/log.sh
    source "$_MOLE_CORE_DIR/log.sh"
fi
if [[ -z "${MOLE_TIMEOUT_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeout.sh
    source "$_MOLE_CORE_DIR/timeout.sh"
fi
if [[ -z "${MOLE_TIMEOUTS_LOADED:-}" ]]; then
    # shellcheck source=lib/core/timeouts.sh
    source "$_MOLE_CORE_DIR/timeouts.sh"
fi

# shellcheck source=lib/core/browser_clones.sh
source "$_MOLE_CORE_DIR/browser_clones.sh"

# Keep the removal-timeout summary actionable: record which path ran out of
# budget so the closing note can name it instead of a bare count.
_mole_record_removal_timeout_path() {
    local path="$1"
    MOLE_CLEAN_REMOVAL_TIMEOUT_PATHS="${MOLE_CLEAN_REMOVAL_TIMEOUT_PATHS:+$MOLE_CLEAN_REMOVAL_TIMEOUT_PATHS
}$path"
}

# Bound production sudo commands while keeping shell-function mocks observable
# in tests. Timeout behavior itself must use a PATH stub so it exercises the
# same external-command branch that users run.
_mole_bounded_sudo() {
    local duration="${1:-${MOLE_TIMEOUT_DISK_VERIFY_SEC:-30}}"
    shift || true
    [[ $# -gt 0 ]] || return 2
    if [[ ! "$duration" =~ ^[0-9]+(\.[0-9]+)?$ || "$duration" =~ ^0+(\.0+)?$ ]]; then
        duration=30
    fi

    if declare -F sudo > /dev/null 2>&1; then
        sudo "$@"
        return $?
    fi

    local sudo_bin=""
    sudo_bin=$(command -v sudo 2> /dev/null || true)
    [[ -n "$sudo_bin" ]] || return 127
    run_with_timeout "$duration" "$sudo_bin" "$@"
}

_mole_bounded_sudo_until() {
    local deadline="$1"
    local requested="$2"
    shift 2
    local duration=""
    duration=$(_mole_timeout_with_deadline "$requested" "$deadline") || return $?
    _mole_bounded_sudo "$duration" "$@"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Format duration in seconds to human readable string (e.g., "5 days", "2 months")
format_duration_human() {
    local seconds="${1:-0}"
    [[ ! "$seconds" =~ ^[0-9]+$ ]] && seconds=0

    local days=$((seconds / 86400))

    if [[ $days -eq 0 ]]; then
        echo "today"
    elif [[ $days -eq 1 ]]; then
        echo "1 day"
    elif [[ $days -lt 7 ]]; then
        echo "${days} days"
    elif [[ $days -lt 30 ]]; then
        local weeks=$((days / 7))
        [[ $weeks -eq 1 ]] && echo "1 week" || echo "${weeks} weeks"
    elif [[ $days -lt 365 ]]; then
        local months=$((days / 30))
        [[ $months -eq 1 ]] && echo "1 month" || echo "${months} months"
    else
        local years=$((days / 365))
        [[ $years -eq 1 ]] && echo "1 year" || echo "${years} years"
    fi
}

# shellcheck source=lib/core/file_ops_policy.sh
source "$_MOLE_CORE_DIR/file_ops_policy.sh"

# shellcheck source=lib/core/file_ops_remove.sh
source "$_MOLE_CORE_DIR/file_ops_remove.sh"

# shellcheck source=lib/core/file_ops_trash.sh
source "$_MOLE_CORE_DIR/file_ops_trash.sh"

# shellcheck source=lib/core/file_ops_log.sh
source "$_MOLE_CORE_DIR/file_ops_log.sh"

# shellcheck source=lib/core/file_ops_find.sh
source "$_MOLE_CORE_DIR/file_ops_find.sh"

# shellcheck source=lib/core/file_ops_size.sh
source "$_MOLE_CORE_DIR/file_ops_size.sh"
