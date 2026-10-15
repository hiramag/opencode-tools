#!/usr/bin/env bash
# The session library: naming, dual identity, derived "current", caching.
# No network — records are written straight into a scratch store.
#
# Run via tests/run.sh.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ------------------------------------------------------------- default store
# Origin: SESSION_FILE made the library land in /tmp/opencode-sid.d, where
# macOS's daily cleaner removes it — and reading a file does not update atime on
# this filesystem, so even a session in daily use was eligible for deletion.

section "sessions_dir"

unset SESSIONS_DIR
assert_eq "defaults under \$HOME" "$HOME/.opencode/sessions" "$(sessions_dir)"

SESSIONS_DIR=/somewhere/else
assert_eq "SESSIONS_DIR overrides"      "/somewhere/else" "$(sessions_dir)"
unset SESSIONS_DIR

# ------------------------------------------------------------- dual identity
# Origin: `ls` showed names while sessions were addressed by id, so the two views
# could disagree about which session was which.

section "session_file accepts a name or an id"

fresh_store
put_session probe     ses_probe123  /projects
put_session api        ses_api456     /projects/api
put_session tidy      ses_tidy789   /projects/notes

assert_eq "by name"        "api" "$(basename "$(session_file api)" .json)"
assert_eq "by session id"  "api" "$(basename "$(session_file ses_api456)" .json)"
assert_rc "unknown name is a miss"   1 session_file nosuch
assert_rc "unknown id is a miss"     1 session_file ses_nosuch

section "session_name_for"

assert_eq "resolves an id to a name"  "api"    "$(session_name_for ses_api456)"
assert_eq "an untracked id stays itself" "ses_zzz" "$(session_name_for ses_zzz)"

# ------------------------------------------------------- derived "current"
# Origin: there were two stores — a /tmp pointer and a JSON library — which could
# disagree. "Current" is now derived from the newest last_used.

section "sid_of derives the current session"

fresh_store
put_session older  ses_older  /projects "" 2026-01-01T00:00:00Z 2026-03-01T00:00:00Z
put_session newer  ses_newer  /projects/api "" 2026-01-02T00:00:00Z 2026-09-09T00:00:00Z
assert_eq "newest last_used wins" "ses_newer" "$(sid_of)"

put_session oldest ses_oldest /projects "" 2025-01-01T00:00:00Z 2020-01-01T00:00:00Z
assert_eq "an older entry does not steal it" "ses_newer" "$(sid_of)"

# Touching one makes it current — this is what `use` does.
session_touch "$SESSIONS_DIR/older.json"
assert_eq "after touching, it becomes current" "ses_older" "$(sid_of)"

section "sid_of with an empty store"

fresh_store
# sid_of ends in die, which exits — so it has to run in a subshell or it takes
# the whole suite down with it.
assert_rc "no sessions is an error, not empty" 1 bash -c 'source "$TOOL"; SESSIONS_DIR="$1"; sid_of' _ "$SESSIONS_DIR"

section "session_prev_name"

fresh_store
put_session a ses_a /projects "" 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z
put_session b ses_b /projects "" 2026-01-01T00:00:00Z 2026-02-02T00:00:00Z
put_session c ses_c /projects "" 2026-01-01T00:00:00Z 2026-03-03T00:00:00Z
assert_eq "the one before the current" "b" "$(session_prev_name)"

fresh_store
put_session solo ses_only /projects "" 2026-01-01T00:00:00Z 2026-01-01T00:00:00Z
assert_rc "a single session has no previous" 1 session_prev_name

# ------------------------------------------------------------------- caching
# Origin: `ls` asked the server for a message count once per session, making it
# O(n) round trips just to print a list.

section "caching"

fresh_store
put_session a ses_a /projects
assert_eq "no cached count shows as ?" "?" "$(jq -r '.msgs // "?"' "$SESSIONS_DIR/a.json")"

session_cache_msgs "$SESSIONS_DIR/a.json" 42
assert_eq "caching writes the count"  "42" "$(jq -r .msgs "$SESSIONS_DIR/a.json")"

session_cache_msgs "$SESSIONS_DIR/a.json" "?"
assert_eq "an unknown count is not cached" "42" "$(jq -r .msgs "$SESSIONS_DIR/a.json")"
session_cache_msgs "$SESSIONS_DIR/a.json" ""
assert_eq "an empty count is not cached"    "42" "$(jq -r .msgs "$SESSIONS_DIR/a.json")"

assert_eq "a record without a model yields empty" "" \
          "$(jq -r '.model // ""' "$SESSIONS_DIR/a.json")"
session_cache_model "$SESSIONS_DIR/a.json" "opencode/space-bunny-free"
assert_eq "the model is cached" "opencode/space-bunny-free" \
          "$(jq -r .model "$SESSIONS_DIR/a.json")"

# The record must stay valid JSON after every rewrite — a truncated file would
# silently take the whole listing down.
assert_rc "the record is still valid JSON" 0 jq -e . "$SESSIONS_DIR/a.json"

# Origin: jq's `length` of null is 0, so an error body read as "no messages" and
# was cached — overwriting a good count with a fabricated zero. An error must
# stay unknown.
section "a failed lookup is not zero"

have_error_is_not_zero() {
  local r=$1
  if printf '%s' "$r" | jq -e '._tag? // empty' >/dev/null 2>&1; then printf '?'; return 0; fi
  printf '%s' "$r" | jq -r '(if type=="array" then . else .data end) | length' 2>/dev/null || printf '?'
}

