#!/usr/bin/env bash
# Pure-function cases: naming, path containment, and field parsing.
# No network, no server, no temporary state beyond a scratch dir.
#
# Run via tests/run.sh.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ------------------------------------------------------------ session naming
# Origin: sessions used to be created unnamed when --as was omitted, existing on
# the server with no way to find them. `new` now always ends up named.

section "session_derive_name"

assert_eq "explicit --as wins"            tidy       "$(session_derive_name /projects/notes tidy)"
assert_eq "basename of a plain path"      api        "$(session_derive_name /projects/api '')"
assert_eq "last segment of a deep path"   path       "$(session_derive_name /a/b/c/path '')"
assert_eq "trailing slash is stripped"    api        "$(session_derive_name /projects/api/ '')"
assert_eq "double slash is stripped"      projects   "$(session_derive_name //projects '')"
assert_eq "bare / falls back to a stamp"  "$(date -u +%Y%m%d-%H%M)" \
                                           "$(session_derive_name / '')"
assert_eq "root with trailing slash"      "$(date -u +%Y%m%d-%H%M)" \
                                           "$(session_derive_name / '')"
# An empty dir should never reach here — `new` always resolves one first. The
# fallback is a timestamp, which is the safe answer rather than an empty name.
assert_eq "an empty dir falls back to a stamp" "$(date -u +%Y%m%d-%H%M)" \
                                           "$(session_derive_name '' '')"

# ------------------------------------------------------------ root containment
# Origin: the first boundary check was `"$dir" == "$root"*`, which accepts
# /projects2 — a sibling that merely shares a string prefix.

section "under_root"

assert_rc "the root itself is inside"     0 under_root /projects /projects
assert_rc "a child is inside"             0 under_root /projects/api /projects
assert_rc "a deep child is inside"        0 under_root /projects/a/b/c /projects
assert_rc "a sibling is OUTSIDE"          1 under_root /projects2 /projects
assert_rc "a sibling prefix is OUTSIDE"   1 under_root /projects-secret /projects
assert_rc "the parent is OUTSIDE"         1 under_root / /projects
assert_rc "/etc is OUTSIDE"               1 under_root /etc /projects
assert_rc "trailing slashes are equal"    0 under_root /projects/ /projects
assert_rc "child with trailing slash"     0 under_root /projects/api/ /projects/

# Origin: macOS reports /private/var/... while you type /var/...; a pure string
# comparison called the server's own working directory outside itself.
assert_rc "the /private prefix is ignored" 0 under_root /var/folders/x /private/var/folders/x
assert_rc "and on the other side too"      0 under_root /private/var/folders/x /var/folders/x

# Origin: an empty root returned 0, so "allow" — meaning that with the server
# down, `new` offered "/" and accepted it. A containment control must fail
# CLOSED: an unverifiable boundary is not a boundary.
assert_rc "an empty root is UNVERIFIABLE"  2 under_root /anything ""
assert_rc "  and for the root itself too"   2 under_root "" ""
assert_rc "  and even for the server itself" 2 under_root /private/var ""

# ------------------------------------------------------------ field parsing
# Origin: jq @tsv emits tabs, but tab is IFS *whitespace*, so bash collapses runs
# of it. An empty model field vanished and every column after it shifted left.

section "tab-separated parsing"

parse_tsv_tab() {
  local out=(); local -a f=()
  IFS=$'\t' read -r -a f <<< "$1"
  out=("${f[@]}")
  printf '%s|' "${out[@]}"
}

parse_tsv_us() {
  local out=(); local -a f=()
  IFS=$'\x1f' read -r -a f <<< "$1"
  out=("${f[@]}")
  printf '%s|' "${out[@]}"
}

# Built through jq, the same way the tool builds them, so the two cannot drift.
ROW_TAB=$'ses_1\t/projects\t\t2026-01-01\t2026-02-02'
ROW_US=$(printf '%s' '{"id":"ses_1","model":""}' \
         | jq -r '[.id, "/projects", .model, "2026-01-01", "2026-02-02"] | join("\u001f")')

assert_eq "tab IFS collapses the empty field" "ses_1|/projects|2026-01-01|2026-02-02|" \
                                               "$(parse_tsv_tab "$ROW_TAB")"
assert_eq "0x1f IFS preserves it"             "ses_1|/projects||2026-01-01|2026-02-02|" \
                                               "$(parse_tsv_us "$ROW_US")"

# And the end-to-end version: a session record with no model must line up.
section "session record round-trip"

fresh_store
cat > "$SESSIONS_DIR/nomodel.json" <<'JSON'
{"id":"ses_x","directory":"/projects","model":"","created":"2026-01-01T00:00:00Z",
 "last_used":"2026-02-02T00:00:00Z","host":"h"}
