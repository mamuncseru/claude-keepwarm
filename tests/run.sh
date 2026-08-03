#!/usr/bin/env bash
#
# keepwarm test suite. No network, no API calls, no real crontab.
#
# Each test runs in a throwaway sandbox with a PATH shim providing a stub
# `claude` (canned responses, counts invocations) and a fake `crontab`
# (reads/writes a temp file). That makes install/uninstall safe to test and
# keeps results independent of the developer's real environment.
#
#   ./tests/run.sh            run everything
#   ./tests/run.sh floor      run tests whose name matches "floor"
#
set -uo pipefail

ROOT="$(cd -P "$(dirname "$0")/.." && pwd)"
KW="$ROOT/keepwarm"
FILTER="${1:-}"
ORIG_PATH="$PATH"

PASS=0
FAIL=0
FAILED=""

# ------------------------------------------------------------------ harness --

RED=""; GREEN=""; OFF=""
if [ -t 1 ]; then RED=$'\033[31m'; GREEN=$'\033[32m'; OFF=$'\033[0m'; fi

setup() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/keepwarm-test.XXXXXX")"
    BIN="$SANDBOX/bin"
    mkdir -p "$BIN" "$SANDBOX/home" "$SANDBOX/activity"

    STUB_LOG="$SANDBOX/calls"
    : >"$STUB_LOG"
    FAKE_CRONTAB="$SANDBOX/crontab.txt"
    : >"$FAKE_CRONTAB"

    cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf 'call\n' >>"${STUB_LOG:-/dev/null}"
case "${STUB_MODE:-ok}" in
  limited)
    printf 'Claude usage limit reached. Your limit will reset at 3pm.\n'; exit 0 ;;
  error)
    printf '{"is_error":true,"result":"stub failure","total_cost_usd":0}\n'; exit 1 ;;
  auth)
    printf '%s\n' '{"is_error":true,"duration_api_ms":0,"stop_reason":"stop_sequence","total_cost_usd":0,"terminal_reason":"api_error","result":"Failed to authenticate: OAuth session expired and could not be refreshed","type":"result"}'; exit 1 ;;
  flaky)
    # fail the first attempt, succeed afterwards
    if [ "$(wc -l <"${STUB_LOG:-/dev/null}" | tr -d ' ')" -le 1 ]; then
      printf '{"is_error":true,"result":"transient"}\n'; exit 1
    fi
    printf '{"is_error":false,"result":"ok","usage":{"input_tokens":167,"output_tokens":71}}\n'; exit 0 ;;
  *)
    printf '{"is_error":false,"result":"ok","total_cost_usd":0.000522,"usage":{"input_tokens":167,"output_tokens":71}}\n'; exit 0 ;;
esac
STUB

    cat >"$BIN/crontab" <<'FAKE'
#!/usr/bin/env bash
f="${FAKE_CRONTAB:?fake crontab path not set}"
case "${1:-}" in
  -l) if [ -s "$f" ]; then cat "$f"; else printf 'no crontab\n' >&2; exit 1; fi ;;
  -r) : >"$f" ;;
  -)  cat >"$f" ;;
  *)  printf 'unsupported crontab arg: %s\n' "${1:-}" >&2; exit 2 ;;
esac
FAKE

    chmod +x "$BIN/claude" "$BIN/crontab"

    export PATH="$BIN:$ORIG_PATH"
    export STUB_LOG FAKE_CRONTAB
    export STUB_MODE="ok"
    export KEEPWARM_HOME="$SANDBOX/home"
    export KEEPWARM_ACTIVITY_DIR="$SANDBOX/activity"
    export KEEPWARM_PING_ATTEMPTS=2
    export KEEPWARM_PING_RETRY_DELAY=0
}