assert_eq "a deleted session stays unknown" "?" \
  "$(have_error_is_not_zero '{"_tag":"SessionNotFoundError","message":"..."}')"
assert_eq "a 401 stays unknown" "?" \
  "$(have_error_is_not_zero '{"_tag":"UnauthorizedError"}')"
assert_eq "an empty array is a real zero" "0" \
  "$(have_error_is_not_zero '{"data":[]}')"
assert_eq "two messages is a real two"   "2" \
  "$(have_error_is_not_zero '{"data":[{},{}]}')"
assert_eq "other fields survive caching" "/projects" \
          "$(jq -r .directory "$SESSIONS_DIR/a.json")"
assert_eq "  and the id too" "ses_a" "$(jq -r .id "$SESSIONS_DIR/a.json")"

# ------------------------------------------------------------ bulk removal
# Origin: `rm` read only $1, so `rm a b c` removed a and silently ignored b and
# c — and stopped at the first name that did not exist.

section "session_rm handles every argument"

fresh_store
put_session a ses_a /projects
put_session b ses_b /projects
put_session c ses_c /projects
session_rm a b c > /dev/null 2>&1
assert_eq "all three removed" "0" "$(ls "$SESSIONS_DIR" | wc -l | tr -d ' ')"

fresh_store
put_session a ses_a /projects
put_session b ses_b /projects
session_rm a nosuch b > /dev/null 2>&1; rc=$?
assert_rc "a bad name makes it non-zero" 1 test "$rc" -eq 0
assert_eq "  but the good ones still go" "0" "$(ls "$SESSIONS_DIR" | wc -l | tr -d ' ')"

fresh_store
# in a subshell: session_rm with no args ends in die, which exits
assert_rc "no arguments is an error" 1 bash -c 'source "$TOOL"; SESSIONS_DIR="$1"; session_rm' _ "$SESSIONS_DIR"

# -------------------------------------------- the dispatcher, not the function
# All four fixed defects lived in the dispatcher's argument handling, not in the
# function it calls. `session_rm` already looped over "$@" and its unit test above
# passed the whole time, while `rm a b c` forgot only "a" — because the dispatcher
# passed "${2:-}". A test that calls the function directly is blind to this class of
# bug. These run the script as a subprocess.
#
# The host is deliberately unreachable. `rm` never calls the server, and `delete`
# reaching the server call at all is the signal that -y was honoured.

section "rm dispatch passes every name through"

fresh_store
put_session a ses_a /projects
put_session b ses_b /projects
put_session c ses_c /projects
out=$(OPENCODE_HOST=http://test.invalid:4096 OPENCODE_PASS=x \
      SESSIONS_DIR="$SESSIONS_DIR" "$TOOL" rm a b c 2>&1)
assert_eq  "all three removed via the dispatcher" "0" \
           "$(ls "$SESSIONS_DIR" | wc -l | tr -d ' ')"
assert_contains "  each was reported, not just the first" 'forgot "c"' "$out"
assert_contains "  and the first, too"                'forgot "a"' "$out"

section "rm with no names is a usage error, not an empty name"

out=$(OPENCODE_HOST=http://test.invalid:4096 OPENCODE_PASS=x \
      SESSIONS_DIR="$SESSIONS_DIR" "$TOOL" rm 2>&1)
assert_contains "it explains itself" "usage:" "$out"
assert_not_contains "  no bogus empty-name lookup" 'matching ""' "$out"

section "delete dispatch honours -y wherever it appears"

fresh_store
put_session a ses_a /projects
# -y was read from $3 only, which for --session-id holds the id, so the flag was
# ignored and the prompt appeared anyway. Reaching the server call proves otherwise.
out=$(OPENCODE_HOST=http://test.invalid:1 OPENCODE_PASS=x \
      SESSIONS_DIR="$SESSIONS_DIR" "$TOOL" delete --session-id ses_a -y </dev/null 2>&1)
assert_contains     "  -y reaches the server for --session-id" "local name left in place" "$out"
assert_not_contains "  and never asks to type it back"        "Type it to confirm" "$out"

out=$(OPENCODE_HOST=http://test.invalid:1 OPENCODE_PASS=x \
      SESSIONS_DIR="$SESSIONS_DIR" "$TOOL" delete a -y </dev/null 2>&1)
assert_contains     "  -y reaches the server by name too"    "local name left in place" "$out"
assert_not_contains "  still no prompt"                       "Type it to confirm" "$out"

section "delete without -y still confirms"

out=$(OPENCODE_HOST=http://test.invalid:1 OPENCODE_PASS=x \
      SESSIONS_DIR="$SESSIONS_DIR" "$TOOL" delete a </dev/null 2>&1)
assert_contains     "it asks for the name back" "Type it to confirm" "$out"
assert_not_contains "  and a closed stdin aborts" "local name left in place" "$out"

section "raw dispatch parses its own flags"

# The case tested ${1:-} without shifting, so $1 was still "raw" and -i could
# never match. An unrecognised flag is now an error instead of a silent fall
# through to a plain stream — which is what proves the argument is being read.
out=$(OPENCODE_HOST=http://test.invalid:4096 OPENCODE_PASS=x "$TOOL" raw --bogus 2>&1 </dev/null)
assert_contains "an unknown flag is rejected" "unknown option for raw" "$out"

summary