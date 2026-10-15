#!/usr/bin/env bash 
# opencode-bash-tool.sh — test and drive an OpenCode server's event stream over SSE.
#
# USAGE
# Usage: opencode-bash-tool.sh <command> [options] [arguments]
#
# Run `./opencode-bash-tool.sh --version` to confirm which copy you are executing.
# Behaviour has changed under a fixed command name before; a stale copy in a
# shell history or a second checkout produces output that looks like a fresh bug.
#
# Commands:
#   --version                            version, path and line count of THIS copy
#   info                                server info and connectivity check
#   new [dir] [model] [provider] [--as name]
#                                          create a session and save its ID
#                                          --as also registers it by name
#   ls                                    list named sessions
#   locations                             show the active session's directory and
#                                         what the server has loaded
#   dirs [path]                           browse the server's filesystem
#                                         (default: the server's own working
#                                          directory — pass a path to override)
#   ping                                 check reachability and auth, unambiguously
#   use <name>                            switch to a named session
#   rm <name> [name ...]                  forget named sessions (they stay on the server)
#   delete <name>                         delete a named session, on the server too
#   delete --session-id <id>              same, for an unnamed session
#   watch                               stream events for the saved session
#   raw [-i]                            unfiltered SSE stream, no session needed
#   ask [--live|--wait|--raw] "text"
#                                          send a prompt, show the reply here
#                                          --live    stream the reply (default)
#                                          --wait    print the reply once complete
#                                          --raw     print raw SSE frames
#   model <id> [provider]               switch the saved session's model
#   models [filter]                     list available models
#   history                             last 3 messages of the saved session
#   wait                                block until the session is idle
#   selftest                            end-to-end checks, local throwaway server
#
# ask options:
#   --live    stream the reply as it writes (default)
#   --wait    print the reply once complete
#   --raw     print raw SSE frames instead of the rendered reply
#
# Configuration is required: export OPENCODE_HOST and OPENCODE_PASS, or
# set them at the top of this script. There are no fallbacks — a missing value is
# a hard error, never a silent default.
#
# OPENCODE_HOST must include the scheme and the port, or curl tries port 80 and hangs:
#   OPENCODE_HOST=http://<server-host>:4096      correct
#   OPENCODE_HOST=<server-host>:4096             wrong: no scheme
#   OPENCODE_HOST=<server-host>                  wrong: no scheme and no port
# END USAGE
#
# To set values in place instead, export them before running, e.g.
#   OPENCODE_HOST=http://<server-host>:4096 OPENCODE_PASS=your-password ./opencode-bash-tool.sh info

set -euo pipefail

# Bump when behaviour changes under a command name that already existed.
SCRIPT_VERSION="2026.10.15-21"
#   -5  new: check the path against the server instead of scanning its parent,
#           so mount points are not reported missing; distinguish "absent" from
#           "could not tell" so a transport failure is never called a missing dir
#   -4  dirs: fall back to /api/fs/list with no path instead of the cold-empty
#            /api/debug/location, and say so when the path came from the server
#   -3  ping: distinguish 401 from 000 from an unexpected status
#   -2  ping: stop appending a second 000 when curl already printed one

# Only commands that actually issue HTTP requests need credentials.
need_http() {
  case "${1:-}" in
    ls|rm|use|"") return 1 ;;
    selftest) return 1 ;;
    *) return 0 ;;
  esac
}
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# End-to-end checks against a throwaway server on localhost.
# Never touches OPENCODE_HOST/OPENCODE_PASS from the environment; it exports its own.
# The key assertion is that the prompt text arrives at the server intact, which
# is the regression that shipped once before (the script sent the literal "ask").
# Stop the selftest server and confirm it actually died.
#
# `kill` alone is not enough: the process may take time to exit or ignore SIGTERM,
# and a leaked server on the selftest port outlives the run and confuses the next
# one. So: SIGTERM, wait, SIGKILL, wait, then verify by pid AND by port.
#   $1 pid   $2 port
# Echoes nothing. Returns 0 if the server is gone, 1 if it leaked.
stop_server() {
  local pid=$1 port=$2 waited=0
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && ((waited < 50)); do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    sleep 0.3
  fi
  wait "$pid" 2>/dev/null || true
  if kill -0 "$pid" 2>/dev/null; then
    printf 'LEAK: test server pid %s survived cleanup - kill it manually\n' "$pid" >&2
    return 1
  fi
  if curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$port/api/info" 2>/dev/null; then
    printf 'LEAK: something is still listening on port %s\n' "$port" >&2
    return 1
  fi
  return 0
}

