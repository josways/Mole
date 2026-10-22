#!/bin/bash
# Internal deletion module. Load through file_ops.sh; do not initialize independently.
# Inputs, outcomes and failure behavior: docs/QUALITY_CONTRACTS.md.

# ============================================================================
# Path Validation
# ============================================================================

_mole_normalize_deletion_policy_path() {
    local path="$1"
    local slash="/"
    local double_slash="//"

    while [[ "$path" == *"$double_slash"* ]]; do
        path="${path//$double_slash/$slash}"
    done

    while [[ "$path" == *"/./"* ]]; do
        path="${path//\/\.\//$slash}"
    done
    while [[ "$path" == */. ]]; do
        path="${path%/.}"
        [[ -n "$path" ]] || path="/"
    done

    local trimmed="${path%/}"
    [[ -n "$trimmed" ]] && printf '%s\n' "$trimmed" || printf '%s\n' "$path"
}

# PerfPowerServices keeps one live SQLite database per telemetry store, named
# Current* (CurrentBackgroundProcessingDB.BGSQL, CurrentXcodeOrganizerDB.XCSQL
# and so on), and rotates old data into Archived* files. The main file and its
# WAL companions must stay together while the service runs; unlinking any member
# can split the active database state, and mtime cannot prove it is closed. The
# BackgroundProcessing path is also the one the read-only System Data hint sizes.
readonly MOLE_ACTIVE_POWERLOG_DB_PATH="/private/var/db/powerlog/Library/PerfPowerTelemetry/BackgroundProcessing/CurrentBackgroundProcessingDB.BGSQL"
readonly MOLE_POWERLOG_TELEMETRY_ROOT="/private/var/db/powerlog/Library/PerfPowerTelemetry"

_mole_is_active_powerlog_database_path() {
    local restore_nocasematch=false
    local result=1

    if ! shopt -q nocasematch; then
        shopt -s nocasematch
        restore_nocasematch=true
    fi

    # <root>/<store>/Current*, one level deep; the -wal and -shm companions
    # share the Current prefix.
    case "$1" in
        "$MOLE_POWERLOG_TELEMETRY_ROOT"/*/Current*)
            # Cut by length: the case match folds case, a prefix strip would not.
            local store_and_file="${1:$((${#MOLE_POWERLOG_TELEMETRY_ROOT} + 1))}"
            local store="${store_and_file%%/*}"
            local file="${store_and_file#*/}"
            [[ -n "$store" && "$file" != */* ]] && result=0
            ;;
    esac

    [[ "$restore_nocasematch" == "true" ]] && shopt -u nocasematch
    return "$result"
}

# Live reverse-DNS user-cache guard (#1390).
# Unlinking an open Cache.db (or its -wal/-shm companions) while the owning
# helper still holds the database can send that process into an unbounded write
# loop on unlinked temp files and fill the volume (Autodesk Fusion's
# AcCoreConsole). Size and mtime are never authority for these trees: only a
# conclusive "no matching process" result, plus an open-file check for SQLite
# families, may authorize deletion.
#
# Process-state results are memoized for the current clean process so a batch
# under one cache directory does not fork pgrep once per leaf file. Bash 3.2
# has no associative arrays, so the cache is a pipe-delimited string.

_mole_user_cache_scope() {
    local path="$1"
    local normalized="${path%/}"
    local library_root="${HOME%/}/Library"
    local remainder=""
    local component=""
    local suffix=""
    local scope_type=""

    case "$normalized" in
        "$library_root/Caches"/*)
            remainder="${normalized#"$library_root/Caches"/}"
            component="${remainder%%/*}"
            scope_type="standard"
            ;;
        "$library_root/Containers"/*)
            remainder="${normalized#"$library_root/Containers"/}"
            component="${remainder%%/*}"
            suffix="${remainder#"$component"}"
            case "$suffix" in
                /Data/Library/Caches | /Data/Library/Caches/*) scope_type="container" ;;
                *) return 1 ;;
            esac
            ;;
        "$library_root/Group Containers"/*)
            remainder="${normalized#"$library_root/Group Containers"/}"
            component="${remainder%%/*}"
            suffix="${remainder#"$component"}"
            case "$suffix" in
                /Caches | /Caches/* | /Library/Caches | /Library/Caches/*) scope_type="container" ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac

    # Reverse-DNS style only (com.vendor.app). Named trees such as Homebrew
    # stay outside this gate; they have their own process probes. The separator
    # is excluded so the caller can split this Bash-3.2-compatible record.
    [[ "$component" == *.* && "$component" != .* && "$component" != *"|"* ]] || return 1
    printf '%s|%s\n' "$component" "$scope_type"
    return 0
}

# SQLite main file or -wal / -shm / -journal companion. Case-insensitive so a
# cache sweep cannot delete a database through a case variant of its name
# (contributor PR #1391 + main reverse-DNS gate).
_mole_is_sqlite_database_path() {
    local restore_nocasematch=false
    local result=1
    local path="$1"
    local base="${path%-wal}"
    base="${base%-shm}"
    base="${base%-journal}"

    if ! shopt -q nocasematch; then
        shopt -s nocasematch
        restore_nocasematch=true
    fi

    case "$base" in
        *.db | *.sqlite | *.sqlite3)
            result=0
            ;;
    esac

    [[ "$restore_nocasematch" == "true" ]] && shopt -u nocasematch
    return "$result"
}

_mole_is_user_cache_sqlite_family_path() {
    _mole_is_sqlite_database_path "$1"
}

# Exact browser partial-download files directly under Downloads. These may be
# actively written even when their browser process name is unavailable, so the
# final deletion gate must recheck the file handle itself.
# A partial download is a mutable file some process may still be writing, not a
# rebuildable cache, so callers gate it on an open-handle probe instead of size
# or age. Homebrew's cache belongs here for the same reason the browser roots
# do: `brew fetch` writes `<sha>--<name>.incomplete` and holds it open for the
# length of the transfer, and a blanket sweep of that directory deleted six
# in-flight cask downloads out from under a running fetch (#1594).
_mole_is_incomplete_download_path() {
    local downloads_root="${HOME%/}/Downloads"
    local brew_downloads="${HOME%/}/Library/Caches/Homebrew/downloads"
    local path="$1"
    case "$path" in
        "$downloads_root"/*.download | "$downloads_root"/*.crdownload | "$downloads_root"/*.part)
            [[ "${path#"$downloads_root"/}" != */* ]]
            ;;
        "$brew_downloads"/*.incomplete)
            [[ "${path#"$brew_downloads"/}" != */* ]]
            ;;
        *) return 1 ;;
    esac
}

