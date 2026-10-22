#!/bin/bash
# User data paths are independent of the installer's --config code root.
# This module is pure: resolving a path never creates, migrates or removes it.
set -euo pipefail

if [[ -n "${MOLE_PATHS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_PATHS_LOADED=1

# Args: output variable, config|cache|logs, optional invoking home.
# Returns 2 for an invalid kind/home/name, without changing the output variable.
# printf -v avoids spawning a subshell on command startup and hot paths.
mole_user_path_into() {
    [[ $# -ge 2 && $# -le 3 ]] || return 2
    [[ "$1" =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ && "$1" != _mole_path_* ]] || return 2
    local _mole_path_home="${3-${HOME:-}}" _mole_path_suffix
    [[ "$_mole_path_home" == /* ]] || return 2
    while [[ "$_mole_path_home" == */ && "$_mole_path_home" != / ]]; do
        _mole_path_home="${_mole_path_home%/}"
    done
    case "$2" in
        config) _mole_path_suffix=".config/mole" ;;
        cache) _mole_path_suffix=".cache/mole" ;;
        logs) _mole_path_suffix="Library/Logs/mole" ;;
        *) return 2 ;;
    esac
    printf -v "$1" '%s/%s' "${_mole_path_home%/}" "$_mole_path_suffix"
}
