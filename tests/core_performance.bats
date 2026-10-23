#!/usr/bin/env bats

load helpers/common

setup_file() {
    mole_test_setup_project_root

    TEST_DATA_DIR="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-perf.XXXXXX")"
    export TEST_DATA_DIR
}

teardown_file() {
    rm -rf "$TEST_DATA_DIR"
}

setup() {
    source "$PROJECT_ROOT/lib/core/base.sh"
}

@test "Perl timeout backend backs off short polls and preserves command status" {
    [[ -x /usr/bin/perl ]] || skip "Perl fallback unavailable"
    run /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
export MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN="" MO_TIMEOUT_PERL_BIN=/usr/bin/perl
source "$PROJECT_ROOT/lib/core/timeout.sh"
probe_dir=$(mktemp -d "$TEST_DATA_DIR/poll.XXXXXX")
# SAFE: exact mktemp-created test fixture, removed after the bounded probe exits.
trap 'rm -rf "$probe_dir"' EXIT
cat > "$probe_dir/MolePollProbe.pm" <<'PERL'
package MolePollProbe;
use strict;
use warnings;
use Time::HiRes ();
my $real_sleep = \&Time::HiRes::sleep;
my $polls = 0;
{
    no warnings 'redefine';
    *Time::HiRes::sleep = sub (;@) {
        open my $log, '>>', "$ENV{MOLE_POLL_FIXTURE}/intervals" or die $!;
        print {$log} "$_[0]\n";
        close $log or die $!;
        # The child cannot exit before six polls, even on a busy runner.
        if (++$polls == 6) {
            open my $release, '>', "$ENV{MOLE_POLL_FIXTURE}/release" or die $!;
            close $release or die $!;
        }
        return $real_sleep->(@_);
    };
}
1;
PERL
export PERL5LIB="$probe_dir" PERL5OPT=-MMolePollProbe MOLE_POLL_FIXTURE="$probe_dir"
rc=0
# Both helper and child have a deadline, so a broken handshake cannot hang.
run_with_timeout 10 /bin/bash --noprofile --norc -c '
    deadline=$((SECONDS + 10))
    while [[ ! -f "$MOLE_POLL_FIXTURE/release" ]]; do
        [[ $SECONDS -lt $deadline ]] || exit 99
        sleep 0.01
    done
    exit 7
' < /dev/null || rc=$?
printf 'RC=%s POLLS=%s\n' "$rc" "$(tr '\n' ',' < "$probe_dir/intervals")"
[[ $rc -eq 7 ]] || exit 1
awk '
    BEGIN { split("0.01 0.02 0.04 0.08 0.1 0.1", expected) }
    NR <= 6 && $1 != expected[NR] { bad = 1 }
    $1 <= 0 || $1 > 0.1 { bad = 1 }
    END { exit (bad || NR < 6) }
' "$probe_dir/intervals"
EOF
    [ "$status" -eq 0 ] || { printf '%s\n' "$output"; return 1; }
    [[ "$output" == *"RC=7 POLLS=0.01,0.02,0.04,0.08,0.1,0.1,"* ]]
}

@test "scan workers reap a completed peer before a blocked queue head" {
    run /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
release="$TEST_DATA_DIR/release-$$"
(while [[ ! -f "$release" ]]; do sleep 0.02; done) &
slow=$!
trap 'touch "$release"; wait "$slow" 2>/dev/null || true' EXIT
(exit 7) &
fast=$!
finished=""
rc=0
mole_wait_for_any_worker finished "$slow" "$fast" || rc=$?
[[ "$finished" == "$fast" && "$rc" == 7 ]] || exit 1
kill -0 "$slow" || exit 1
touch "$release"
wait "$slow"
printf 'fast-reaped slow-still-running\n'
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"fast-reaped slow-still-running"* ]] || return 1
}

@test "scan worker polling propagates interrupted sleep" {
    run /bin/bash <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/base.sh"
sleep 10 &
worker=$!
trap 'kill "$worker" 2>/dev/null || true; wait "$worker" 2>/dev/null || true' EXIT
sleep() { return 130; }
finished=""
rc=0
mole_wait_for_any_worker finished "$worker" || rc=$?
[[ "$rc" == 130 && -z "$finished" ]] || exit 1
printf 'interruption-propagated\n'
EOF
    [ "$status" -eq 0 ]
    [[ "$output" == *"interruption-propagated"* ]] || return 1
}