_mole_user_cache_sqlite_main_path() {
    local path="$1"
    case "$path" in
        *-wal) printf '%s\n' "${path%-wal}" ;;
        *-shm) printf '%s\n' "${path%-shm}" ;;
        *-journal) printf '%s\n' "${path%-journal}" ;;
        *) printf '%s\n' "$path" ;;
    esac
}

_mole_sqlite_family_base_path() {
    _mole_user_cache_sqlite_main_path "$1"
}

# One process-table snapshot per run, mirroring the Mac app's
# ProcessGuard.cachedProcessTable. The answer cannot change between candidates
# inside a single sweep, and the old code forked pgrep up to three times per
# cache directory.
#
# Lines that must not vote are dropped here: Mole's own process, and the
# measurement tools it forks over the very path being judged. `du -skPx
# ~/Library/Caches/<id>` puts <id> in the table purely because Mole is looking
# at it, which would make every slowly-measured cache report its owner as live.
_MOLE_PROCESS_TABLE=""
_MOLE_PROCESS_TABLE_STATE=""

_mole_reset_process_snapshot() {
    _MOLE_PROCESS_TABLE=""
    _MOLE_PROCESS_TABLE_STATE=""
    _MOLE_USER_CACHE_OWNER_STATE_CACHE=""
}

