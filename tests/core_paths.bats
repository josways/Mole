#!/usr/bin/env bats

load helpers/common

setup() {
    mole_test_setup_project_root
}

@test "user path resolution keeps install roots separate and does not create data" {
    local fixture
    fixture=$(mktemp -d "$BATS_TEST_DIRNAME/tmp-user-paths.XXXXXX")
    run /bin/bash --noprofile --norc -s -- "$fixture" <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/paths.sh"
CONFIG_DIR="$1/custom-install"
mole_user_path_into config config "$1/user/"
mole_user_path_into cache cache "$1/user"
mole_user_path_into logs logs "$1/user"
[[ "$config" == "$1/user/.config/mole" ]] || exit 1
[[ "$cache" == "$1/user/.cache/mole" ]] || exit 1
[[ "$logs" == "$1/user/Library/Logs/mole" ]] || exit 1
[[ ! -e "$1/user" && ! -e "$CONFIG_DIR" ]] || exit 1
EOF
    rm -rf "$fixture" # SAFE: exact mktemp-created path-only fixture.
    [ "$status" -eq 0 ]
}

@test "user path resolver refuses invalid inputs without changing the output" {
    run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/paths.sh"
result=kept
rc=0
mole_user_path_into result unknown /Users/example || rc=$?
[[ $rc -eq 2 && "$result" == kept ]] || exit 1
rc=0
mole_user_path_into result config relative || rc=$?
[[ $rc -eq 2 && "$result" == kept ]] || exit 1
rc=0
mole_user_path_into 'array[0]' config /Users/example || rc=$?
[[ $rc -eq 2 && "$result" == kept ]] || exit 1
EOF
    [ "$status" -eq 0 ]
}