@test "bytes_to_human handles large values efficiently" {
    # Measured in a plain child shell, not in this Bats process: Bats installs a
    # DEBUG trap that inflates 1000 calls to 1-2.5s, which hid a real regression.
    # ~40ms here; the 300ms budget still catches one added fork per call.
    local limit_ms="${MOLE_PERF_BYTES_TO_HUMAN_LIMIT_MS:-300}"
    local elapsed

    elapsed=$(
        /bin/bash --noprofile --norc -c '
            source "$1/lib/core/base.sh"
            bytes_to_human 1073741824 > /dev/null
            start=$(date +%s%N)
            for i in {1..1000}; do
                bytes_to_human 1073741824 > /dev/null
            done
            end=$(date +%s%N)
            printf "%s\n" $(( (end - start) / 1000000 ))
        ' _ "$PROJECT_ROOT"
    )

    [ "$elapsed" -lt "$limit_ms" ] || return 1
}

@test "bytes_to_human produces correct output for GB range" {
    result=$(bytes_to_human 1000000000)
    [ "$result" = "1.00GB" ]

    result=$(bytes_to_human 5000000000)
    [ "$result" = "5.00GB" ]
}

@test "bytes_to_human produces correct output for MB range" {
    result=$(bytes_to_human 1000000)
    [ "$result" = "1.0MB" ]

    result=$(bytes_to_human 100000000)
    [ "$result" = "100.0MB" ]
}

@test "bytes_to_human produces correct output for KB range" {
    result=$(bytes_to_human 1000)
    [ "$result" = "1KB" ]

    result=$(bytes_to_human 10000)
    [ "$result" = "10KB" ]
}

@test "bytes_to_human handles edge cases" {
    result=$(bytes_to_human 0)
    [ "$result" = "0B" ]

    run bytes_to_human "invalid"
    [ "$status" -eq 1 ]
    [ "$output" = "0B" ]

    run bytes_to_human "-100"
    [ "$status" -eq 1 ]
    [ "$output" = "0B" ]
}

# This is a deliberately small execution contract for get_file_size, not a
# shell parser or an OS fork counter. Inspect expanded commands so quoting the
# stat path and literal shell syntax in comments cannot fool the check.
assert_get_file_size_trace() {
    local trace_file="$1" line depth command stat_calls=0
    local trace_pattern='^\++([0-9]+) (.*)$'
    while IFS= read -r line; do
        [[ "$line" =~ $trace_pattern ]] || { printf 'unexpected trace: %s\n' "$line"; return 1; }
        depth="${BASH_REMATCH[1]}"
        command="${BASH_REMATCH[2]}"
        if [[ "$depth" == 1 && "$command" == "$STAT_BSD -f%z "* ]]; then
            stat_calls=$((stat_calls + 1))
            continue
        fi
        [[ "$depth" == 0 ]] || { printf 'extra child-shell work: %s\n' "$line"; return 1; }
        # Bash 3.2 need not wait for an unused process substitution. Its
        # expanded descriptor is visible in the parent trace before return.
        # Both checked inputs are regular temporary paths, never /dev/fd paths.
        [[ "$command" != *'/dev/fd/'* ]] || { printf 'process substitution: %s\n' "$line"; return 1; }
        case "$command" in
            get_file_size\ * | local\ * | echo\ * | printf\ * | wait | 'set +x') ;;
            *)
                [[ "$command" =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]] || {
                    printf 'unexpected command: %s\n' "$line"
                    return 1
                }
                ;;
        esac
    done < "$trace_file"
    [[ "$stat_calls" -eq 1 ]] || { printf 'stat probes: %s\n' "$stat_calls"; return 1; }
}

@test "get_file_size uses one stat probe without extra child-shell work" {
    # A timing ratio against bare stat flaked on busy runners. Bash 3.2 xtrace
    # exposes expanded commands and BASH_SUBSHELL without timing thresholds or
    # another parser dependency. Run outside Bats' own DEBUG instrumentation.
    local test_file="$TEST_DATA_DIR/size_test.txt"
    local trace_file="$BATS_TEST_TMPDIR/size.trace" file expected
    dd if=/dev/zero of="$test_file" bs=1024 count=100 2> /dev/null
    for file in "$test_file" "$TEST_DATA_DIR/missing"; do
        expected=0
        [[ "$file" != "$test_file" ]] || expected=102400
        run /bin/bash --noprofile --norc -s "$PROJECT_ROOT" "$file" "$trace_file" <<'EOF'
source "$1/lib/core/base.sh"
PS4='+${BASH_SUBSHELL} '
{
    set -x
    get_file_size "$2" || exit 1
    wait
    set +x
} 2> "$3"
EOF
        [ "$status" -eq 0 ]
        [ "$output" = "$expected" ]
        assert_get_file_size_trace "$trace_file"
    done
}