selftest() {
  local port=${SELFTEST_PORT:-4997} tmpd pid probe i ok=0 failures=0 mid
  local a

  command -v opencode >/dev/null || { echo "FAIL: opencode not on PATH" >&2; return 1; }
  tmpd=$(mktemp -d)
  probe="selftest-probe-$$-$(date +%s)"
  a=$(printf 'opencode:selftest' | base64 | tr -d '\n')

  # Refuse to run if the port is already taken. Otherwise the server we start
  # fails to bind, the readiness check is satisfied by whatever is already
  # there, and every check silently runs against the wrong process.
  if curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$port/api/info" 2>/dev/null; then
    printf 'FAIL: port %s is already in use - a previous selftest server leaked.\n' "$port" >&2
    printf '      find it with: ps -eo pid,args | grep "[o]pencode serve --hostname"\n' >&2
    printf '      or pick another port with: SELFTEST_PORT=%s\n' "$((port + 1))" >&2
    return 1
  fi

  # OPENCODE_DB isolates the database so a test run cannot leave sessions and
  # projects in the real one. HOME is deliberately left alone: pointing it at a
  # temp dir also hides provider credentials, which makes the models and
  # model-switch checks below pass vacuously.
  #
  # Run from $tmpd so the server's WorkingDirectory — the hard root for
  # sessions — is the throwaway workspace. Started from here instead, every
  # `new $tmpd` would be refused as outside the root. `exec` so $pid is the
  # server itself and stop_server can signal it directly.
  ( cd "$tmpd" && OPENCODE_PASSWORD=selftest OPENCODE_DB="$tmpd/selftest.db" \
    exec opencode serve --hostname 127.0.0.1 --port "$port" \
    > "$tmpd/server.log" 2>&1 < /dev/null ) &
  pid=$!

  export OPENCODE_HOST="http://127.0.0.1:$port" OPENCODE_PASS=selftest \
         SESSIONS_DIR="$tmpd/sessions"

  # Belt and braces: confirm the test is aimed at the throwaway server before
  # sending anything. If this ever fails, abort rather than touch a real one.
  if [[ "$OPENCODE_HOST" != "http://127.0.0.1:$port" \
        || "$SESSIONS_DIR" != "$tmpd/sessions" ]]; then
    echo "FAIL: selftest is not pointed at its throwaway server" >&2
    stop_server "$pid" "$port" || true
    rm -rf "$tmpd" || true
    return 1
  fi

  for ((i = 0; i < 150; i++)); do
    if curl -sS --max-time 2 -o /dev/null -H "Authorization: Basic $a" \
         "$OPENCODE_HOST/api/info" 2>/dev/null; then
      ok=1; break
    fi
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done

  if ((ok == 0)); then
    echo "FAIL: test server never became ready on port $port" >&2
    sed -n '1,20p' "$tmpd/server.log" >&2
    stop_server "$pid" "$port" || true
    rm -rf "$tmpd" || true
    return 1
  fi

  # Confirm the server answering is the one we started, not a squatter that
  # happened to answer the readiness probe.
  got=$(curl -sS --max-time 5 -H "Authorization: Basic $a" \
    "http://127.0.0.1:$port/api/info" | jq -r '.pid // empty' 2>/dev/null)
  if [[ -n "$got" && "$got" != "$pid" ]]; then
    printf 'FAIL: port %s is answering with pid %s, but we started %s\n' \
      "$port" "$got" "$pid" >&2
    stop_server "$pid" "$port" || true
    rm -rf "$tmpd" || true
    return 1
  fi

  echo "test server ready on $OPENCODE_HOST"
  printf '  host:       %s   (throwaway, not your server)\n' "$OPENCODE_HOST"
  printf '  workspace:  %s   (temporary, removed on exit)\n' "$tmpd"
  printf '  probe:      %s\n' "$probe"
  echo

  check() {
    local name=$1; shift
    printf '  %-26s' "$name"
    if "$@"; then echo "ok"; else echo "FAIL" >&2; failures=$((failures + 1)); fi
  }

  t_info() { "$0" info >/dev/null 2>&1; }
  # No pointer file any more: `new` succeeding means a record landed in the
  # library. Checking a pointer here would pass even if the session were lost.
  t_new()  { "$0" new "$tmpd" >/dev/null 2>&1 && ls "$tmpd"/sessions/*.json >/dev/null 2>&1; }
  t_models() { "$0" models >/dev/null 2>&1; }
  t_model() {
    mid=$("$0" models 2>/dev/null | head -1 | cut -f1)
    [[ -n "$mid" ]] && "$0" model "$mid" >/dev/null 2>&1
  }
  t_prompt() {
    "$0" ask --wait "$probe" >/dev/null 2>&1 || true
    # `history` already unwraps .data and slices, so its output is a bare array.
    "$0" history 2>/dev/null \
      | jq -e --arg p "$probe" '.[]? | select(.type=="user" and .text==$p)' \
      >/dev/null 2>&1
  }

  # Regression, unquoted on purpose. `text=${1:?...}` took only the first word and
  # discarded the rest with no warning, so `ask --wait how are you` asked "how".
  # $probe has no spaces, so the check above could never have caught that.
  t_prompt_unquoted() {
    "$0" ask --wait selftest does this arrive whole >/dev/null 2>&1 || true
    "$0" history 2>/dev/null \
      | jq -e '.[]? | select(.type=="user" and .text=="selftest does this arrive whole")' \
      >/dev/null 2>&1
  }

  check "info"              t_info
  check "new"               t_new
  check "models"            t_models
  check "model switch"      t_model
  check "prompt round-trip" t_prompt
  check "unquoted prompt"   t_prompt_unquoted

  echo
  used=$("$0" ls 2>/dev/null | awk 'NR==2{print $2}')
  printf '  session used: %s\n' "${used:-(none created)}"
  printf '  host:        %s\n' "$OPENCODE_HOST"

  # Cleanup must never abort the script. Killing the server can surface from
  # `wait` as a signal status, which `set -e` would treat as a fatal failure.
  if ! stop_server "$pid" "$port"; then
    failures=$((failures + 1))
  fi
  rm -rf "$tmpd" || true

  echo
  if ((failures)); then
    echo "$failures check(s) failed"
    return 1
  fi
  echo "all checks passed"
}

# Delete a session on the server. Echoes nothing.
#   $1 session id
session_delete_remote() {
  local sid=$1 resp code body
  resp=$(curl -sS --http1.1 -w '\n%{http_code}' -X DELETE \
    -H "Authorization: Basic $AUTH" "$OPENCODE_HOST/api/session/$sid")
  code=${resp##*$'\n'}
  body=${resp%$'\n'*}
  if [[ "$code" == 2* ]]; then
    return 0
  fi
  printf 'server refused the delete (HTTP %s)\n' "$code" >&2
  [[ -n "$body" ]] && printf 'server said: %s\n' "$body" >&2
  return 1
}

usage() {
  sed -n '/^# USAGE$/,/^# END USAGE$/p' "$0" | sed '1d;$d;s/^# \{0,1\}//'
}

for dep in curl jq base64; do
  command -v "$dep" >/dev/null || die "missing dependency: $dep"
done
AUTH=$(printf 'opencode:%s' "${OPENCODE_PASS-}" | base64 | tr -d '\n')
api() { curl -sS --http1.1 -H "Authorization: Basic $AUTH" "$OPENCODE_HOST$1"; }

# POST JSON and split the response into "<body>\n<status>" so callers can
# report what the server actually said instead of a generic guess.
post_json() {
  curl -sS --http1.1 -w '\n%{http_code}' -X POST \
    -H "Authorization: Basic $AUTH" \
    -H 'Content-Type: application/json' \
    -d "$2" \
    "$OPENCODE_HOST$1" || true
}

# The active session is DERIVED from the library — the newest last_used — rather
# than stored in a pointer file. One store, so the two views cannot disagree and
# nothing lives in /tmp to be swept.
sid_of() {
  local f best="" bl="" lu
  shopt -s nullglob
  for f in "$(sessions_dir)"/*.json; do
    [[ -e "$f" ]] || continue
    lu=$(jq -r '.last_used // .created // ""' "$f")
    [[ -n "$lu" && "$lu" > "$bl" ]] && { bl=$lu; best=$f; }
  done
  shopt -u nullglob
  [[ -n "$best" ]] || die "no sessions tracked yet - run: $0 new <dir>"
  jq -r '.id' "$best"
}

# Named session store. One JSON file per named session, in $HOME by default.
#   SESSIONS_DIR   override the location
sessions_dir() {
  if [[ -n "${SESSIONS_DIR:-}" ]]; then printf '%s' "$SESSIONS_DIR"
  else printf '%s' "$HOME/.opencode/sessions"
  fi
}

# Accept a name OR a session id. Prints the path of the matching file.
session_file() {
  local key=$1 f
  f="$(sessions_dir)/$key.json"
  [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  shopt -s nullglob
  for f in "$(sessions_dir)"/*.json; do
    [[ -e "$f" ]] || continue
    [[ "$(jq -r '.id // ""' "$f")" == "$key" ]] && { printf '%s' "$f"; return 0; }
  done
  shopt -u nullglob
  return 1
}

# Name for a session id, falling back to the bare id when it is not tracked.
session_name_for() {
  local f
  f=$(session_file "$1") && { basename "$f" .json; return 0; }
  printf '%s' "$1"
}

session_touch() {
  local f=$1
  jq --arg u "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_used = $u' "$f" > "$f.t" \
    && mv "$f.t" "$f"
}

# Name for a new session: the --as value, else the directory's last segment,
# else a timestamp when there is no segment (a bare "/").
session_derive_name() {
  local dir=$1 want=$2 base
  if [[ -n "$want" ]]; then printf '%s' "$want"; return 0; fi
  base=${dir%/}
  base=${base##*/}
  [[ -n "$base" ]] || base=$(date -u +%Y%m%d-%H%M)
  printf '%s' "$base"
}