_mole_load_process_table() {
    if [[ -n "${_MOLE_PROCESS_TABLE_STATE:-}" ]]; then
        [[ "$_MOLE_PROCESS_TABLE_STATE" == "ok" ]] || return 1
        return 0
    fi

    local raw=""
    if ! raw=$(ps -axo pid,ppid,comm,args 2> /dev/null) || [[ -z "$raw" ]]; then
        _MOLE_PROCESS_TABLE_STATE="unavailable"
        return 1
    fi
    # Before args, ps cuts comm to 16 bytes; as the LAST column it prints the
    # whole executable path, spaces included. That second read is the only
    # unambiguous answer to "which bundle runs this", because argv can be
    # rewritten and a path with spaces has no field boundary. It rides on the
    # end of each line after \037; a pid missing from it keeps the argv
    # heuristic. A failed read only loses the extra evidence.
    local executables=""
    executables=$(ps -axo pid=,comm= 2> /dev/null) || executables=""

    # Every text tool below runs under LC_ALL=C so it compares BYTES. A process
    # table is not guaranteed to be UTF-8: an app named 富途牛牛 makes awk and
    # grep abort with "illegal byte sequence" in a UTF-8 locale, and an aborted
    # filter would silently shorten the table into a false "owner is idle".
    local filtered=""

    # Mole must not vote on itself. `pgrep -f` skipped the caller for free;
    # a raw table does not, and every candidate id reaches this code as an
    # argument, so the shell running `mo clean` (and any wrapper above it)
    # carries that id in its own argv. Walking the ppid chain drops the whole
    # invoking tree, which is also what excludes the `du` and `find` children
    # forked to MEASURE the very directory being judged.
    if ! filtered=$(printf '%s\n' "$raw" | MOLE_PS_EXECUTABLES="$executables" LC_ALL=C awk -v self="$$" '
        BEGIN {
            rows = split(ENVIRON["MOLE_PS_EXECUTABLES"], exe_rows, "\n")
            for (r = 1; r <= rows; r++) {
                row = exe_rows[r]
                sub(/^[[:space:]]+/, "", row)
                if (!match(row, /^[0-9]+[[:space:]]+\//)) continue
                exe_pid = substr(row, 1, RLENGTH)
                sub(/[[:space:]]+\/$/, "", exe_pid)
                exe_path = substr(row, RLENGTH)
                if (index(exe_path, "\037") == 0) exe[exe_pid] = exe_path
            }
        }
        NR > 1 {
            pid = $1
            parent[pid] = $2
            order[++count] = pid
            # Drop the pid/ppid columns back off the line.
            sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+/, "")
            text[pid] = $0
            comm[pid] = $1
        }
        END {
            for (p = self; p != "" && p != "0" && p != "1" && !(p in seen); p = parent[p]) {
                seen[p] = 1
                mine[p] = 1
            }
            # Descendants too: a command substitution forks a child that
            # inherits our argv verbatim, so the id would come back through
            # the copy even after the ancestor chain is gone.
            for (i = 1; i <= count; i++) {
                pid = order[i]
                depth = 0
                for (p = pid; p != "" && p != "0" && p != "1" && depth < 64; p = parent[p]) {
                    if (p == self) { mine[pid] = 1; break }
                    depth++
                }
            }
            for (i = 1; i <= count; i++) {
                pid = order[i]
                if (pid in mine) continue
                n = split(comm[pid], parts, "/")
                base = parts[n]
                if (base == "du" || base == "find" || base == "mdfind" ||
                    base == "ps" || base == "grep" || base == "stat" ||
                    base == "ls" || base == "rm") continue
                if (index(tolower(text[pid]), "com.tw93.mole") > 0) continue
                if (pid in exe) print text[pid] "\037" exe[pid]
                else print text[pid]
            }
        }'); then
        # A filter that died mid-table would leave a SHORT table, which reads
        # as "nothing owns this cache". Refuse to answer instead.
        _MOLE_PROCESS_TABLE_STATE="unavailable"
        return 1
    fi

    _MOLE_PROCESS_TABLE="$filtered"
    _MOLE_PROCESS_TABLE_STATE="ok"
    return 0
}

# Escape the ERE metacharacters so a cache-dir component is matched as a
# literal. Only these: a backslash before any other byte (`\-`, `\ `) is
# undefined in POSIX ERE, and GNU grep prints "stray \" warnings for it.
_mole_regex_escape() {
    printf '%s' "$1" | LC_ALL=C sed 's/[][(){}.^$*+?|\\]/\\&/g'
}

# Tri-state process probe for a reverse-DNS cache owner:
# 0 = a matching process is running, 1 = none matched, 2 = could not tell.
#
# Two acceptance shapes, deliberately asymmetric (parity with the Mac app's
# ProcessGuard.processListMentionsCacheOwner):
#   1. The full reverse-DNS id appears in the line. Self-identifying, so a
#      plain substring is enough.
#   2. The last DNS label appears as a DELIMITED token AND the same line
#      independently names another component of the id. Corroboration is what
#      makes a shared binary name usable: Claude and VS Code both ship a
#      Squirrel binary called ShipIt, so `pgrep -x ShipIt` attributed VS Code's
#      cache to a running Claude. Measured on this machine before the change,
#      34 of 59 idle caches were called busy; the plain-substring shapes it
#      relied on also read "default" out of syncdefaultsd and "data" out of
#      dataaccessd.
#
# Shape 2 cannot tell sibling channels apart: every Brave Origin Nightly line
# carries "Brave" and "Nightly", so com.brave.Browser.nightly stayed busy for
# as long as the other channel ran, and its cache directory (610 MB of
# abandoned Sparkle downloads on one machine) was never reclaimed. A line whose
# executable lives in an app bundle is therefore attributed by that bundle's
# identifier (_mole_process_line_belongs_to_other_app) before its tokens count.
_mole_user_cache_owner_process_state() {
    local owner="$1"
    [[ -n "$owner" ]] || return 2

    local cache_token="|${owner}:"
    case "${_MOLE_USER_CACHE_OWNER_STATE_CACHE:-}" in
        *"${cache_token}0|"*) return 0 ;;
        *"${cache_token}1|"*) return 1 ;;
        *"${cache_token}2|"*) return 2 ;;
    esac

    if ! _mole_load_process_table; then
        # An unreadable process table is not proof the owner is idle.
        return 2
    fi
    local table="$_MOLE_PROCESS_TABLE"

    # Feed the table by here-string, never through a pipe. `grep -q` exits on
    # its first match, and the printf still writing into that closed pipe takes
    # SIGPIPE, which bash reports as "printf: write error: Broken pipe" on
    # stderr; during `mo clean` that lands in the middle of the user's output.
    local state=1
    if LC_ALL=C grep -qiF -- "$owner" <<< "$table"; then
        state=0
    fi

    local leaf="${owner##*.}"
    if [[ $state -eq 1 && -n "$leaf" && "$leaf" != "$owner" && ${#leaf} -ge 4 ]]; then
        # "com" is in every reverse-DNS id and corroborates nothing.
        local -a corroborators=()
        local old_ifs="$IFS"
        local -a components=()
        IFS='.' read -r -a components <<< "$owner"
        IFS="$old_ifs"
        local index=0
        local last_index=$((${#components[@]} - 1))
        local component
        for component in "${components[@]}"; do
            if [[ $index -lt $last_index && ${#component} -ge 4 ]]; then
                case "$component" in
                    [cC][oO][mM]) ;;
                    *) corroborators+=("$(_mole_regex_escape "$component")") ;;
                esac
            fi
            index=$((index + 1))
        done

        if [[ ${#corroborators[@]} -gt 0 ]]; then
            local escaped_leaf
            escaped_leaf=$(_mole_regex_escape "$leaf")
            local alternation=""
            for component in "${corroborators[@]}"; do
                alternation="${alternation:+$alternation|}$component"
            done
            local boundary_open='(^|[^A-Za-z0-9])'
            local boundary_close='([^A-Za-z0-9]|$)'
            # Two passes, so both tokens must land on the SAME line. Materialize
            # the first result instead of piping into a `grep -q`, for the same
            # broken-pipe reason as the substring check above.
            local leaf_lines=""
            leaf_lines=$(LC_ALL=C grep -iE -- \
                "${boundary_open}${escaped_leaf}${boundary_close}" <<< "$table") || leaf_lines=""
            local corroborated_lines=""
            if [[ -n "$leaf_lines" ]]; then
                corroborated_lines=$(LC_ALL=C grep -iE -- \
                    "${boundary_open}(${alternation})${boundary_close}" <<< "$leaf_lines") || corroborated_lines=""
            fi
            local line
            while IFS= read -r line; do
                [[ -n "$line" ]] || continue
                if _mole_process_line_belongs_to_other_app "$line" "$owner" "$leaf"; then
                    continue
                fi
                state=0
                break
            done <<< "$corroborated_lines"
        fi
    fi

    _MOLE_USER_CACHE_OWNER_STATE_CACHE="${_MOLE_USER_CACHE_OWNER_STATE_CACHE-}${cache_token}${state}|"
    return "$state"
}

# CFBundleIdentifier of an app bundle into _MOLE_APP_BUNDLE_ID, memoized for
# the process (bundles do not change identity while a clean runs). Status 1
# when the plist cannot be read, including a read that times out on a
# dataless bundle; the miss is memoized too, and callers treat it as busy.
_MOLE_APP_BUNDLE_ID_CACHE=""
_MOLE_APP_BUNDLE_ID=""
_mole_app_bundle_identifier() {
    local bundle="$1"
    local cache_token="|${bundle}="
    _MOLE_APP_BUNDLE_ID=""
    case "${_MOLE_APP_BUNDLE_ID_CACHE:-}" in
        *"$cache_token"*)
            local rest="${_MOLE_APP_BUNDLE_ID_CACHE#*"$cache_token"}"
            _MOLE_APP_BUNDLE_ID="${rest%%|*}"
            [[ -n "$_MOLE_APP_BUNDLE_ID" ]]
            return
            ;;
    esac
    local id=""
    id=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        plutil -extract CFBundleIdentifier raw -o - "$bundle/Contents/Info.plist" 2> /dev/null) || id=""
    mole_is_reverse_dns_bundle_id "$id" || id=""
    _MOLE_APP_BUNDLE_ID_CACHE="${_MOLE_APP_BUNDLE_ID_CACHE-}${cache_token}${id}|"
    _MOLE_APP_BUNDLE_ID="$id"
    [[ -n "$id" ]]
}

# A corroborated shape-2 process line whose executable lives in an app bundle
# below /Applications or ~/Applications is attributed by that bundle's id.
# The executable path ps reported for the pid (after \037) decides the bundle.
# Without it, inspect only the leading argv path, removing a truncated comm
# only when argv repeats its prefix. Never search later arguments for an app.
# 0 = the line belongs to a different app, so it says nothing about the owner.
# 1 = the line may be the owner's and its tokens count:
#   - the bundle's identifier is the owner's, or the two extend each other at a
#     label boundary (a settings or helper app inside the owner's bundle);
#   - the executable itself is named after the owner's last label, which is
#     how a helper with its own cache directory runs inside another vendor's
#     bundle (AcCoreConsole inside Autodesk Fusion, #1390);
#   - the identifier cannot be read, or no such bundle path is on the line.
_mole_process_line_belongs_to_other_app() {
    local line="$1" owner="$2" leaf="$3"
    local field root head tail bundle="" executable=""
    if [[ "$line" == *$'\037'* ]]; then
        executable="${line##*$'\037'}"
        line="${line%$'\037'*}"
    fi
    # ps can prefix argv with a truncated 16-byte comm. Remove it only when
    # argv repeats that exact path prefix; otherwise keep uncertain lines busy.
    line="${line#"${line%%[![:space:]]*}"}"
    local comm_prefix="${line:0:16}"
    local arguments="${line:16}"
    arguments="${arguments#"${arguments%%[![:space:]]*}"}"
    if [[ "$comm_prefix" == /* && "$arguments" == "$comm_prefix"* ]]; then
        line="$arguments"
    fi
    field="$line"
    [[ "$executable" == /* ]] && field="$executable"
    for root in /Applications "$HOME/Applications"; do
        [[ "$field" == "$root/"* ]] || continue
        head=""
        tail="$field"
        while [[ "$tail" == *.app/* ]]; do
            head="${head}${tail%%.app/*}.app"
            tail="${tail#*.app/}"
            # Crossing into another absolute argument cannot identify argv[0].
            [[ "$head" != *" /"* ]] || return 1
            if [[ -d "$head" ]]; then
                bundle="$head"
                break 2
            fi
            head="${head}/"
        done
    done
    [[ -n "$bundle" ]] || return 1
    _mole_app_bundle_identifier "$bundle" || return 1
    local id="$_MOLE_APP_BUNDLE_ID"

    local restore_nocasematch=false
    if ! shopt -q nocasematch; then
        shopt -s nocasematch
        restore_nocasematch=true
    fi
    # Labels are [-A-Za-z0-9], so the leaf needs no escaping inside the regex.
    local executable_pattern="/${leaf}([[:space:]]|\$)"
    local other_app=true
    if [[ "$id" == "$owner" || "$id" == "$owner".* || "$owner" == "$id".* ||
        "$line" =~ $executable_pattern || "${executable##*/}" == "$leaf" ]]; then
        other_app=false
    fi
    [[ "$restore_nocasematch" == "true" ]] && shopt -u nocasematch
    [[ "$other_app" == "true" ]]
}

# Is the database family live? 0 = in use, 1 = idle, 2 = could not tell.
# WAL-mode -shm only exists while at least one connection is open (PR #1391),
# but a stale -shm can remain after an unclean exit. When -shm exists we must
# still verify a process holds it open; otherwise the guard refuses forever on
# orphaned caches (#1439).
_mole_sqlite_database_in_use() {
    local path="$1"
    local base
    base=$(_mole_sqlite_family_base_path "$path")

    # Check every family member, including a stale -shm. If any process has a
    # handle open the database is live; if none do, the -shm is orphaned and
    # deletion is safe. One lsof call covers the whole family: forking it per
    # member tripled the live-cache gate's cost once the -shm fast path went
    # away (#1439), and lsof already accepts several names at once.
    local candidate
    local -a family=()
    for candidate in "$base" "${base}-wal" "${base}-shm"; do
        [[ -e "$candidate" ]] || continue
        family[${#family[@]}]="$candidate"
    done
    # Guard the empty expansion: macOS /bin/bash is 3.2, where "${a[@]}" on an
    # empty array is an unbound-variable error under set -u.
    [[ ${#family[@]} -gt 0 ]] || return 1

    _mole_paths_have_open_handle "${family[@]}"
}

_mole_user_cache_sqlite_has_open_handle() {
    local path="$1"
    local state=0
    _mole_sqlite_database_in_use "$path" || state=$?
    return "$state"
}

# Identity captured by the most recent conclusively idle container-cache
# probe. safe_remove rebinds it immediately before rm so a rename-and-recreate
# cannot turn an idle snapshot of the old object into permission for the new
# object at the same path.
_MOLE_CONTAINER_CACHE_PROBE_PARENT=""
_MOLE_CONTAINER_CACHE_PROBE_PARENT_ID=""
_MOLE_CONTAINER_CACHE_PROBE_TARGET_ID=""
_MOLE_COMPLETE_LSOF_MODE=""

_mole_container_cache_probe_deadline() {
    local timeout_seconds="${MOLE_TIMEOUT_MEDIUM_PROBE_SEC:-5}"
    if [[ ! "$timeout_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ||
        "$timeout_seconds" =~ ^0+(\.0+)?$ ]]; then
        timeout_seconds=5
    fi
    local timeout_whole="${timeout_seconds%%.*}"
    local timeout_budget=$((10#$timeout_whole))
    if [[ "$timeout_seconds" == *.* && "${timeout_seconds#*.}" =~ [1-9] ]]; then
        timeout_budget=$((timeout_budget + 1))
    fi
    [[ $timeout_budget -ge 2 ]] || timeout_budget=2
    printf '%s\n' "$((SECONDS + timeout_budget))"
}

_mole_lsof_records_include_root_process() {
    local records="$1"
    local padded=$'\n'"$records"$'\n'
    [[ "$padded" == *$'\np1\n'* && "$padded" == *$'\nu0\n'* ]]
}

# Choose an lsof invocation that can see root-owned processes. macOS may return
# status 1 with no diagnostics when an unprivileged lsof silently omits those
# processes, which is not proof that a cache has no privileged open handles.
# Prefer direct visibility; use only an already-authorized non-interactive sudo
# session as a fallback. Tests and no-auth probes never attempt sudo.
_mole_complete_lsof_mode() {
    local probe_deadline="${1:-}"
    case "${_MOLE_COMPLETE_LSOF_MODE:-}" in
        direct | sudo) return 0 ;;
        unknown) return 2 ;;
    esac

    command -v lsof > /dev/null 2>&1 || {
        _MOLE_COMPLETE_LSOF_MODE="unknown"
        return 2
    }
    declare -f run_with_timeout > /dev/null 2>&1 || {
        _MOLE_COMPLETE_LSOF_MODE="unknown"
        return 2
    }

    local probe_timeout=""
    if ! probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$probe_deadline"); then
        _MOLE_COMPLETE_LSOF_MODE="unknown"
        return 2
    fi

    local records=""
    local probe_rc=0
    records=$(run_with_timeout "$probe_timeout" lsof -F pu -p 1 < /dev/null 2>&1) || probe_rc=$?
    # A timed-out read proves nothing: retain this item, continue other cleanup.
    mole_rc_timeout "$probe_rc" && return 2
    if mole_rc_timeout_or_signal "$probe_rc"; then
        return "$probe_rc"
    fi
    if [[ $probe_rc -eq 0 ]] && _mole_lsof_records_include_root_process "$records"; then
        _MOLE_COMPLETE_LSOF_MODE="direct"
        return 0
    fi

    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]] ||
        ! command -v sudo > /dev/null 2>&1; then
        _MOLE_COMPLETE_LSOF_MODE="unknown"
        return 2
    fi

    if ! probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "$probe_deadline"); then
        _MOLE_COMPLETE_LSOF_MODE="unknown"
        return 2
    fi
    records=""
    probe_rc=0
    records=$(run_with_timeout "$probe_timeout" sudo -n lsof -F pu -p 1 < /dev/null 2>&1) || probe_rc=$?
    # A timed-out read proves nothing: retain this item, continue other cleanup.
    mole_rc_timeout "$probe_rc" && return 2
    if mole_rc_timeout_or_signal "$probe_rc"; then
        return "$probe_rc"
    fi
    if [[ $probe_rc -eq 0 ]] && _mole_lsof_records_include_root_process "$records"; then
        _MOLE_COMPLETE_LSOF_MODE="sudo"
        return 0
    fi

    _MOLE_COMPLETE_LSOF_MODE="unknown"
    return 2
}

_mole_run_complete_lsof() {
    local probe_timeout="$1"
    shift
    case "${_MOLE_COMPLETE_LSOF_MODE:-}" in
        direct) run_with_timeout "$probe_timeout" lsof "$@" < /dev/null ;;
        sudo) run_with_timeout "$probe_timeout" sudo -n lsof "$@" < /dev/null ;;
        *) return 2 ;;
    esac
}

# Is any exact path open? 0 = in use, 1 = idle, 2 = could not tell. A complete
# process view is required before an empty lsof result can authorize deletion.
_mole_paths_have_open_handle() {
    [[ $# -gt 0 ]] || return 1

    local visibility_rc=0
    _mole_complete_lsof_mode || visibility_rc=$?
    if mole_rc_timeout_or_signal "$visibility_rc"; then
        return "$visibility_rc"
    fi
    [[ $visibility_rc -eq 0 ]] || return 2

    local lsof_rc=0
    local open_records=""
    # MO_DEBUG=0 on the capture, because this buffer is EVIDENCE, not output:
    # an empty stderr is what makes rc=1 mean "conclusively idle" below. With
    # the flag on, run_with_timeout writes its own "[TIMEOUT] Running with ..."
    # line into the same stream, the buffer is never empty, and every probe
    # downgrades to "could not tell". Measured on this Mac: 10 of 25 real cache
    # databases flipped from cleanable to kept under `mo clean --debug`, so the
    # flag meant to explain the run was quietly changing it.
    open_records=$(MO_DEBUG=0 _mole_run_complete_lsof "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        -F n -- "$@" 2>&1) || lsof_rc=$?
    if mole_rc_timeout "$lsof_rc"; then
        # An incomplete read-only probe is unknown, not a run cancellation.
        return 2
    fi
    if mole_rc_timeout_or_signal "$lsof_rc"; then
        return "$lsof_rc"
    fi
    if [[ $lsof_rc -eq 0 ]]; then
        return 0
    fi
    # lsof may return 1 when only some requested family members are open. A
    # field record is still positive evidence of use, while diagnostics are an
    # unknown result and must never be discarded as a reliable no-match.
    local padded_records=$'\n'"$open_records"$'\n'
    if [[ "$padded_records" == *$'\nn'* ]]; then
        return 0
    fi
    [[ $lsof_rc -eq 1 && -z "$open_records" ]] || return 2
    return 1
}

# Is any process holding the exact container-cache file, or a descendant of
# the directory, open? 0 = in use, 1 = conclusively idle, 2 = could not tell;
# signal statuses are preserved so clean can stop instead of treating an
# interrupted safety probe as an ordinary skipped item.
_mole_container_cache_has_open_handle() {
    local path="$1"
    _MOLE_CONTAINER_CACHE_PROBE_PARENT=""
    _MOLE_CONTAINER_CACHE_PROBE_PARENT_ID=""
    _MOLE_CONTAINER_CACHE_PROBE_TARGET_ID=""
    command -v lsof > /dev/null 2>&1 || return 2
    declare -f run_with_timeout > /dev/null 2>&1 || return 2
    [[ -e "$path" ]] || return 1

    if [[ -n "${_MOLE_CONTAINER_CACHE_PROBE_DEADLINE+x}" &&
        -z "$_MOLE_CONTAINER_CACHE_PROBE_DEADLINE" ]]; then
        _MOLE_CONTAINER_CACHE_PROBE_DEADLINE=$(_mole_container_cache_probe_deadline)
    fi
    local visibility_rc=0
    _mole_complete_lsof_mode "${_MOLE_CONTAINER_CACHE_PROBE_DEADLINE:-}" || visibility_rc=$?
    if mole_rc_timeout_or_signal "$visibility_rc"; then
        return "$visibility_rc"
    fi
    [[ $visibility_rc -eq 0 ]] || return 2

    local probe_timeout=""
    if ! probe_timeout=$(_mole_timeout_with_deadline "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        "${_MOLE_CONTAINER_CACHE_PROBE_DEADLINE:-}"); then
        debug_log "Container cache handle probe budget exhausted, keep: $path"
        return 2
    fi
    # Bind the exact parent and target objects around lsof. The path can be
    # renamed and recreated while the recursive probe is running.
    _mole_snapshot_path_identity "$path" || return 2
    local expected_parent="$_MOLE_PATH_SNAPSHOT_PARENT"
    local expected_parent_id="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    local expected_target_id="$_MOLE_PATH_SNAPSHOT_TARGET_ID"

    local lsof_rc=0
    local records=""
    if [[ -d "$path" ]]; then
        records=$(MO_DEBUG=0 _mole_run_complete_lsof "$probe_timeout" \
            -F pfn +D "$path" 2>&1) || lsof_rc=$?
    else
        records=$(MO_DEBUG=0 _mole_run_complete_lsof "$probe_timeout" \
            -F pfn -- "$path" 2>&1) || lsof_rc=$?
    fi

    if mole_rc_timeout "$lsof_rc"; then
        # An incomplete read-only probe is unknown, not a run cancellation.
        return 2
    fi
    if mole_rc_timeout_or_signal "$lsof_rc"; then
        return "$lsof_rc"
    fi
    if [[ $lsof_rc -eq 0 ]]; then
        return 0
    fi
    # A recursive walk may report one open record and still fail on another
    # descendant. Field output starts with p/f/n; warning prose does not.
    if [[ -n "$records" ]] && LC_ALL=C grep -qE '^[pfn]' <<< "$records"; then
        return 0
    fi
    # Only status 1 with completely empty output is a conclusive no-match for
    # this snapshot. It is not an ownership lease: safe_remove minimizes the
    # unavoidable reopen window by taking this snapshot at the final sink.
    # Missing lsof/timeout helper, timeout, signal, traversal warning, or other
    # error is unknown and must not authorize deletion.
    [[ $lsof_rc -eq 1 && -z "$records" ]] || return 2
    if ! _mole_path_matches_identity \
        "$path" "$expected_parent" "$expected_parent_id" "$expected_target_id"; then
        debug_log "Container cache identity changed during handle probe, keep: $path"
        return 2
    fi
    _MOLE_CONTAINER_CACHE_PROBE_PARENT="$expected_parent"
    _MOLE_CONTAINER_CACHE_PROBE_PARENT_ID="$expected_parent_id"
    _MOLE_CONTAINER_CACHE_PROBE_TARGET_ID="$expected_target_id"
    return 1
}

# Return 0 when deletion must be refused (live owner or open cache handle).
_mole_should_refuse_live_user_cache_path() {
    local path="$1"
    _MOLE_CONTAINER_CACHE_PROBE_PARENT=""
    _MOLE_CONTAINER_CACHE_PROBE_PARENT_ID=""
    _MOLE_CONTAINER_CACHE_PROBE_TARGET_ID=""
    local scope=""
    scope=$(_mole_user_cache_scope "$path") || return 1
    local owner="${scope%%|*}"
    local scope_type="${scope#*|}"

    local process_state=0
    _mole_user_cache_owner_process_state "$owner" || process_state=$?
    if [[ $process_state -eq 0 ]]; then
        debug_log "Live user cache owner running, keep: $path ($owner)"
        return 0
    fi
    if [[ $process_state -eq 2 ]]; then
        debug_log "Live user cache owner state unknown, keep: $path ($owner)"
        return 0
    fi

    # Container ids and helper process names need not correspond (for example,
    # a team-prefixed Group Container used by SkyComputerUseService). Inspect
    # every open descendant instead of treating process-name silence as idle.
    if [[ "$scope_type" == "container" ]]; then
        # A real safe_remove defers this comparatively expensive recursive
        # probe to its final-sink recheck. Nothing mutates the target between
        # initial validation and that boundary. Dry-run and direct validators
        # do not set this dynamic-scope flag and still probe here.
        if [[ "${_MOLE_DEFER_CONTAINER_HANDLE_PROBE:-false}" == "true" ]]; then
            return 1
        fi
        local container_open_state=0
        _mole_container_cache_has_open_handle "$path" || container_open_state=$?
        if mole_rc_timeout_or_signal "$container_open_state"; then
            return "$container_open_state"
        fi
        if [[ $container_open_state -eq 0 || $container_open_state -eq 2 ]]; then
            debug_log "Container cache handle not conclusively idle, keep: $path"
            return 0
        fi
    # Standard reverse-DNS caches retain the narrower SQLite-family probe.
    elif _mole_is_user_cache_sqlite_family_path "$path"; then
        local open_state=0
        _mole_user_cache_sqlite_has_open_handle "$path" || open_state=$?
        if mole_rc_timeout_or_signal "$open_state"; then
            return "$open_state"
        fi
        if [[ $open_state -eq 0 || $open_state -eq 2 ]]; then
            debug_log "SQLite user cache handle not conclusively idle, keep: $path"
            return 0
        fi
    elif [[ -d "$path" ]]; then
        # A caller's GLOBIGNORE would silently hide database files from this
        # glob, which reads as "no SQLite here" and unblocks the delete. Shadow
        # it with an empty local: bash restores the caller's value AND its
        # attributes on return, so no manual save, `declare -p` parsing, or
        # export-state replay is needed. An empty GLOBIGNORE also turns off the
        # dotglob that bash auto-enables for a non-empty one, so dotglob is set
        # explicitly below and restored by hand (shopt state is not scoped).
        # failglob off keeps an empty cache directory yielding a literal that
        # the -f test drops. Both shopt flags are saved because cleanup helpers
        # elsewhere in the tree set them without restoring. nullglob is left
        # alone: either state reaches the same -f filter.
        local GLOBIGNORE=""
        local candidate open_state family_base seen_base already_seen
        local restore_dotglob=false
        local restore_failglob=false
        local -a sqlite_candidates=()
        local -a sqlite_family_bases=()

        if shopt -q dotglob; then
            restore_dotglob=true
        fi
        if shopt -q failglob; then
            restore_failglob=true
        fi
        shopt -s dotglob
        shopt -u failglob
        sqlite_candidates=("$path"/*)
        if [[ "$restore_dotglob" != "true" ]]; then shopt -u dotglob; fi
        if [[ "$restore_failglob" == "true" ]]; then shopt -s failglob; fi

        if [[ ${#sqlite_candidates[@]} -gt 0 ]]; then
            for candidate in "${sqlite_candidates[@]}"; do
                [[ -f "$candidate" ]] || continue
                _mole_is_user_cache_sqlite_family_path "$candidate" || continue
                family_base=$(_mole_sqlite_family_base_path "$candidate")
                already_seen=false
                if [[ ${#sqlite_family_bases[@]} -gt 0 ]]; then
                    for seen_base in "${sqlite_family_bases[@]}"; do
                        if [[ "$seen_base" == "$family_base" ]]; then
                            already_seen=true
                            break
                        fi
                    done
                fi
                [[ "$already_seen" == "true" ]] && continue
                sqlite_family_bases[${#sqlite_family_bases[@]}]="$family_base"

                open_state=0
                _mole_user_cache_sqlite_has_open_handle "$family_base" || open_state=$?
                if mole_rc_timeout_or_signal "$open_state"; then
                    return "$open_state"
                fi
                if [[ $open_state -eq 0 || $open_state -eq 2 ]]; then
                    debug_log "SQLite under user cache dir not conclusively idle, keep: $path ($family_base)"
                    return 0
                fi
            done
        fi
    fi

    return 1
}

_mole_path_is_same_existing_file() {
    local path="$1"
    local protected_path="$2"
    [[ -e "$path" && -e "$protected_path" && "$path" -ef "$protected_path" ]]
}

_mole_path_is_within_existing_root() {
    local path="$1"
    local protected_root="$2"
    [[ -e "$protected_root" ]] || return 1

    local probe="$path"
    while [[ "$probe" == /* ]]; do
        if _mole_path_is_same_existing_file "$probe" "$protected_root"; then
            return 0
        fi
        [[ "$probe" == "/" ]] && break
        probe="${probe%/*}"
        [[ -n "$probe" ]] || probe="/"
    done
    return 1
}

# Deletion policy only. App/data protection stays in app_protection.sh.
_mole_is_critical_deletion_path() {
    local path="$1"

    case "$path" in
        # Homebrew (Intel) and user-installed software live here; individual
        # entries stay deletable. The Homebrew roots themselves are still
        # critical roots and must fall through to the deny arms below.
        /usr/local/* | /opt/homebrew/*)
            return 1
            ;;
        / | \
            /bin | /bin/* | \
            /dev | /dev/* | \
            /sbin | /sbin/* | \
            /usr | /usr/* | \
            /System | /System/* | \
            /Library | /Library/Apple | /Library/Apple/* | \
            /Library/Application\ Support | \
            /Library/Extensions | /Library/Extensions/* | \
            /Library/Keychains | /Library/Keychains/* | \
            /Applications | \
            /Applications/Finder.app | /Applications/Finder.app/* | \
            /Applications/Safari.app | /Applications/Safari.app/* | \
            /Volumes | \
            /opt | /opt/homebrew | \
            /Users | /Users/Shared | /Users/Guest | /Users/Guest/*)
            return 0
            ;;
        /private | /private/tmp)
            return 0
            ;;
        /etc | /etc/* | /private/etc | /private/etc/*)
            return 0
            ;;
        /var | /var/db | /var/db/* | /var/audit | /var/audit/* | /var/root | \
            /private/var | /private/var/tmp | /private/var/folders | \
            /private/var/db | /private/var/db/* | /private/var/audit | /private/var/audit/* | /private/var/root)
            return 0
            ;;
    esac

    # Reject a user home root (/Users/<name>) while keeping its children
    # deletable. A single case glob cannot express "exactly one component
    # under /Users", so match one level here: this catches the empty-variable
    # collapse "/Users/$user/$leaf" -> "/Users/<name>" that would otherwise
    # hand rm -rf an entire home directory.
    if [[ "$path" == /Users/* && "$path" != /Users/*/* ]]; then
        return 0
    fi

    # APFS is normally case-insensitive but case-preserving. Uppercase aliases
    # such as /SYSTEM and /OPT/HOMEBREW are not symlinks, so string policy
    # checks alone can miss that they are the same inode as protected roots.
    local protected_root
    local -a exact_roots=(
        / /Applications /Library /Volumes /Network /cores /etc /home /net
        /tmp /var /private /private/tmp /private/var /private/var/tmp
        /private/var/folders /Users /opt /opt/homebrew
    )
    for protected_root in "${exact_roots[@]}"; do
        if _mole_path_is_same_existing_file "$path" "$protected_root"; then
            return 0
        fi
    done

    local -a protected_trees=(
        /bin /dev /sbin /usr /System /private/etc /private/var/audit
        /private/var/db /private/var/root /Library/Apple /Library/Extensions
        /Library/Keychains /Applications/Finder.app /Applications/Safari.app
    )
    for protected_root in "${protected_trees[@]}"; do
        if _mole_path_is_within_existing_root "$path" "$protected_root"; then
            return 0
        fi
    done

    # Protect every account root even when a caller changes only component
    # casing (for example /USERS/SHARED on a case-insensitive volume).
    local parent_path="${path%/*}"
    [[ -n "$parent_path" ]] || parent_path="/"
    if _mole_path_is_same_existing_file "$parent_path" "/Users"; then
        return 0
    fi

    return 1
}

# True when path is a direct child of the invoking user's Trash. Emptying Trash
# is an explicit discard contract: cleanup protection for input methods,
# keyboards, and similar names still applies to live Library paths, but not to
# items the user or uninstall already moved into ~/.Trash.
_mole_is_user_trash_top_level_item() {
    local path="$1"
    [[ -n "$path" && "$path" == /* ]] || return 1

    local user_home="${HOME:-}"
    [[ -n "$user_home" && "$user_home" == /* ]] || return 1

    local policy_path
    policy_path=$(_mole_normalize_deletion_policy_path "$path")

    local trash_dir="${user_home%/}/.Trash"
    [[ "${policy_path%/*}" == "$trash_dir" ]]
}

# The batch uninstall caller owns these arrays. Record evidence at the gate,
# not by probing again after removal or reading a previous operation's log.
_mole_record_uninstall_refusal() {
    [[ "${_MOLE_UNINSTALL_REFUSALS_ACTIVE:-0}" == "1" ]] || return 0
    _MOLE_UNINSTALL_REFUSAL_PATHS+=("$1")
    _MOLE_UNINSTALL_REFUSAL_REASONS+=("$2")
}

# Validate path for deletion (absolute, no traversal, not system dir)
# A refusal leaves its fixed operations-log reason in _MOLE_VALIDATION_REASON
# so the sink that asked can record why the path stayed.
validate_path_for_deletion() {
    local path="$1"
    _MOLE_VALIDATION_REASON="invalid path"

    # Check path is not empty
    if [[ -z "$path" ]]; then
        log_error "Path validation failed: empty path"
        return 1
    fi

    # Check path is absolute
    if [[ "$path" != /* ]]; then
        log_error "Path validation failed: path must be absolute: $path"
        return 1
    fi

    # Check for path traversal attempts
    # Only reject .. when it appears as a complete path component (/../ or /.. or ../)
    # This allows legitimate directory names containing .. (e.g., Firefox's "name..files")
    if [[ "$path" =~ (^|/)\.\.(\/|$) ]]; then
        log_error "Path validation failed: path traversal not allowed: $path"
        return 1
    fi

    # Check path doesn't contain dangerous characters
    if [[ "$path" =~ [[:cntrl:]] ]] || [[ "$path" =~ $'\n' ]]; then
        log_error "Path validation failed: contains control characters: $path"
        return 1
    fi

    local policy_path
    policy_path=$(_mole_normalize_deletion_policy_path "$path")
    _MOLE_VALIDATION_REASON="protected"

    # Check symlink target if path is a symbolic link
    if [[ -L "$path" ]]; then
        local link_target
        link_target=$(readlink "$path" 2> /dev/null) || {
            log_error "Cannot read symlink: $path"
            return 1
        }

        # Resolve relative symlinks to absolute paths for validation
        local resolved_target="$link_target"
        if [[ "$link_target" != /* ]]; then
            local link_dir
            link_dir=$(dirname "$path")
            resolved_target=$(cd "$link_dir" 2> /dev/null && cd "$(dirname "$link_target")" 2> /dev/null && pwd)/$(basename "$link_target") || resolved_target=""
        fi

        # Validate resolved target against protected paths
        if [[ -n "$resolved_target" ]]; then
            resolved_target=$(_mole_normalize_deletion_policy_path "$resolved_target")
            if _mole_is_critical_deletion_path "$resolved_target"; then
                log_error "Symlink points to protected system path: $path -> $resolved_target"
                return 1
            fi
        fi
    fi

    # Ancestor-symlink guard. The checks above (deny list, protection policy)
    # match on the LITERAL path string, and the -L test above only inspects the
    # leaf. If any ANCESTOR component is a symlink, the string matches nothing
    # dangerous while the actual rm follows the link into the real target:
    # a redirected "~/Library/Caches" would let a cache sweep walk into
    # ~/Documents or a system tree. Canonicalize the parent (physical cd
    # resolves every ancestor link) and re-run the deny predicates on the
    # resolved leaf. Deny-only: a resolved path never grants permission the
    # literal path lacked, so legitimate targets keep their existing verdict.
    # Runs BEFORE the allowlists below, which would otherwise early-return past
    # this gate for /private/* paths.
    #
    # This sits on the hot path (every deletion candidate), so the common case
    # must stay fork-free: walk the ancestors with the [[ -L ]] builtin and only
    # pay for the canonicalizing subshell when one of them really is a symlink.
    # A dirname + `cd -P` on every call cost ~2ms, about +23% on validation.
    local parent_dir resolved_parent probe
    local ancestor_is_link=false
    parent_dir="${policy_path%/*}"
    [[ -z "$parent_dir" ]] && parent_dir="/"
    if [[ -d "$parent_dir" ]]; then
        probe="$parent_dir"
        while [[ "$probe" == /?* ]]; do
            if [[ -L "$probe" ]]; then
                ancestor_is_link=true
                break
            fi
            probe="${probe%/*}"
        done
    fi
    if [[ "$ancestor_is_link" == "true" ]]; then
        resolved_parent=$(cd -P "$parent_dir" 2> /dev/null && pwd -P) || resolved_parent=""
        if [[ -n "$resolved_parent" && "$resolved_parent" != "$parent_dir" ]]; then
            local resolved_path
            resolved_path=$(_mole_normalize_deletion_policy_path "${resolved_parent}/${policy_path##*/}")
            if _mole_is_critical_deletion_path "$resolved_path"; then
                log_error "Path validation failed: resolves into a critical system path: $path -> $resolved_path"
                return 1
            fi
            if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$resolved_path"; then
                _mole_record_uninstall_refusal "$path" protected
                if [[ "${MO_DEBUG:-0}" == "1" ]]; then
                    log_warning "Path validation: resolves into a protected path: $path -> $resolved_path"
                fi
                return 1
            fi
        fi
    fi

    # Allow deletion of coresymbolicationd cache (safe system cache that can be rebuilt)
    case "$policy_path" in
        /System/Library/Caches/com.apple.coresymbolicationd/data | /System/Library/Caches/com.apple.coresymbolicationd/data/*)
            return 0
            ;;
    esac

    # Reject the active power telemetry database before the broad powerlog
    # allowlist below. Size and mtime are diagnostic signals, never deletion
    # authority for a database that a KeepAlive system service can reopen.
    if _mole_is_active_powerlog_database_path "$policy_path"; then
        debug_log "Path validation: active powerlog database kept: $policy_path"
        return 1
    fi

    # Live reverse-DNS user caches (process + SQLite handle). Covers Autodesk
    # helpers and every other com.vendor tree under ~/Library/Caches (#1390).
    local live_cache_guard_rc=0
    _mole_should_refuse_live_user_cache_path "$policy_path" || live_cache_guard_rc=$?
    if [[ $live_cache_guard_rc -eq 0 ]]; then
        _mole_record_uninstall_refusal "$path" live-cache
        _MOLE_VALIDATION_REASON="live user cache"
        debug_log "Path validation: live user cache kept: $policy_path"
        return 1
    fi
    if mole_rc_timeout_or_signal "$live_cache_guard_rc"; then
        _mole_record_clean_cancellation "$live_cache_guard_rc"
        return "$live_cache_guard_rc"
    fi

    # General SQLite family gate from PR #1391: refuse any in-use database even
    # outside reverse-DNS cache dirs (fail closed when lsof cannot answer).
    if _mole_is_sqlite_database_path "$policy_path"; then
        local sqlite_state=0
        _mole_sqlite_database_in_use "$policy_path" || sqlite_state=$?
        if mole_rc_timeout_or_signal "$sqlite_state"; then
            _mole_record_clean_cancellation "$sqlite_state"
            return "$sqlite_state"
        fi
        if [[ $sqlite_state -eq 0 || $sqlite_state -eq 2 ]]; then
            _MOLE_VALIDATION_REASON="active or unknown SQLite database"
            debug_log "Path validation: in-use SQLite database kept: $policy_path"
            return 1
        fi
    fi

    # Browser partial downloads are mutable user files, not ordinary caches.
    # Recheck them here so safe_remove binds the open-handle evidence at the
    # final deletion boundary instead of trusting an earlier cleanup scan.
    if _mole_is_incomplete_download_path "$policy_path"; then
        local download_open_state=0
        _mole_paths_have_open_handle "$policy_path" || download_open_state=$?
        if mole_rc_timeout_or_signal "$download_open_state"; then
            _mole_record_clean_cancellation "$download_open_state"
            return "$download_open_state"
        fi
        if [[ $download_open_state -eq 0 || $download_open_state -eq 2 ]]; then
            _MOLE_VALIDATION_REASON="active or unknown download"
            debug_log "Path validation: incomplete download not conclusively idle, keep: $policy_path"
            return 1
        fi
    fi

    # Endpoint-security/EDR agent caches under var/folders look like ordinary
    # rebuildable caches, but deleting anything in a sensor's container trips
    # tamper detection (reported as malware). Reject here, before the
    # /private/var/folders allowlist below, so every deletion caller is covered,
    # not only the cleanup sweeps that pre-check the predicate.
    if declare -f is_endpoint_security_cache_path > /dev/null 2>&1 && is_endpoint_security_cache_path "$policy_path"; then
        if [[ "${MO_DEBUG:-0}" == "1" ]]; then
            log_warning "Path validation: endpoint-security agent cache skipped: $policy_path"
        fi
        return 1
    fi

    # Allow known safe paths under /private
    case "$policy_path" in
        /private/tmp/* | \
            /private/var/tmp/* | \
            /private/var/log | /private/var/log/* | \
            /private/var/folders/* | \
            /private/var/db/diagnostics | /private/var/db/diagnostics/* | \
            /private/var/db/DiagnosticPipeline | /private/var/db/DiagnosticPipeline/* | \
            /private/var/db/powerlog | /private/var/db/powerlog/* | \
            /private/var/db/reportmemoryexception | /private/var/db/reportmemoryexception/* | \
            /private/var/db/receipts/*.bom | /private/var/db/receipts/*.plist)
            return 0
            ;;
    esac

    # Check path isn't critical system directory
    if _mole_is_critical_deletion_path "$policy_path"; then
        log_error "Path validation failed: critical system path: $path"
        return 1
    fi

    # Check if path is protected (keychains, system settings, etc)
    if declare -f should_protect_path > /dev/null 2>&1; then
        if _mole_is_user_trash_top_level_item "$policy_path"; then
            :
        elif should_protect_path "$policy_path"; then
            _mole_record_uninstall_refusal "$path" protected
            if [[ "${MO_DEBUG:-0}" == "1" ]]; then
                log_warning "Path validation: protected path skipped: $policy_path"
            fi
            return 1
        fi
    fi

    return 0
}