@test "get_file_size execution guard rejects extra work and accepts harmless syntax" {
    local variant expected extra body trace_file="$BATS_TEST_TMPDIR/fixture.trace"
    local test_file="$BATS_TEST_TMPDIR/fixture.txt"
    printf 'fixture' > "$test_file"
    for variant in baseline external subshell substitution pipeline process backtick arithmetic comment quoted_stat; do
        expected=1
        # shellcheck disable=SC2016  # These strings are source for a plain fixture shell.
        case "$variant" in
            baseline) extra=''; expected=0 ;;
            external) extra='/usr/bin/true' ;;
            subshell) extra='( : )' ;;
            substitution) extra='extra=$(printf x)' ;;
            pipeline) extra='printf x | /bin/cat > /dev/null' ;;
            process) extra='extra=<(printf x)' ;;
            backtick) extra='extra=`printf x`' ;;
            arithmetic) extra='extra=$((1 + 2))'; expected=0 ;;
            comment) extra='# $(unused) | `unused` <(unused)'; expected=0 ;;
            quoted_stat) extra=''; expected=0 ;;
        esac
        # shellcheck disable=SC2016  # Source for the fixture shell; expanded there.
        body='get_file_size() {
    local file="$1" result extra
    EXTRA
    result=$($STAT_BSD -f%z "$file" 2> /dev/null)
    echo "${result:-0}"
}'
        body="${body/EXTRA/$extra}"
        if [[ "$variant" == quoted_stat ]]; then
            # shellcheck disable=SC2016  # Exercise a quoted command path.
            body="${body/\$STAT_BSD/\"\$STAT_BSD\"}"
        fi
        run /bin/bash --noprofile --norc -s "$body" "$test_file" "$trace_file" "$STAT_BSD" <<'EOF'
eval "$1"
STAT_BSD="$4"
PS4='+${BASH_SUBSHELL} '
{
    set -x
    get_file_size "$2" || exit 1
    wait
    set +x
} 2> "$3"
EOF
        [ "$status" -eq 0 ]
        [ "$output" = 7 ]
        local actual=0
        assert_get_file_size_trace "$trace_file" || actual=$?
        [[ "$actual" -eq "$expected" ]] || { printf 'wrong guard result for %s\n' "$variant"; return 1; }
    done
}

@test "get_file_mtime returns valid timestamp" {
    local test_file="$TEST_DATA_DIR/mtime_test.txt"
    touch "$test_file"

    result=$(get_file_mtime "$test_file")

    [[ "$result" =~ ^[0-9]{10,}$ ]]
}

@test "get_file_owner returns current user for owned files" {
    local test_file="$TEST_DATA_DIR/owner_test.txt"
    touch "$test_file"

    result=$(get_file_owner "$test_file")
    current_user=$(whoami)

    [ "$result" = "$current_user" ]
}

@test "create_temp_file and cleanup_temp_files work efficiently" {
    local start end elapsed
    local limit_ms="${MOLE_PERF_CREATE_TEMP_FILE_LIMIT_MS:-3000}"

    declare -a MOLE_TEMP_DIRS=()

    start=$(date +%s%N)
    for i in {1..50}; do
        create_temp_file > /dev/null
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    [ "$elapsed" -lt "$limit_ms" ]

    [ "${#MOLE_TEMP_FILES[@]}" -eq 50 ]

    start=$(date +%s%N)
    cleanup_temp_files
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))
    [ "$elapsed" -lt "$limit_ms" ]

    [ "${#MOLE_TEMP_FILES[@]}" -eq 0 ]
}

@test "mktemp_file creates files with correct prefix" {
    local temp_file
    temp_file=$(mktemp_file "test_prefix")

    [[ "$temp_file" =~ test_prefix ]] || return 1

    [ -f "$temp_file" ]

    rm -f "$temp_file"
}

@test "get_optimal_parallel_jobs returns sensible values" {
    local result

    result=$(get_optimal_parallel_jobs)
    [[ "$result" =~ ^[0-9]+$ ]] || return 1
    [ "$result" -gt 0 ]
    [ "$result" -le 128 ]

    local scan_jobs
    scan_jobs=$(get_optimal_parallel_jobs "scan")
    [ "$scan_jobs" -gt "$result" ]

    local compute_jobs
    compute_jobs=$(get_optimal_parallel_jobs "compute")
    [ "$compute_jobs" -le "$scan_jobs" ]
}

@test "section tracking has minimal overhead" {
    local start end elapsed

    if ! declare -f note_activity > /dev/null 2>&1; then
        TRACK_SECTION=0
        SECTION_ACTIVITY=0
        note_activity() {
            if [[ $TRACK_SECTION -eq 1 ]]; then
                SECTION_ACTIVITY=1
            fi
        }
    fi

    note_activity

    start=$(date +%s%N)
    for i in {1..1000}; do
        note_activity
    done
    end=$(date +%s%N)

    elapsed=$(( (end - start) / 1000000 ))

    local limit_ms="${MOLE_PERF_SECTION_LIMIT_MS:-2000}"
    [ "$elapsed" -lt "$limit_ms" ]
}