teardown() {
    export PATH="$ORIG_PATH"
    [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

calls()      { wc -l <"$STUB_LOG" | tr -d ' '; }
# SC1091: the state file is generated at runtime, so there is nothing to follow.
# shellcheck disable=SC1091
state_get()  { ( . "$KEEPWARM_HOME/state/window.env" 2>/dev/null; eval "printf '%s' \"\${$1:-}\"" ); }
logtext()    { cat "$KEEPWARM_HOME/logs/keepwarm.log" 2>/dev/null; }

# write_state <window_start_epoch>
write_state() {
    mkdir -p "$KEEPWARM_HOME/state"
    cat >"$KEEPWARM_HOME/state/window.env" <<EOF
WINDOW_START=$1
WINDOW_END=$(( $1 + 18000 ))
LAST_PING=$1
LAST_STATUS=ok
EOF
}

# The tests need the same GNU/BSD date shim the script uses. Detecting it
# here (rather than chaining `||` fallbacks) matters because BSD `date -d`
# means "set DST" and silently succeeds instead of failing.
if [ "$(date -u -d '@0' '+%Y' 2>/dev/null)" = "1970" ]; then TD="gnu"; else TD="bsd"; fi
t_fmt()   { if [ "$TD" = "gnu" ]; then date -d "@$1" "$2"; else date -r "$1" "$2"; fi; }
t_parse() { if [ "$TD" = "gnu" ]; then date -d "$1" '+%s'
            else date -j -f '%Y-%m-%d %H:%M:%S' "$1" '+%s'; fi; }

# An hour boundary N hours in the past.
hours_ago_boundary() {
    local t=$(( $(date '+%s') - $1 * 3600 ))
    t_parse "$(t_fmt "$t" '+%Y-%m-%d %H:00:00')"
}

fail_test() { FAIL=$(( FAIL + 1 )); FAILED="$FAILED\n    - $CURRENT: $1"; printf '%s  FAIL%s %s\n      %s\n' "$RED" "$OFF" "$CURRENT" "$1"; }

assert_eq() {
    if [ "$1" = "$2" ]; then return 0; fi
    fail_test "${3:-assertion}: expected [$1], got [$2]"
    return 1
}

assert_match() {
    if printf '%s' "$1" | grep -qE "$2"; then return 0; fi
    fail_test "${3:-assertion}: expected to match /$2/, got [$(printf '%s' "$1" | head -c 200)]"
    return 1
}

run_test() {
    CURRENT="$1"
    case "$CURRENT" in *"$FILTER"*) ;; *) return 0 ;; esac
    setup
    OK_BEFORE=$FAIL
    "$1"
    if [ "$FAIL" -eq "$OK_BEFORE" ]; then
        PASS=$(( PASS + 1 ))
        printf '%s  ok  %s %s\n' "$GREEN" "$OFF" "$CURRENT"
    fi
    teardown
}

# -------------------------------------------------------------------- tests --

test_ping_opens_window_on_the_hour() {
    "$KW" ping >/dev/null 2>&1
    local start end
    start="$(state_get WINDOW_START)"
    end="$(state_get WINDOW_END)"
    assert_eq "1" "$(calls)" "claude called exactly once"
    assert_eq "ok" "$(state_get LAST_STATUS)" "status recorded"
    assert_eq "0" "$(( start % 60 ))" "window start is on a minute boundary"
    assert_eq "00:00" "$(t_fmt "$start" '+%M:%S')" "window start floored to the top of the hour"
    assert_eq "18000" "$(( end - start ))" "window is 5 hours long"
}

test_run_with_no_state_pings() {
    "$KW" run >/dev/null 2>&1
    assert_eq "1" "$(calls)" "first run pings"
    assert_match "$(logtext)" "WINDOW +opened" "logs the new window"
}

test_run_inside_window_does_not_ping() {
    "$KW" run >/dev/null 2>&1          # opens a window
    "$KW" run >/dev/null 2>&1          # should be a no-op
    "$KW" run >/dev/null 2>&1
    assert_eq "1" "$(calls)" "no extra calls while the window is live"
    assert_match "$(logtext)" "WAIT" "logs a WAIT heartbeat"
}

