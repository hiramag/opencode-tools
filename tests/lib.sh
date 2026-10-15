#!/usr/bin/env bash
# Shared test helpers. Sourced by each test_*.sh — never run directly.
#
# Cases here are all regressions: every one of them corresponds to a bug that
# actually shipped, was caught by a test, or was nearly shipped because a test
# was vacuous. See README.md for the origin of each.

set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_CASE=""

# The tool under test. Resolved relative to this file so the suite runs from
# anywhere, and so a stale copy on $PATH can never be tested by mistake.
: "${TOOL:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/opencode-bash-tool.sh"}"
[[ -f "$TOOL" ]] || { echo "cannot find the tool at $TOOL"; exit 2; }

# shellcheck source=/dev/null
source "$TOOL"
export TOOL

# The tool sets `set -e` for its own use. Tests must NOT inherit that: a test
# asserts on failures, so the first failing command would abort the suite. This
# cost one confusing afternoon — a suite silently stopped mid-way.
set +e
set -uo pipefail

# A session store that is not the real one. Every test gets its own, so tests
# cannot see each other's files or touch ~/.opencode/sessions.
fresh_store() {
  SESSIONS_DIR=$(mktemp -d)
  export SESSIONS_DIR
  STORES+=("$SESSIONS_DIR")
}

STORES=()
cleanup_stores() {
  local d
  for d in "${STORES[@]:-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf "$d"; done
  STORES=()
}
# Preserve the exit status across the trap. Without this, a suite that dies part
# way through runs cleanup, cleanup succeeds, and the crash is reported as PASS —
# which is worse than no test at all, because it manufactures confidence.
trap 'rc=$?; cleanup_stores; exit $rc' EXIT

# Write a session record straight into the store, bypassing the network.
put_session() {
  local name=$1 id=$2 dir=$3 model=${4:-} created=${5:-2026-01-01T00:00:00Z} \
        last=${6:-2026-01-01T00:00:00Z} host=${7:-http://test.invalid:4096}
  mkdir -p "$SESSIONS_DIR"
  jq -nc --arg id "$id" --arg d "$dir" --arg m "$model" --arg c "$created" \
         --arg l "$last" --arg h "$host" \
    '{id:$id, directory:$d, model:$m, created:$c, last_used:$l, host:$h}' \
    > "$SESSIONS_DIR/$name.json"
}

# ---------------------------------------------------------------- assertions

ok()   { TESTS_RUN=$((TESTS_RUN + 1)); printf '    ok   %s\n' "$1"; }
bad()  {
  TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '    FAIL %s\n' "$1"
  [[ $# -gt 1 ]] && printf '         expected: %s\n' "$2"
  [[ $# -gt 2 ]] && printf '         actual:   %s\n' "$3"
  return 0
}

# assert_eq <label> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "[$2]" "[$3]"; fi
}

# assert_contains <label> <needle> <haystack>
assert_contains() {
  if [[ "$3" == *"$2"* ]]; then ok "$1"; else bad "$1" "to contain [$2]" "[$3]"; fi
}

# assert_not_contains <label> <needle> <haystack>
assert_not_contains() {
  if [[ "$3" != *"$2"* ]]; then ok "$1"; else bad "$1" "not to contain [$2]" "[$3]"; fi
}

# assert_rc <label> <expected-rc> <command...>
# Runs the command, tolerating a non-zero result under set -e.
assert_rc() {
  local label=$1 want=$2; shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$label" "$want" "$rc"
}

section() { CURRENT_CASE=$1; printf '  %s\n' "$1"; }

summary() {
  printf '\n  %d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
  (( TESTS_FAILED == 0 ))
}