session_save() {
  local name=$1 sid=$2 dir=$3 model=$4 sdir
  [[ -n "$name" ]] || return 0
  case "$name" in */*|.|..|"") die "invalid session name: $name" ;; esac
  sdir=$(sessions_dir)
  mkdir -p "$sdir"
  jq -nc --arg id "$sid" --arg d "$dir" --arg m "$model" --arg h "$OPENCODE_HOST" \
         --arg c "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id:$id, directory:$d, model:$m, created:$c, last_used:$c, host:$h}' \
    > "$sdir/$name.json"
  printf 'saved as "%s"\n' "$name"
}

# The entry used before the current one: second-newest last_used.
session_prev_name() {
  local f; local -a lines=()
  shopt -s nullglob
  for f in "$(sessions_dir)"/*.json; do
    [[ -e "$f" ]] || continue
    lines+=("$(jq -r '.last_used // .created // ""' "$f")	$(basename "$f" .json)")
  done
  shopt -u nullglob
  (( ${#lines[@]} < 2 )) && return 1
  printf '%s\n' "${lines[@]}" | sort -r | sed -n '2p' | cut -f2
}

session_missing() {
  local key=$1 names="" f
  shopt -s nullglob
  for f in "$(sessions_dir)"/*.json; do
    [[ -e "$f" ]] && names="$names $(basename "$f" .json)"
  done
  shopt -u nullglob
  printf 'no session matching "%s"\n' "$key" >&2
  [[ -n "$names" ]] && printf '  available:%s\n' "$names" >&2
  return 1
}

session_use() {
  local key=${1:?usage: $0 use <name|session-id|->} f name h
  if [[ "$key" == "-" ]]; then
    key=$(session_prev_name) || die "no previous session - only one is tracked"
  fi
  f=$(session_file "$key") || { session_missing "$key"; return 1; }
  name=$(basename "$f" .json)
  h=$(jq -r '.host // ""' "$f")
  # A name is local; the session is not. Pointing at another server should say so.
  [[ -n "$h" && "$h" != "$OPENCODE_HOST" ]] \
    && printf 'note: "%s" is on %s, not %s\n' "$name" "$h" "$OPENCODE_HOST" >&2
  session_touch "$f"
  printf 'now using "%s"  %s\n' "$name" "$(jq -r .id "$f")"
}

# Store a message count alongside the session so ls need not ask the server.
session_cache_msgs() {
  local f=$1 n=$2
  # Only a real count may overwrite. "?" means we could not tell, and
  # overwriting a good value with "could not tell" destroys information.
  [[ "$n" == "?" || -z "$n" ]] && return 0
  jq --argjson n "$n" '.msgs = $n' "$f" > "$f.t" && mv "$f.t" "$f"
}

# The model a session actually runs, from the server. null until one has been
# chosen, which means "inherits whatever the server defaults to".
session_model() {
  local r
  r=$(api "/api/session/$1" 2>/dev/null) || { printf '?'; return 0; }
  # Same distinction as msg_count: a failed lookup must not read as "inherits".
  if printf '%s' "$r" | jq -e '._tag? // empty' >/dev/null 2>&1; then
    printf '?'; return 0
  fi
  printf '%s' "$r" | jq -r '.data.model? // empty
    | if . == null then "" else (.providerID + "/" + .id) end' 2>/dev/null || printf '?'
}

# The server's configured default model. Fetched ONCE per ls, not per session:
# a session with no model of its own inherits this.
server_default_model() {
  local r
  r=$(api /api/model/default 2>/dev/null) || { printf '?'; return 0; }
  printf '%s' "$r" | jq -r '.data
    | select(type == "object")
    | .providerID + "/" + .id' 2>/dev/null || printf '?'
}

session_cache_model() {
  local f=$1 m=$2
  # "?" means we could not tell. Writing it would be worse than not writing at
  # all: the next plain `ls` reads the record back and displays the question mark
  # as though it were a model. Skip it, exactly as session_cache_msgs does.
  if [[ "$m" == "?" ]]; then return 0; fi
  if [[ -n "$m" ]]; then
    jq --arg m "$m" '.model = $m' "$f" > "$f.t" && mv "$f.t" "$f"
  else
    # Empty could mean "genuinely inherits the default" or "could not reach
    # the server". Distinguish: only clear when the server actually said so.
    if api "/api/session/$(jq -r .id "$f")" 2>/dev/null \
         | jq -e '(.data? | type) == "object" and ((.data.model? | type) == "null")' >/dev/null 2>&1; then
      jq --arg m "" '.model = $m' "$f" > "$f.t" && mv "$f.t" "$f"
    fi
  fi
}

msg_count() {
  local r
  r=$(api "/api/session/$1/message" 2>/dev/null) || { printf '?'; return 0; }
  # An error body is NOT zero messages. jq's `length` of null is 0, so without
  # this an error was cached as "no messages" — indistinguishable from a real
  # answer, and it overwrote good data on every failed refresh.
  if printf '%s' "$r" | jq -e '._tag? // empty' >/dev/null 2>&1; then
    printf '?'; return 0
  fi
  printf '%s' "$r" | jq -r '(if type=="array" then . else .data end) | length' 2>/dev/null \
    || printf '?'
}

session_ls() {
  local pattern="" refresh=0 a
  for a in "$@"; do
    case "$a" in
      --refresh) refresh=1 ;;
      -*) printf 'unknown option for ls: %s\n' "$a" >&2; return 1 ;;
      *) pattern=$a ;;
    esac
  done

  local f n i d m c lu msgs cur="" bl="" mark shown=0
  local -a files
  mkdir -p "$(sessions_dir)"
  shopt -s nullglob
  files=("$(sessions_dir)"/*.json)
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    printf 'no sessions yet - create one with: %s new <dir>\n' "$0"
    return 0
  fi

  for f in "${files[@]}"; do
    n=$(basename "$f" .json)
    # glob match, same rules as the shell: ls 'ha*', ls 'test'
    [[ -n "$pattern" ]] && [[ "$n" != $pattern* ]] && continue
    shown=$((shown + 1))
    lu=$(jq -r '.last_used // .created // ""' "$f")
    [[ "$lu" > "$bl" ]] && { bl=$lu; cur=$f; }
  done

  if (( shown == 0 )); then
    printf 'no session matching "%s"\n' "$pattern" >&2
    printf '  available:%s\n' "$(printf '%s\n' "${files[@]##*/}" | sed 's/\.json$//' | tr '\n' ' ')" >&2
    return 1
  fi

  local dflt
  dflt=$(server_default_model)

  printf '%-14s %-38s %-22s %4s  %-28s %s\n' NAME ID DIRECTORY MSGS MODEL LAST_USED
  for f in "${files[@]}"; do
    n=$(basename "$f" .json)
    [[ -n "$pattern" ]] && [[ "$n" != $pattern* ]] && continue

    # \x1f, NOT a tab. Tab is IFS whitespace, so bash collapses runs of it and an
    # empty field — an unset model — vanishes, shifting every later column left.
    IFS=$'\x1f' read -r i d m c lu < <(
      jq -r '[.id, .directory, (.model // ""), .created, (.last_used // .created)]
             | join("\u001f")' "$f")

    if (( refresh )); then
      msgs=$(msg_count "$i")
      m=$(session_model "$i")
      session_cache_msgs "$f" "$msgs"
      session_cache_model "$f" "$m"
    else
      # Cached. Asking the server once per session made ls O(n) round trips.
      msgs=$(jq -r '.msgs // "?"' "$f")
      m=$(jq -r '.model // ""' "$f")
    fi

    mark=" "
    [[ "$f" == "$cur" ]] && mark="*"
    # Empty model means the session has none of its own — show what it inherits.
    # If the server's default could not be fetched, say so plainly: "inherits ?"
    # reads like a model whose name is a question mark.
    local shown_model
    if [[ "$m" == "?" ]]; then
      m=""          # a stale "?" is not a model; treat it as unknown
    fi
    if [[ -n "$m" ]]; then
      shown_model=$m
    elif [[ "$dflt" == "?" ]]; then
      shown_model="inherits (default unknown)"
    else
      shown_model="inherits $dflt"
    fi
    printf '%-14s %-38s %-22s %4s  %-28s %s %s\n' \
      "$n" "${i:--}" "${d:--}" "${msgs:--}" "$shown_model" "${lu:0:16}" "$mark"
  done
  printf '\n  * current.  use <name> to switch, use - for the previous one.\n'
  (( refresh )) || printf '  MSGS is cached; ls --refresh asks the server for exact counts.\n'
}
# Takes one or more names/ids. Every argument is used or reported — silently
# ignoring extras is the same "swallow the failure" pattern this script avoids
# everywhere else, and it made a five-name command look like it had worked.
session_rm() {
  local key f name rc=0
  (($#)) || die "usage: $0 rm <name|session-id> [name ...]"
  for key in "$@"; do
    if f=$(session_file "$key" 2>/dev/null); then
      name=$(basename "$f" .json)
      rm -f "$f"
      printf 'forgot "%s" - the session still exists on the server\n' "$name"
    else
      session_missing "$key" || true
      rc=1
    fi
  done
  return $rc
}

# Send a prompt and render the reply to stdout.
#   $1 session id   $2 prompt text   $3 mode: live | wait
# Both modes use event shapes verified against a live server:
#   session.text.delta  -> .data.delta  (incremental)
#   session.text.ended  -> .data.text   (complete)
# Subscribes BEFORE prompting so no event is missed in between.
ask_stream() {
  local sid=$1 text=$2 mode=$3
  local tmp pid i total consumed=0 line payload etype
  local started=0 finished=0 guard=0 err="" blocked="" stale=0
  local last=$SECONDS

  tmp=$(mktemp)
  curl -sSN --http1.1 -H "Authorization: Basic $AUTH" "$OPENCODE_HOST/api/event" > "$tmp" 2>/dev/null &
  pid=$!

  for ((i = 0; i < 100; i++)); do
    grep -q 'server\.connected' "$tmp" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done

  # NOTE: do not capture this response. Doing so changed the timing of this
  # function and silently broke streaming on a working server. If you need to
  # check the result, curl the endpoint by hand first.
  post_json "/api/session/$sid/prompt" \
    "$(jq -nc --arg t "$text" '{text:$t}')" >/dev/null

  while ((guard < 2000)); do
    guard=$((guard + 1))
    total=$(wc -l < "$tmp" 2>/dev/null | tr -d ' ')
    total=${total:-0}

    if ((total > consumed)); then
      while IFS= read -r line; do
        case "$line" in data:*) ;; *) continue ;; esac
        payload=${line#data: }
        etype=$(jq -jr '.type // empty' <<< "$payload" 2>/dev/null) || continue
        [[ -n "$etype" ]] || continue
        started=1
        case "$etype" in
          session.text.delta)
            case "$mode" in
              raw)  printf '%s\n' "$line" ;;
              live) jq -jr '.data.delta // empty' <<< "$payload" ;;
            esac
            ;;
          session.text.ended)
            if [[ "$mode" == raw ]]; then
              printf '%s\n' "$line"
            else
              printf '\n'
              [[ "$mode" == wait ]] && { jq -jr '.data.text // empty' <<< "$payload"; printf '\n'; }
            fi
            ;;
          session.step.failed|session.execution.failed)
            err=$(jq -jr '.data.error.message // .data.error.type // "unknown error"' <<< "$payload" 2>/dev/null)
            ;;
          session.execution.succeeded)
            finished=1
            ;;
          *form*|*permission*)
            blocked=$etype
            finished=1
            ;;
        esac
      done < <(sed -n "$((consumed + 1)),${total}p" "$tmp")
      consumed=$total
      last=$SECONDS
    fi

    ((finished)) && break
    kill -0 "$pid" 2>/dev/null || break
    # An agent waiting on a question or permission emits nothing while it waits.
    # Better to report that than hang silently until the guard expires.
    if ((SECONDS - last > 12)); then
      stale=1
      break
    fi
    sleep 0.15
  done

  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  rm -f "$tmp"

  if [[ -n "$err" ]]; then
    printf 'error: %s\n' "$err" >&2
    return 1
  fi
  if [[ -n "$blocked" ]]; then
    printf '\nagent is waiting on input (%s)\n' "$blocked" >&2
    printf 'reply from the web UI, or inspect with: %s watch\n' "$0" >&2
    return 2
  fi
  if ((stale)); then
    printf '\nno activity for 12s - agent may be waiting on a question\n' >&2
    printf 'inspect with: %s watch\n' "$0" >&2
    return 2
  fi
  if ((started == 0)); then
    printf 'no events received - check the server is up and the session is valid\n' >&2
    return 1
  fi
  return 0
}

