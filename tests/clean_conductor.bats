#!/usr/bin/env bats

load helpers/common

setup() {
    mole_test_setup_project_root
    SANDBOX=$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-conductor.XXXXXX")
    export SANDBOX
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME/Conductor/workspaces/repo/workspace" \
        "$HOME/Conductor/archived-contexts/repo/workspace"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "Conductor workspace and archived context usage is queued and report-only (#1800)" {
    run env MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
_large_prefetch_queue_rows
run_with_timeout() { shift; "$@"; }
du() { printf '2097152\t%s\n' "${!#}"; }
agent_worktree_containers() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
safe_clean() { echo UNEXPECTED_DELETE; return 99; }
check_large_file_candidates
SCRIPT
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" == *"$HOME/Conductor/workspaces"* ]] || return 1
    [[ "$output" == *"$HOME/Conductor/archived-contexts"* ]] || return 1
    [[ "$output" == *"Conductor workspaces"* ]] || return 1
    [[ "$output" == *"Conductor archived contexts"* ]] || return 1
    [[ "$output" != *UNEXPECTED_DELETE* ]] || return 1
    [ -d "$HOME/Conductor/workspaces/repo/workspace" ]
    [ -d "$HOME/Conductor/archived-contexts/repo/workspace" ]
}

@test "Conductor usage ignores linked roots and incomplete measurements (#1800)" {
    mv "$HOME/Conductor/workspaces" "$HOME/real-workspaces"
    ln -s "$HOME/real-workspaces" "$HOME/Conductor/workspaces"
    run env MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'SCRIPT'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
_large_prefetch_queue_rows
run_with_timeout() { printf '2097152\tpartial\n'; return 124; }
agent_worktree_containers() { :; }
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
check_large_file_candidates
SCRIPT
    [ "$status" -eq 0 ] || {
        echo "$output"
        return 1
    }
    [[ "$output" != *"Conductor workspaces"* ]] || return 1
    [[ "$output" != *"Conductor archived contexts"* ]] || return 1
    [ -d "$HOME/real-workspaces/repo/workspace" ]
}