JSON
IFS=$'\x1f' read -r _rid _rdir _rmodel _rcreated _rlast < <(
  jq -r '[.id, .directory, (.model // ""), .created, (.last_used // .created)]
         | join("")' "$SESSIONS_DIR/nomodel.json")
assert_eq "id survives the parse"       "ses_x"        "$_rid"
assert_eq "directory survives"          "/projects"    "$_rdir"
assert_eq "model stays empty, not the date" ""        "$_rmodel"
assert_eq "created does not leak into model" "2026-01-01T00:00:00Z" "$_rcreated"
assert_eq "last_used lands in its own column" "2026-02-02T00:00:00Z" "$_rlast"

# ------------------------------------------------------------ event filtering
# Origin: ask_stream consumed the server-wide SSE stream and switched on
# .type alone, so while a second session was active its deltas rendered into
# this reply, its session.execution.succeeded ended this ask early, and its
# failure was reported as this session's error. ask now drops every event
# whose data.sessionID names another session.

section "event_is_for"

assert_rc "an event for our session passes" 0 \
  event_is_for ses_a '{"type":"session.text.delta","data":{"sessionID":"ses_a","delta":"x"}}'
assert_rc "an event for another session is dropped" 1 \
  event_is_for ses_a '{"type":"session.text.delta","data":{"sessionID":"ses_b","delta":"x"}}'
assert_rc "an unaddressed event passes through" 0 \
  event_is_for ses_a '{"type":"server.connected"}'
assert_rc "a malformed payload is dropped, not fatal" 1 \
  event_is_for ses_a 'not json'

section "ask_handle_event reports what it accepted"

# The silence budget is built on this contract: ask_stream resets its timer
# only on 0, so every non-0 must mean "not activity for this session".
# Before this, heartbeats and other sessions' events reset the timer on
# every line, so a healthy-but-stuck stream kept a dead ask alive and
# ASK_SILENCE could never fire. 2 exists for server-level events: alive,
# but not activity, so a server that ever emits repeated unaddressed pings
# cannot defeat the budget either.

assert_rc "a heartbeat is skipped" 1 \
  ask_handle_event ses_a wait ': heartbeat'
assert_rc "a blank line is skipped" 1 \
  ask_handle_event ses_a wait ''
assert_rc "another session's event is skipped" 1 \
  ask_handle_event ses_a wait 'data: {"type":"session.text.delta","data":{"sessionID":"ses_b","delta":"x"}}'
assert_rc "a malformed payload is skipped" 1 \
  ask_handle_event ses_a wait 'data: not json'
assert_rc "an event for our session is accepted" 0 \
  ask_handle_event ses_a wait 'data: {"type":"session.text.delta","data":{"sessionID":"ses_a","delta":"x"}}'
assert_rc "an unaddressed event is alive, not activity" 2 \
  ask_handle_event ses_a wait 'data: {"type":"server.connected"}'

section "ask_handle_event ignores other sessions"

# Resets the state the handler updates, then runs it, capturing rendered
# output into EV_OUT. The handler must run in THIS shell: $(...) would run it
# in a subshell and its updates to started/finished/err/blocked would vanish,
# making every state assertion pass for the wrong reason.
run_event() {
  started=0; finished=0; err=""; blocked=""
  local tmpo
  tmpo=$(mktemp)
  ask_handle_event ses_a "$1" "$2" > "$tmpo" 2>/dev/null
  EV_OUT=$(cat "$tmpo")
  rm -f "$tmpo"
}

run_event live 'data: {"type":"session.text.delta","data":{"sessionID":"ses_b","delta":"other session text"}}'
assert_eq   "another session's delta does not render" "" "$EV_OUT"
assert_eq   "  and does not start our stream"         "0" "$started"

run_event wait 'data: {"type":"session.execution.succeeded","data":{"sessionID":"ses_b"}}'
assert_eq "another session finishing does not end this ask" "0" "$finished"

run_event wait 'data: {"type":"session.execution.failed","data":{"sessionID":"ses_b","error":{"message":"boom"}}}'
assert_eq "another session's failure is not ours" "" "$err"

run_event wait 'data: {"type":"session.permission.requested","data":{"sessionID":"ses_b"}}'
assert_eq "another session's prompt does not block this ask" "" "$blocked"

run_event raw 'data: {"type":"session.text.delta","data":{"sessionID":"ses_b","delta":"x"}}'
assert_eq "raw mode does not leak other sessions" "" "$EV_OUT"

section "ask_handle_event still serves our session"

run_event live 'data: {"type":"session.text.delta","data":{"sessionID":"ses_a","delta":"hello"}}'
assert_eq   "our delta renders"          "hello" "$EV_OUT"
assert_eq   "  and starts our stream"    "1" "$started"

run_event wait 'data: {"type":"session.execution.succeeded","data":{"sessionID":"ses_a"}}'
assert_eq "our completion ends the ask" "1" "$finished"

run_event wait 'data: {"type":"session.execution.failed","data":{"sessionID":"ses_a","error":{"message":"boom"}}}'
assert_eq "our failure is recorded" "boom" "$err"

section "ask_handle_event marks the stream alive"

# A server-level event must still set started: the connect event is often
# the only event a dead stream ever sends, and started is what keeps the
# tail from reporting "no events received" for a stream that did connect.
# It must not, however, count as a completion.
run_event wait 'data: {"type":"server.connected"}'
assert_eq "an unaddressed event sets started" "1" "$started"
assert_eq "  but does not finish the ask" "0" "$finished"

summary