dir_entries() {
  # name<TAB>type for one directory level on the server
  curl -sS --max-time 15 --http1.1 -G -H "Authorization: Basic $AUTH" \
    --data-urlencode "path=$1" "$OPENCODE_HOST/api/fs/list" 2>/dev/null \
    | jq -r '(.data // [])[] | "\(.type)\t\(.path)"' 2>/dev/null
}

# Directory entries come back location-relative with leading ../ segments and a
# trailing slash, so reduce to the final name component.
dname() {
  local s=${1%/}          # drop trailing slash FIRST, then take the last segment
  printf '%s' "${s##*/}"
}

# Does a directory exist on the server? Lists the parent and looks for the name.
# Listing is location-relative, so we compare the last path segment rather than
# trying to reconstruct an absolute path.
dir_exists() {
  local target=$1 resp
  [[ -z "$target" ]] && return 0
  [[ "$target" == */ ]] && target=${target%/}
  [[ -z "$target" ]] && return 0

  # Ask the server about the path itself. Listing the *parent* does not work:
  # the server's listing does not traverse mount points, so a separate mount is
  # absent from its parent's listing even though the directory plainly exists.
  # That made /projects report as "not found" while `dirs` listed three
  # directories under it.
  #
  # A directory answers with a resolved location, even when empty. A file or a
  # missing path both come back FileNotFoundError. So: no error AND a location.
  #
  #   0 = exists   1 = does not exist   2 = could not tell (transport/parse)
  resp=$(curl -sS --http1.1 -G -H "Authorization: Basic $AUTH" \
    --data-urlencode "path=$target" "$OPENCODE_HOST/api/fs/list" 2>/dev/null) || true
  # NOTE: `|| true` is required. Under `set -e` a command substitution that fails
  # propagates its status, so an unreachable server would kill the script here
  # rather than returning 2.

  printf '%s' "$resp" | jq -e '.' >/dev/null 2>&1 || return 2
  printf '%s' "$resp" | jq -e '
      (._tag // "none") == "none"
      and (.location.directory // "") != ""
    ' >/dev/null 2>&1
}

# Interactive directory chooser. Prevents creating sessions against paths that
# do not exist, which is what left /blah in the project registry.
mkdir_remote() {
  # Create a directory on the server: mkdir -p <base>/<name>
  #
  # The route is POST /api/session/{id}/shell with a command STRING — argv and
  # agentID are rejected, additionalProperties is false.
  #
  # That endpoint 404s when the session's own directory does not exist, so the
  # shell has to run from a directory that is already there. $base always is.
  # The helper session is deleted immediately afterwards; it adds no project
  # row because $base is already registered.
  #
  #   0 = created   1 = failed
  local base=$1 name=$2 resp body code sid target
  [[ -z "$base" || -z "$name" ]] && return 1

  # The name reaches a shell command string, so it is validated rather than
  # quoted. Anything outside this set is refused outright.
  if [[ ! "$name" =~ ^[A-Za-z0-9._/-]+$ || "$name" == *".."* ]]; then
    printf '  names may use letters, digits . _ - and / only, and no ".."\n' >&2
    return 1
  fi
  target="${base%/}/${name#/}"
  target=${target%/}

  resp=$(post_json /api/session "$(jq -nc --arg d "${base%/}" '{location:{directory:$d}}')")
  code=${resp##*$'\n'}; body=${resp%$'\n'*}
  sid=$(printf '%s' "$body" | jq -r '.data.id // empty' 2>/dev/null)
  if [[ -z "$sid" ]]; then
    printf '  could not open a session in %s to create the directory\n' "$base" >&2
    return 1
  fi

  resp=$(curl -sS --http1.1 -w '\n%{http_code}' -X POST \
    -H "Authorization: Basic $AUTH" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg c "mkdir -p $target" '{command:$c}')" \
    "$OPENCODE_HOST/api/session/$sid/shell" 2>/dev/null || true)
  code=${resp##*$'\n'}

  session_delete_remote "$sid" >/dev/null 2>&1 || true

  [[ "$code" == 2* ]] || { printf '  mkdir failed (HTTP %s)\n' "$code" >&2; return 1; }
  # Confirm against the server rather than trusting the 204.
  dir_exists "$target" || { printf '  %s still not visible afterwards\n' "$target" >&2; return 1; }
  return 0
}

# True when $1 is the root itself or something under it. The separator matters:
# "$dir" == "$root"* would accept /projects2, which is a different tree.
#
# Both sides are normalised for macOS's /var -> /private/var convention. Without
# it the server reports its working directory as /private/var/... while you type
# /var/... , and a pure string comparison calls that "outside the root" — which
# is how the first version of this check rejected its own working directory.
#   0 = inside   1 = outside   2 = root unknown, so unverifiable
#
# An unknown root returns 2, NOT 0. Allowing everything is the wrong default for
# a containment control: with the server down, `new` would otherwise have offered
# "/" and accepted it, and the boundary would vanish exactly when something is
# already wrong.
under_root() {
  local dir=${1%/} root=${2%/}
  [[ -n "$root" ]] || return 2
  [[ "$dir"   == /private/* ]] && dir=${dir#/private}
  [[ "$root"  == /private/* ]] && root=${root#/private}
  [[ "$dir" == "$root" || "$dir" == "$root/"* ]]
}

server_workdir() {
  # The server's working directory, from the unit's WorkingDirectory=.
  # /api/fs/list with no path resolves against it and names it in the response.
  # /api/info exposes only paths.tmp — there is no cwd field to read.
  local resp
  resp=$(curl -sS --http1.1 -G -H "Authorization: Basic $AUTH" \
    "$OPENCODE_HOST/api/fs/list" 2>/dev/null) || return 1
  printf '%s' "$resp" | jq -r '.location.directory // ""' 2>/dev/null
}

pick_dir() {
  local cur=${1:-} type entry n=0 choice idx
  if [[ -z "$cur" ]]; then
    cur=$(server_workdir) || cur=""
    if [[ -n "$cur" ]]; then
      printf '\n  server working directory:  %s\n' "$cur" >&2
    else
      # Do not label a fallback as a fact. Printing "/" under the heading
      # "server working directory" implies we asked the server and it said so.
      printf '\n  could not reach the server to learn its working directory.\n' >&2
      printf '  browsing from / for reference only; nothing will be created.\n' >&2
      cur=/
    fi
  fi
  local root can_create=0
  root=$(server_workdir)
  [[ -n "$cur" && "$cur" != / ]] && can_create=1
  while :; do
    printf '\n  %s\n' "$cur" >&2
    n=0
    while IFS=$'\t' read -r type entry; do
      [[ "$type" == "directory" ]] || continue
      n=$((n + 1))
      # dname strips the leading ../ segments and any trailing slash
      printf '   %2d  %s\n' "$n" "$(dname "$entry")" >&2
    done < <(dir_entries "$cur")
    ((n == 0)) && printf '   (enter for no subdirectories)\n' >&2
    if ((can_create)); then
      n=$((n + 1))
      printf '   %2d  new subdirectory\n' "$n" >&2
    fi
    printf '\n  number to enter  n new  . use this path  q quit: ' >&2
    read -r choice || { printf '\n' >&2; return 1; }

    case "$choice" in
      q|Q) return 1 ;;
      .|'') printf '%s' "$cur"; return 0 ;;
      /*)
        rc=0; under_root "${choice%/}" "$root" || rc=$?
        if (( rc != 0 )); then
          printf '  outside %s - sessions can only be created under it\n' "$root" >&2
          continue
        fi
        cur=${choice%/}; continue ;;
      n|N|new)
        # Typing n is the same as picking the create slot, so both routes land
        # in the one block below rather than duplicating it.
        if (( ! can_create )); then
          printf '  cannot create a directory at /\n' >&2
          continue
        fi
        choice=$n
        ;;
      *)
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > n )); then
          printf '  not a listed number\n' >&2
          continue
        fi
        ;;
    esac

    # The LAST slot is "new subdirectory", which is not a real entry. Without
    # this it fell through the descent loop, matched no directory, and silently
    # reprinted the same screen.
    if (( can_create && choice == n )); then
      local made
      printf '  name for the new directory under %s: ' "$cur" >&2
      read -r made || { printf '\n' >&2; return 1; }
      made=${made#/}
      if [[ -z "$made" ]]; then
        printf '  that name cannot be used\n' >&2
      elif mkdir_remote "$cur" "$made"; then
        printf '  created:  %s/%s\n' "${cur%/}" "$made" >&2
        printf '%s' "${cur%/}/$made"
        return 0
      fi
      continue
    fi

    idx=0
    while IFS=$'\t' read -r type entry; do
      [[ "$type" == "directory" ]] || continue
      idx=$((idx + 1))
      if ((idx == choice)); then
        cur="${cur%/}/$(dname "$entry")"
        break
      fi
    done < <(dir_entries "$cur")
  done
}

# Configuration: no fallbacks. A required variable that is missing or empty is a
# hard error rather than a silent default, so a test or a script can never drift
# onto the wrong server without saying so.
#
# Scope the requirement to what each command actually uses. `ls`, `rm` and `use`
# only touch files under SESSIONS_DIR; making them demand network credentials
# blocks local housekeeping. Everything that speaks HTTP still requires them.
local_cmd=0
case "${1:-}" in
  ls|rm|use|"") local_cmd=1 ;;
  selftest) local_cmd=1 ;;
  --version|-V|version) local_cmd=1 ;;
esac

# Answer before the credential guard: asking which copy you are running must work
# even when nothing is configured.
case "${1:-}" in
  --version|-V|version)
    printf 'opencode-bash-tool.sh %s  (%s, %s lines)\n' \
      "$SCRIPT_VERSION" "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" \
      "$(wc -l < "$0" | tr -d ' ')"
    exit 0 ;;
esac

if [[ $# -gt 0 && "${1:-}" != "selftest" ]]; then
  if ((local_cmd == 0)); then
    : "${OPENCODE_HOST:?OPENCODE_HOST is not set. Export it or edit the top of this script.}"
    : "${OPENCODE_PASS:?OPENCODE_PASS is not set. Export it or edit the top of this script.}"
  fi
fi

# Sourced by the test suite: define the functions and stop. Without this, sourcing
# falls into the dispatch below and runs whatever $1 happens to be.
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0
[[ $# -ge 1 ]] || { usage; exit 1; }

case "${1:-}" in

  info)
    api /api/info | jq
    ;;

  new)
    # Positional order is preserved: new [dir] [model] [provider]
    # Flags may appear anywhere: --as <name> registers it in the named store,
    # --dir/--model/--provider override the positional slots.
    dir="" mdl="" prv="" name=""
    shift                                   # drop the subcommand
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --as)        name=${2:?--as needs a name};  shift 2 ;;
        --dir)       dir=${2:?--dir needs a path}; shift 2 ;;
        --model)     mdl=${2:?--model needs an id}; shift 2 ;;
        --provider)  prv=${2:?--provider needs an id}; shift 2 ;;
        -*)          die "unknown option for new: $1" ;;
        *)
          if   [[ -z "$dir" ]]; then dir=$1
          elif [[ -z "$mdl" ]]; then mdl=$1
          elif [[ -z "$prv" ]]; then prv=$1
          else die "too many arguments to new"
          fi
          shift ;;
      esac
    done
    # No PROJECT_DIR: the server's own working directory is the default, and
    # `new` with no arguments always goes to the picker so the choice is
    # explicit. A stale PROJECT_DIR from an older setup is reported once, then
    # ignored, so nobody wonders why it stopped taking effect.
    if [[ -n "${PROJECT_DIR:-}" ]]; then
      printf 'note: PROJECT_DIR=%s is no longer used; the server'"'"'s own working\n' \
        "$PROJECT_DIR" >&2
      printf '      directory is the default, and sessions may only be created under it.\n' >&2
    fi

    # Validate before creating anything. A nonexistent path still yields a
    # session id, which is how junk like /blah ended up in the registry.
    # dir_exists distinguishes "absent" (1) from "could not tell" (2) so a
    # transport failure is never reported as a missing directory.
    if [[ -z "$dir" ]]; then
      # Straight to the picker: no dir argument means "let me choose", and the
      # picker starts at the server's own working directory.
      dir=$(pick_dir) || { printf 'no directory chosen\n' >&2; exit 1; }
      rc=0; dir_exists "$dir" || rc=$?
      case "$rc" in
        0) ;;
        1) printf 'still not found on the server: %s\n' "$dir" >&2; exit 1 ;;
        2) printf 'could not reach the server to check %s\n' "$dir" >&2; exit 1 ;;
      esac
      printf 'using %s\n' "$dir"
    else
      # `|| rc=$?` rather than capturing $? afterwards: under `set -e` a bare
      # function call returning non-zero would exit before the case ran.
      rc=0; dir_exists "$dir" || rc=$?
      case "$rc" in
        0) ;;
        2) printf 'could not reach the server to check %s\n' "$dir" >&2
           printf '  that is not the same as "missing" - fix the connection first\n' >&2
           exit 1 ;;
        1) printf 'directory not found on the server: %s\n' "$dir" >&2
           printf '  browse what is there: %s dirs %s\n' "$0" "$dir" >&2
           dir=$(pick_dir) || { printf 'no directory chosen\n' >&2; exit 1; }
           rc=0; dir_exists "$dir" || rc=$?
           case "$rc" in
             0) printf 'using %s\n' "$dir" ;;
             2) printf 'could not reach the server to check %s\n' "$dir" >&2; exit 1 ;;
             *) printf 'chosen directory still not usable: %s\n' "$dir" >&2; exit 1 ;;
           esac ;;
      esac
    fi

    # Resolve the name and refuse a collision BEFORE creating anything on the
    # server. Checking afterwards would leave an orphan session behind.
    root=$(server_workdir)
    rc=0; under_root "$dir" "$root" || rc=$?
    if (( rc == 2 )); then
      printf 'cannot verify the server working directory, so this will not create anything\n' >&2
      printf '  check the connection:  %s ping\n' "$0" >&2
      exit 1
    elif (( rc == 1 )); then
      printf '%s is outside the server working directory (%s)\n' "$dir" "$root" >&2
      printf '  sessions can only be created under %s\n' "$root" >&2
      printf '  what is there:  %s dirs %s\n' "$0" "$root" >&2
      exit 1
    fi
    auto=$(session_derive_name "$dir" "$name")
    if [[ -f "$(sessions_dir)/$auto.json" ]]; then
      printf 'a session named "%s" already exists  (%s, %s)\n\n' \
        "$auto" \
        "$(jq -r '.id' "$(sessions_dir)/$auto.json")" \
        "$(jq -r '.directory' "$(sessions_dir)/$auto.json")" >&2
      printf '  use %s                      continue it\n' "$auto" >&2
      printf '  new %s --as <name>   start a separate one\n' "$dir" >&2
      exit 1
    fi
    [[ -n "$name" ]] || name=$auto

    resp=$(post_json /api/session "$(jq -nc --arg d "$dir" '{location:{directory:$d}}')")
    code=${resp##*$'\n'}
    body=${resp%$'\n'*}

    if [[ "$code" != 2* ]]; then
      printf 'error: session creation failed (HTTP %s) for dir=%s\n' "$code" "$dir" >&2
      printf 'server said: %s\n' "$body" >&2
      printf 'check that %s exists on the server and is writable by the opencode user\n' "$dir" >&2
      exit 1
    fi

    sid=$(printf '%s' "$body" | jq -r '.data.id // empty' 2>/dev/null || true)
    if [[ -z "$sid" ]]; then
      printf 'error: server returned success but the response had no .data.id field\n' >&2
      printf 'server said: %s\n' "$body" >&2
      exit 1
    fi

    printf 'session id: %s\ndirectory:  %s\n' "$sid" "$dir"

    # A new session inherits the server default model unless one is given, and
    # that default may be a model your account cannot afford.
    if [[ -n "$mdl" ]]; then
      if ! "$0" model "$mdl" "$prv"; then
        printf '\nnot keeping the unusable session\n' >&2
        exit 1
      fi
    fi
    # Every session is tracked. A name is derived when --as is absent, so no
    # session can exist on the server without being findable here. Collision was
    # checked before the session was created.
    session_save "$name" "$sid" "$dir" "$mdl"
    ;;

  ping)
    # Unambiguous connection test. `info` alone is ambiguous: every failure
    # prints nothing, so an unreachable host, a wrong password and a broken
    # server look identical.
    ping_body=$(mktemp)
    printf '  server     %s\n' "$OPENCODE_HOST"
    # curl's -w already emits 000 when it cannot connect, so don't append another.
    code=$(curl -sS --http1.1 -o "$ping_body" -w '%{http_code}' --max-time 10 \
      -H "Authorization: Basic $AUTH" "$OPENCODE_HOST/api/info" 2>/dev/null || true)
    code=${code:-000}
    printf '  status     %s\n' "$code"
    case "$code" in
      2*)
        printf '  auth       ok\n'
        jq -r '"  version    \(.version // "?")\n  pid        \(.pid // "?")"' \
          "$ping_body" 2>/dev/null
        ;;
      401|403)
        rm -f "$ping_body"
        printf '  auth       FAILED - OPENCODE_PASS does not match the server password\n'
        printf '              rotate it on the server, then update OPENCODE_PASS and re-source\n' >&2
        exit 1
        ;;
      000)
        rm -f "$ping_body"
        printf '  reachable  no\n' >&2
        printf '              check OPENCODE_HOST (scheme, port), that the server is running,\n' >&2
        printf '              and that the firewall allows this client\n' >&2
        exit 1
        ;;
      *)
        printf '  unexpected response from %s\n' "$code" >&2
        head -c 200 "$ping_body" >&2; printf '\n' >&2
        rm -f "$ping_body"
        exit 1
        ;;
    esac
    if cur=$(sid_of 2>/dev/null); then
      printf '  session    %s  (%s)\n' "$cur" "$(session_name_for "$cur")"
    else
      printf '  session    none (run: %s new)\n' "$0" >&2
    fi
    rm -f "$ping_body"
    ;;

  locations)
    if sid_of >/dev/null 2>&1; then
      printf 'active session:  %s  (%s)\n' "$(sid_of)" "$(session_name_for "$(sid_of)")"
      printf '  directory:     %s\n' \
        "$(api "/api/session/$(sid_of)" | jq -r '.data.location.directory // "(unknown)"' 2>/dev/null)"
    else
      echo "active session:  none (run: $0 new)"
    fi
    echo
    n=$(api /api/debug/location \
      | jq -r '(if type=="array" then . else .data end) | length')
    if [[ "$n" -gt 0 ]]; then
      echo "locations loaded on the server:"
      api /api/debug/location \
        | jq -r '(if type=="array" then . else .data end)[]? | "  \(.directory)"'
    else
      echo "locations loaded on the server: none cached yet"
    fi
    echo
    echo "projects the server knows about:"
    echo "  (historical registry - paths recorded by earlier sessions. This is"
    echo "   NOT a check that they exist. Use: $0 dirs <path> to verify one.)"
    api /api/project \
      | jq -r '(if type=="array" then . else .data end)[]? | "  \(.canonical)"'
    ;;

  dirs)
    # Resolution: an explicit argument, else ask the server to resolve its own
    # working directory. No client-side default — PROJECT_DIR is gone, so the
    # server is the single source of truth for where work happens.
    #
    # Deliberately NOT /api/debug/location here. That endpoint is usage-derived
    # and fills in lazily, so on a freshly booted server it returns nothing and
    # the chain would silently fall through to /. /api/fs/list with no path
    # resolves against the server's cwd, which is present from process start.
    # One round trip, and the response tells us which location it used.
    dpath=${2:-}
    fell_back=0
    if [[ -n "$dpath" ]]; then
      resp=$(curl -sS --http1.1 -G -H "Authorization: Basic $AUTH" \
        --data-urlencode "path=$dpath" "$OPENCODE_HOST/api/fs/list")
    else
      fell_back=1
      resp=$(curl -sS --http1.1 -G -H "Authorization: Basic $AUTH" \
        "$OPENCODE_HOST/api/fs/list")
    fi
    base=$(printf '%s' "$resp" | jq -r '.location.directory // ""')
    [[ -n "$dpath" ]] || dpath=${base:-/}

    printf '  %s\n' "$dpath"
    printf '%s' "$resp" \
      | jq -r --arg b "$base" '
          def norm:
            (if startswith("/") then "/" else "" end) as $lead
            | (split("/")
               | reduce .[] as $c ([];
                   if $c == "" or $c == "." then .
                   elif $c == ".." then (if length > 0 then .[0:-1] else . end)
                   else . + [$c] end)
               | join("/")) as $p
            | $lead + $p;
          (if type=="array" then . else .data end)[]?
          | "\(.type)\t\((if $b == "" then "" else $b + "/" end) + .path | norm)"
        ' \
      | while IFS=$'\t' read -r t p; do
          case "$t" in
            directory) printf '  [dir]  %s\n' "$p" ;;
            *)         printf '         %s\n' "$p" ;;
          esac
        done

    # Only when the path came from the server rather than from this shell. Without
    # this the user cannot tell a deliberate listing from a defaulted one.
    if (( fell_back )); then
      printf '\n'
      printf '  this is the server'"'"'s own working directory\n' >&2
      printf '  pass a path to browse elsewhere:  %s dirs /some/path\n' "$0" >&2
    fi
    ;;

  ls)
    # shift: inside the case arm $1 is still the subcommand name
    shift
    session_ls "$@"
    ;;

  use)
    session_use "${2:-}"
    ;;

  rm)
    # "${@:2}" not "${2:-}": session_rm already loops over every argument, but the
    # dispatcher passed only the first, so `rm a b c` reported success after
    # forgetting "a" and never mentioned b or c. Silent, not an error.
    session_rm "${@:2}"
    ;;

  delete)
    # Flags may appear anywhere. Previously -y was only read from the third
    # position, which for the --session-id form holds the id, so
    # `delete --session-id <id> -y` silently ignored -y and still prompted.
    shift                                   # drop the subcommand
    dforce=0
    dby_id=0
    dtarget=""
    for darg in "$@"; do
      case "$darg" in
        -y|--yes)     dforce=1 ;;
        --session-id) dby_id=1 ;;
        -*)           die "unknown option for delete: $darg" ;;
        *)
          [[ -z "$dtarget" ]] || die "too many arguments to delete"
          dtarget=$darg ;;
      esac
    done
    [[ -n "$dtarget" ]] || die "usage: $0 delete <name> | --session-id <id>  [-y]"

    if (( dby_id )); then
      dsid=$dtarget
      dlabel=$(printf 'session %s' "$dsid")
      dexpect=$dsid
    else
      df="$(sessions_dir)/$dtarget.json"
      [[ -f "$df" ]] || die "no saved session named \"$dtarget\" - run: $0 ls"
      dsid=$(jq -r '.id' "$df")
      ddir=$(jq -r '.directory // "?"' "$df")
      dlabel=$(printf '%s  (%s)\n              directory: %s' "$dtarget" "$dsid" "$ddir")
      dexpect=$dtarget
    fi

    if (( dforce == 0 )); then
      printf 'This permanently deletes:\n  %s\n  and every message in it.\n\n' "$dlabel" >&2
      printf 'Type it to confirm: ' >&2
      read -r dconfirm || die "aborted"
      [[ "$dconfirm" == "$dexpect" ]] || die "aborted - did not match"
    fi

    if session_delete_remote "$dsid"; then
      printf 'deleted on server: %s\n' "$dsid"
      # Drop the local record too, matched by name or by id.
      local lf
      lf=$(session_file "$dsid" 2>/dev/null || session_file "$dtarget" 2>/dev/null || true)
      [[ -n "$lf" ]] && rm -f "$lf"
      exit 0
    fi
    printf 'local name left in place; retry or use: %s rm %s\n' "$0" "$dtarget" >&2
    exit 1
    ;;

  models)
    filter=${2:-.}
    api /api/model | jq -r --arg f "$filter" \
      '.data[] | select(.id | test($f; "i")) | "\(.id)\t\(.name // "")"'
    ;;

  model)
    model=${2:?usage: $0 model <model-id> [provider-id]}
    provider=${3:-opencode}
    sid=$(sid_of)
    resp=$(post_json "/api/session/$sid/model" \
      "$(jq -nc --arg id "$model" --arg p "$provider" '{model:{id:$id,providerID:$p}}')")
    code=${resp##*$'\n'}
    body=${resp%$'\n'*}

    if [[ "$code" != 2* ]]; then
      printf 'error: model switch failed (HTTP %s) for %s/%s\n' "$code" "$provider" "$model" >&2
      printf 'server said: %s\n' "$body" >&2
      case "$body" in
        *LocationNotFound*)
          printf '\nthe session directory does not exist on the server.\n' >&2
          printf 'create it on the host, then run new again:\n' >&2
          printf '  ssh <lxc> mkdir -p %s\n' \
            "$(printf '%s' "$body" | jq -r '.location.directory // empty' 2>/dev/null)" >&2
          ;;
        *SessionNotFound*)
          printf '\nno such session. Run: %s ls\n' "$0" >&2
          ;;
        *)
          printf '\ncheck the id and provider with: %s models %s\n' "$0" "$model" >&2
          ;;
      esac
      exit 1
    fi

    printf 'session %s now uses %s/%s\n' "$sid" "$provider" "$model"
    printf 'note: session-scoped only; new sessions revert to the server default\n'
    ;;

  watch)
    sid=$(sid_of)
    # -N disables curl buffering; --line-buffered does the same for grep.
    # Without either, output appears frozen even while events are arriving.
    curl -sSN --http1.1 -H "Authorization: Basic $AUTH" "$OPENCODE_HOST/api/event" \
      | grep --line-buffered -F "$sid" || true
    ;;

  raw)
    # exec so curl owns the terminal: true passthrough, no buffering, Ctrl-C
    # exits cleanly. -i includes response headers, useful for checking auth.
    # shift first: the case tested ${1:-} without dropping the subcommand, so ${1}
    # was still "raw" and -i could never match. Documented, and silently a no-op.
    shift
    case "${1:-}" in
      -i|--include) exec curl -sN --http1.1 --include \
              -H "Authorization: Basic $AUTH" "$OPENCODE_HOST/api/event" ;;
      -*) die "unknown option for raw: $1" ;;
      *)  exec curl -sN --http1.1 \
              -H "Authorization: Basic $AUTH" "$OPENCODE_HOST/api/event" ;;
    esac
    ;;

  ask)
    shift                     # drop the subcommand; $1 must become the first user arg
    mode=${ASK_MODE:-live}
    # Strip any number of leading mode flags, last one wins. Previously only $1
    # was examined, so `ask --wait --raw "x"` sent the literal text "--raw".
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --live) mode=live; shift ;;
        --wait) mode=wait; shift ;;
        --raw)  mode=raw;  shift ;;
        *) break ;;
      esac
    done
    # The message is every remaining word joined. `text=${1:?...}` sent only the
    # first word and discarded the rest with no warning: `ask how are you` asked
    # "how" and dropped the question.
    (($#)) || die "usage: $0 ask [--live|--wait|--raw] \"your message\""
    text="$*"
    sid=$(sid_of)
    ask_stream "$sid" "$text" "$mode"
    # Keep the cached count honest for the session just used.
    sf=$(session_file "$sid" 2>/dev/null || true)
    [[ -n "$sf" ]] && session_cache_msgs "$sf" "$(msg_count "$sid")"
    ;;

  history)
    sid=$(sid_of)
    # Message arrays are newest-first, so the most recent sit at the head.
    api "/api/session/$sid/message" | jq '.data[:3]'
    ;;

  wait)
    sid=$(sid_of)
    curl -sS --http1.1 -X POST -H "Authorization: Basic $AUTH" \
      "$OPENCODE_HOST/api/session/$sid/wait" | jq
    ;;

  selftest)
    selftest
    ;;

  *)
    usage
    exit 1
    ;;
esac