test_expired_window_pings_again() {
    write_state "$(hours_ago_boundary 6)"
    "$KW" run >/dev/null 2>&1
    assert_eq "1" "$(calls)" "expired window triggers a ping"
    assert_eq "ok" "$(state_get LAST_STATUS)" "status is ok"
}

test_rate_limited_leaves_window_untouched() {
    write_state "$(hours_ago_boundary 6)"
    local before
    before="$(state_get WINDOW_END)"
    STUB_MODE="limited" "$KW" run >/dev/null 2>&1
    assert_eq "limited" "$(state_get LAST_STATUS)" "records limited"
    assert_eq "$before" "$(state_get WINDOW_END)" "window NOT advanced on limit"
    assert_match "$(logtext)" "LIMITED" "logs the limit"
    # and it must not burn retries on a limit — that is not a transient failure
    assert_eq "1" "$(calls)" "limited is not retried in-process"
}

test_error_is_retried_then_recorded() {
    write_state "$(hours_ago_boundary 6)"
    local before
    before="$(state_get WINDOW_END)"
    STUB_MODE="error" "$KW" run >/dev/null 2>&1
    assert_eq "2" "$(calls)" "error retried up to PING_ATTEMPTS"
    assert_eq "error" "$(state_get LAST_STATUS)" "records error"
    assert_eq "$before" "$(state_get WINDOW_END)" "window NOT advanced on error"
}

# Reported from a real Windows install: an expired login was retried three
# times over 40s and buried its one-line cause in a 1200-char payload.
test_auth_failure_is_not_retried() {
    write_state "$(hours_ago_boundary 6)"
    local before
    before="$(state_get WINDOW_END)"
    STUB_MODE="auth" "$KW" run >/dev/null 2>&1
    assert_eq "1" "$(calls)" "auth failure is NOT retried - it is not transient"
    assert_eq "auth" "$(state_get LAST_STATUS)" "records auth"
    assert_eq "$before" "$(state_get WINDOW_END)" "window NOT advanced on auth failure"
    assert_match "$(logtext)" "AUTH +Failed to authenticate" "logs the readable cause, not just the blob"
}

test_auth_failure_gives_actionable_advice() {
    local out
    out="$(STUB_MODE="auth" "$KW" ping 2>&1)"
    assert_match "$out" "not authenticated" "says what went wrong"
    assert_match "$out" "OAuth session expired" "surfaces the CLI's own message"
    assert_match "$out" "/login" "tells the user how to fix it"
}

test_doctor_flags_expired_auth() {
    STUB_MODE="auth" "$KW" ping >/dev/null 2>&1
    local out
    out="$("$KW" doctor 2>&1)"
    assert_match "$out" "authentication" "doctor surfaces the auth failure"
    if "$KW" doctor >/dev/null 2>&1; then
        fail_test "doctor should exit non-zero when authentication failed"
    fi
}

test_transient_error_recovers_within_one_run() {
    write_state "$(hours_ago_boundary 6)"
    STUB_MODE="flaky" "$KW" run >/dev/null 2>&1
    assert_eq "2" "$(calls)" "second attempt made"
    assert_eq "ok" "$(state_get LAST_STATUS)" "recovers without waiting an hour"
    assert_match "$(logtext)" "RETRY" "logs the retry"
}

test_skips_ping_when_user_was_active() {
    local start
    start="$(hours_ago_boundary 6)"
    write_state "$start"
    # A transcript touched after the window boundary means the user's own
    # messages already opened the new window.
    touch "$KEEPWARM_ACTIVITY_DIR/session.jsonl"
    "$KW" run >/dev/null 2>&1
    assert_eq "0" "$(calls)" "no ping spent when already active"
    assert_eq "skipped" "$(state_get LAST_STATUS)" "records skip"
    assert_eq "$(( start + 18000 ))" "$(state_get WINDOW_START)" "window advances to the old boundary"
}

test_stale_activity_does_not_skip() {
    local start
    start="$(hours_ago_boundary 6)"
    write_state "$start"
    touch "$KEEPWARM_ACTIVITY_DIR/session.jsonl"
    # Backdate the transcript to before the boundary: not recent activity.
    touch -t "$(t_fmt "$(( start - 3600 ))" '+%Y%m%d%H%M.%S')" "$KEEPWARM_ACTIVITY_DIR/session.jsonl"
    "$KW" run >/dev/null 2>&1
    assert_eq "1" "$(calls)" "stale activity still pings"
}

test_live_lock_blocks_concurrent_run() {
    mkdir -p "$KEEPWARM_HOME/state/keepwarm.lock.d"
    printf '%s' "$$" >"$KEEPWARM_HOME/state/keepwarm.lock.d/pid"   # our own PID is alive
    "$KW" run >/dev/null 2>&1
    assert_eq "0" "$(calls)" "does not run while another instance holds the lock"
    assert_match "$(logtext)" "SKIP +another keepwarm" "logs the contention"
}

test_stale_lock_is_reclaimed() {
    mkdir -p "$KEEPWARM_HOME/state/keepwarm.lock.d"
    printf '%s' "999999" >"$KEEPWARM_HOME/state/keepwarm.lock.d/pid"  # dead PID
    "$KW" run >/dev/null 2>&1
    assert_eq "1" "$(calls)" "reclaims a lock whose owner died"
}

test_lock_released_after_run() {
    "$KW" run >/dev/null 2>&1
    if [ -d "$KEEPWARM_HOME/state/keepwarm.lock.d" ]; then
        fail_test "lock directory left behind after a normal run"
    fi
}

test_install_and_uninstall() {
    "$KW" install >/dev/null 2>&1
    assert_match "$(cat "$FAKE_CRONTAB")" "claude-keepwarm" "cron line written"
    assert_match "$(cat "$FAKE_CRONTAB")" "^2 \* \* \* \*" "fires hourly at :02"
    "$KW" install >/dev/null 2>&1     # idempotent
    assert_eq "1" "$(grep -c 'claude-keepwarm' "$FAKE_CRONTAB")" "install is idempotent"
    "$KW" uninstall >/dev/null 2>&1
    assert_eq "0" "$(grep -c 'claude-keepwarm' "$FAKE_CRONTAB")" "uninstall removes the line"
}

test_install_preserves_other_cron_entries() {
    printf '0 3 * * * /usr/bin/backup.sh\n' >"$FAKE_CRONTAB"
    "$KW" install >/dev/null 2>&1
    assert_match "$(cat "$FAKE_CRONTAB")" "backup.sh" "unrelated entry preserved on install"
    "$KW" uninstall >/dev/null 2>&1
    assert_match "$(cat "$FAKE_CRONTAB")" "backup.sh" "unrelated entry preserved on uninstall"
}

test_doctor_fails_without_cron() {
    "$KW" ping >/dev/null 2>&1
    if "$KW" doctor >/dev/null 2>&1; then
        fail_test "doctor should exit non-zero when the cron job is missing"
    fi
}

test_doctor_passes_when_healthy() {
    "$KW" install >/dev/null 2>&1
    "$KW" ping >/dev/null 2>&1
    local out
    out="$("$KW" doctor 2>&1)"
    assert_match "$out" "0 failing" "doctor reports healthy"
}

test_config_and_version_do_not_touch_state() {
    "$KW" version >/dev/null 2>&1
    "$KW" config  >/dev/null 2>&1
    assert_eq "0" "$(calls)" "read-only commands make no API calls"
}

test_unknown_command_exits_nonzero() {
    if "$KW" bogus-subcommand >/dev/null 2>&1; then
        fail_test "unknown subcommand should exit non-zero"
    fi
}

# --------------------------------------------------------------------- main --

printf 'keepwarm tests  (bash %s, %s)\n\n' "${BASH_VERSION%%(*}" "$(uname -s)"

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$t"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    # shellcheck disable=SC2059
    printf "$FAILED\n"
    exit 1
fi
