# opencode-bash-tool.sh

A script for driving an OpenCode server over HTTP and SSE.

**Point it at a local opencode instance, or at a server running opencode.** You do
not have to deploy one yourself.

```bash
# a local instance, on this machine
export OPENCODE_HOST='http://127.0.0.1:4096'

# or a server running opencode, anywhere
export OPENCODE_HOST='http://<server-host>:4096'

export OPENCODE_PASS='anything'     # sent as Basic auth; ignored if the server has none
```

[server.md](./server.md) is one way to stand up a server on a Proxmox LXC. It is a
deployment guide, not a prerequisite — the tool knows nothing about Proxmox, systemd,
or your LAN.

See [Pointing somewhere else](#pointing-somewhere-else) if you use more than one
target.

| File | |
|---|---|
| `opencode-bash-tool.sh` | Drive and inspect the server's event stream over HTTP |
| `README.md` | This file — client reference |
| `server.md` | Server deployment, verification and traps |
| `tests/` | Unit tests for the fiddly logic — `./tests/run.sh` |

## Requirements

| | |
|---|---|
| `bash` | 3.2 or newer. macOS ships 3.2, which is enough |
| `curl` | All HTTP. Preinstalled on macOS and most Linux |
| **`jq`** | **Required.** Parses SSE event payloads and builds request bodies |
| `base64` | Builds the Basic auth header. Preinstalled on macOS and most Linux |
| `opencode` | Only if you run your own server, and for `selftest`, which starts a local one. Not needed when you point at an instance that already exists |
`jq` is a hard dependency, not optional. The script parses model output from the
event stream — arbitrary text containing quotes, escapes and newlines — and
constructs JSON request bodies from your prompt. `sed` and `grep` cannot do that
safely, and a partial failure would corrupt replies intermittently.

The script checks for missing dependencies at startup and names the one it
cannot find, so you will not get a confusing error mid-run.

```bash
brew install jq          # macOS
apt install jq           # Debian/Ubuntu, including the server
```

---

## Is it connected?

One command, and it names the failure rather than printing nothing:

```bash
./opencode-bash-tool.sh ping
```

```
  server     http://<server-host>:4096
  status     200
  auth       ok
  version    2.0.26
  pid        1234
  session    ses_ec6e50...
```

| Output | Meaning |
|---|---|
| `status 200` | connected and authenticated |
| `status 401` | reachable, **password is wrong** — usually a rotation |
| `status 000` | **not reachable** — wrong host, stopped service, or firewall |
| `session none` | connected fine, just needs `new` |

The session library lives in `~/.opencode/sessions`, not `/tmp`, so a reboot
clears nothing. `session` shows `none` only before your first `new`.

---

## Quick start

Set the four required variables first — see [Configuration](#configuration).
Start with `ping` to confirm the connection before anything else.

```bash
./opencode-bash-tool.sh ping                                 # reachable + authenticated
./opencode-bash-tool.sh models bunny                         # what can this server run?
./opencode-bash-tool.sh new /projects                        # session on the server's default model
./opencode-bash-tool.sh ask "explain this repo"              # reply appears here
```

Run `watch` in a second terminal when you want the raw event stream rather than
just the reply.

## The raw SSE stream

`raw` shows exactly what the server puts on the socket, with no filtering and no
JSON parsing:

```bash
./opencode-bash-tool.sh raw          # the stream
./opencode-bash-tool.sh raw -i       # plus response headers
```

Three kinds of line appear:

```
data: {"id":"evt_...","type":"session.text.delta",...,"delta":" with me:\n\n- If..."}

: heartbeat

data: {"id":"evt_...","type":"session.execution.succeeded",...}
```

| | |
|---|---|
| `data: <json>` | One event. The JSON occupies a single line |
| *(blank)* | Event boundary |
| `: heartbeat` | A comment. Held on the wire to keep the connection alive, never dispatched |

Note that `\n` inside `delta` is **two literal characters**, not a newline. JSON
escapes are never resolved on the wire, which is the concrete reason the script
needs `jq` rather than `sed` — see [Requirements](#requirements).

`raw` uses `exec`, so curl owns the terminal. Streaming is unbuffered and Ctrl-C
exits cleanly. No saved session is required, so it works before you have run
`new`.

### Heads up

`raw` applies **no filter of any kind**. Every event from every session and every
workspace goes to your terminal. On a busy server that is a lot of output, and
prompts and model replies from other users pass by unredacted.

It is a diagnostic tool — useful for confirming heartbeats, watching `seq`
increment, or checking what an event actually looks like. Do not leave it running
in a shared terminal. Use `watch` when you want a filtered view of one session.

## Raw frames from a prompt

`ask --raw` does the same thing but scoped to one prompt, so you do not need a
second terminal:

```bash
./opencode-bash-tool.sh ask --raw "what does this repo do?"
```

It prints the `data:` lines exactly as they arrive, with no JSON decoding — so
`\n` stays as a literal backslash-n and you see the event types as the model
writes. Heartbeat comments and blank separators are skipped to keep it readable;
the `raw` command shows those.

The default is unchanged. `--live` still streams the rendered reply, `--wait`
still prints it once complete, and no flag behaves as before.

## Commands

`./opencode-bash-tool.sh <command> [options] [arguments]` — run it with no arguments for
the same list.

> **Full reference: [`COMMANDS.md`](COMMANDS.md)** — every command, argument, flag and
> variant in table form, with worked examples, a section on commands that take more
> than one argument, and a table decoding every failure message.

The summary table follows.

| Command | |
|---|---|
| `info` | Server version, pid, capabilities. First thing to run |
| `ping` | Check reachability and auth, naming which failed. Needs no session |
| `new [dir] [model] [provider]` | Create a session, set its model, and register it in `~/.opencode/sessions/`. Validates the directory first; browses for one if it is missing or wrong |
| `new ... --as <name>` | As above, and register the session under a name for later `use` |
| `ls` | List named sessions with id, directory, model and creation time |
| `locations` | Show the active session's directory, the server's cached locations, and known projects |
| `dirs [path]` | Browse the server's filesystem. Defaults to the server's own working directory |
| `use <name>` | Make a named session the active one |
| `rm <name>` | Forget a named session. Does not delete it on the server |
| `delete <name>` | Delete a named session **on the server too**, and every message in it. Prompts for confirmation; `-y` skips it |
| `delete --session-id <id>` | Same, for a session that has no name |

### Choosing a directory

`new` will not create a session against a directory that does not exist on the
server. The server happily returns a session id for any path, so a typo used to
leave a permanent entry in the project registry — that is where `/blah` came
from.

```
$ ./opencode-bash-tool.sh new /blah
directory not found on the server: /blah
No valid directory given. Browse the server filesystem.
```

Resolution order:

1. A directory given as an argument, if it exists
2. otherwise the server's own working directory
3. Otherwise an interactive browser — number to descend, `.` to accept the
   current path, `q` to quit

Nothing is written to the server until a real directory is chosen, so a
mistyped path costs nothing.

Only `OPENCODE_HOST` and `OPENCODE_PASS` are required, and nothing else can be configured to point
elsewhere — sessions may only be created under the server's working directory.

### Rotating the password

The server reads `OPENCODE_PASSWORD` from its environment file, which systemd
loads before dropping privileges. Rotating it is a one-line edit plus a restart.

On the server:

```bash
openssl rand -hex 24

sudo sed -i 's|^OPENCODE_PASSWORD=.*|OPENCODE_PASSWORD=<new-value>|' \
  /etc/opencode/server.env
sudo systemctl restart opencode
```

Then update `OPENCODE_PASS` wherever the client is configured.

Two things to know:

**Changing it revokes every paired session.** The web UI and desktop/mobile app
sessions last 30 days and are signed out when the server password changes. Anyone
using `opencode pair` will need to re-pair.

**If it goes wrong, the server still starts.** With the variable set but wrong,
the service comes up fine and simply authenticates nobody. Confirm in the log
that you see `server listening` and **no** `server password` line — a password
line means the env file was not read and the server generated a random one:

```bash
journalctl -u opencode -n 15 --no-pager | grep -E 'listening|server password'
```

The password travels in cleartext HTTP across the LAN, so rotate it if it has
been typed into shared terminals, committed, or pasted anywhere.

### Sessions

There is **one store**, in `~/.opencode/sessions`, one JSON file per session:

```json
{"id":"ses_ec...","directory":"/projects/ha","model":"opencode/space-bunny-free",
 "created":"2026-10-14T22:55:35Z","last_used":"2026-10-14T23:10:00Z",
 "host":"http://<server-host>:4096"}
```

No pointer file. **"Which session am I using" is derived** — the entry with the
newest `last_used`. One source of truth, so the two views can never disagree,
and nothing lives in `/tmp` to be swept away by a reboot.

```bash
./opencode-bash-tool.sh new <dir> [--as <name>]   # create, name it, make it current
./opencode-bash-tool.sh use <name|session-id|->   # make it current
./opencode-bash-tool.sh ls                        # all of them, * marks current
```

`ask`, `history`, `model`, `wait` and `locations` act on current and never take
a session ID. `rm <name>` forgets it locally; `delete <name>` removes it from the
server too.

### Every session gets a name

```bash
./opencode-bash-tool.sh new /projects/ha          # -> ha
./opencode-bash-tool.sh new /projects/cfengine --as tidy   # -> tidy
./opencode-bash-tool.sh new /                     # -> 20261014-1642, no basename to use
```

A name is derived from the directory's last segment unless `--as` says otherwise,
so a session can never exist on the server without being findable here.

**A taken name is refused, not suffixed:**

```
$ ./opencode-bash-tool.sh new /projects/ha
a session named "ha" already exists  (ses_ec310a1..., /projects/ha)

use ha                    continue it
new /projects/ha --as ha2 start a separate one
```

Nothing is created and nothing is attached. The two outcomes — continue old
context, or start clean — are opposites, and the script cannot know which you
meant. You only get `ha-2` by asking for it.

### Sessions may only be created under the server's working directory

The server's `WorkingDirectory` is a hard root. `new /etc` is refused, and the
picker will not navigate above it:

```
$ ./opencode-bash-tool.sh new /etc
/etc is outside the server working directory (/projects)
  sessions can only be created under /projects
```

`dirs` is **not** bounded — it is read-only inspection, and occasionally useful
for checking something exists.

The check compares `$dir == $root || $dir == "$root/"*`, never `$dir == "$root"*`:
the second form accepts `/projects2`, a different tree that merely shares a
string prefix.

### `ls`

```
NAME              ID                                DIRECTORY        MSGS  MODEL  LAST_USED
ha                ses_ec33e42c8ffev8kOCCIxTnlHJk  /projects/ha       12  -      2026-10-14 23:10 *
probe             ses_ec35f2be1ffeGMHI0DNWKFb829  /projects           4  -      2026-10-14 22:55
```

`MSGS` is the message count, because a session that has grown to hundreds of
messages is a session worth starting fresh from — latency and cost scale with it,
and retrieval from the middle of a long context is less reliable. (The current
model allows 1M tokens of context, so this is about quality rather than a hard
limit.)

`MODEL` shows what the session actually runs. `inherits <provider/model>` means it
has no model of its own and takes the server's configured default — worth seeing
explicitly, because a wrong default is otherwise invisible until a prompt fails.

It is **cached** in the session's own record and refreshed by `ask`, so listing
is free however many sessions you have. `ls --refresh` asks the server for exact
counts when you need them.

`ls` takes a shell glob, which matters once there are more than a handful:

```bash
./opencode-bash-tool.sh ls        # everything
./opencode-bash-tool.sh ls 'ha*'  # just the ha ones
./opencode-bash-tool.sh ls zzz    # no match, and it lists what is available
```

Names and IDs both work as arguments to `use`, `rm` and `delete`. `use -` returns
to the previously-current session.

`host` is recorded per entry, so pointing the client at a second server warns
rather than silently acting on the wrong one.
## selftest

```bash
./opencode-bash-tool.sh selftest
```

Starts a temporary `opencode serve` on `127.0.0.1:4997` with a throwaway password,
exercises the commands against it, then tears it down. Never touches your
configured `OPENCODE_HOST`/`OPENCODE_PASS` or the server.

```
  info                      ok
  new                       ok
  models                    ok
  model switch              ok
  prompt round-trip         ok

all checks passed
```

`prompt round-trip` is the one that matters. It sends a unique probe string and
asserts via `history` that the server received it *verbatim* — the regression that
shipped once, when the script sent the literal string `ask` instead of your prompt.

Verify the test still bites by deleting the `shift` line in the `ask)` branch; it
should report `prompt round-trip FAIL`. Exit code is 0 on success and 1 on
failure, so it drops into CI or a pre-commit hook unchanged.

`selftest` supplies its own `OPENCODE_HOST`, `OPENCODE_PASS` and `SESSIONS_DIR`, and
asserts before sending anything that it really is pointed at the throwaway server.
It aborts rather than risk touching a real one.

## Configuration

Both variables are **required**. There are no fallbacks: a missing or empty
value is a hard error, never a silent default.

```bash
export OPENCODE_HOST=http://<server-host>:4096
export OPENCODE_PASS='your-server-password'
```

That is the whole configuration. Where sessions live and which directory they
default to are both taken from the server, not configured here.

**`OPENCODE_HOST` must include both the scheme and the port.** Without them curl defaults to
port 80 and the request hangs rather than failing, which is slow to diagnose:

| Value | |
|---|---|
| `http://<server-host>:4096` | correct |
| `<server-host>:4096` | no scheme — treated as a hostname |
| `<server-host>` | no scheme, no port — tries port 80 and hangs |

Or prefix a single invocation:

```bash
OPENCODE_HOST=http://<server-host>:4096 OPENCODE_PASS='your-server-password' ./opencode-bash-tool.sh info
```

Because there are no defaults, put these in your shell profile or an env file you
source, otherwise you will need them in every new terminal:

```bash
# opencode-server.env
export OPENCODE_HOST=http://<server-host>:4096
export OPENCODE_PASS='your-server-password'
```

```bash
source ~/opencode-server.env
```

The session library lives at `~/.opencode/sessions`, outside `/tmp`, so it
survives reboots. Override it with `SESSIONS_DIR` if you want it elsewhere.

### What each command actually needs

Requiring network credentials for a command that never touches the network is
just friction. The check is scoped to what each command uses:

| Commands | Requires |
|---|---|
| `ls`, `rm` | **nothing** — purely local files |
| `ping`, `use`, `ask`, `history`, `model`, `wait`, `watch`, `raw` | `OPENCODE_HOST`, `OPENCODE_PASS` |
| `new`, `delete`, `info`, `models`, `dirs`, `locations` | `OPENCODE_HOST`, `OPENCODE_PASS` |
| `selftest` | nothing — supplies its own, on a throwaway server |

So this works from a bare shell:

```bash
./opencode-bash-tool.sh ls
```

The store defaults to `~/.opencode/sessions`. To point it elsewhere:

```bash
SESSIONS_DIR=~/somewhere/else ./opencode-bash-tool.sh ls
```

`selftest` is exempt entirely — it exports its own credentials and asserts its
own target before sending anything.

### Why no fallbacks

A `${VAR:-default}` fallback can silently point a command at the wrong server. If
an export failed, a test would quietly run against the real server and report success.
`selftest` now asserts its own target and aborts if it is not pointed at the
throwaway server.

Requirements are listed under [Requirements](#requirements) above.

**`watch` filters on the session ID, so `: heartbeat` comment lines are invisible
by design.** To see the raw stream including heartbeats:

```bash
curl -sN -H "Authorization: Basic $AUTH" "$OPENCODE_HOST/api/event"
```

---

## Pointing somewhere else

`OPENCODE_HOST` is the only thing that decides which server you talk to. Change it
and everything else follows — nothing in the script is tied to a LAN, a Proxmox
host, or a particular subnet.

| Target | Value |
|---|---|
| This machine | `export OPENCODE_HOST='http://127.0.0.1:4096'` |
| A laptop on the same network | `export OPENCODE_HOST='http://<laptop-host>:4096'` |
| A shared or remote instance | `export OPENCODE_HOST='https://<host>'` |
| A throwaway, for checking the tool works | `./opencode-bash-tool.sh selftest` |

### Containment follows the server

Sessions may only be created **under the target's own working directory**, and the
tool reads that from the server rather than assuming it. Point at a local opencode
and the boundary becomes whatever that process's working directory is — it is not
`/projects` unless that server was set up that way.

If the working directory cannot be read, the tool refuses to create anything rather
than guessing.

### One library, several servers

`~/.opencode/sessions/` is a single shared store. Records do record which host they
belong to, and `use` tells you when you switch to a session recorded against a
different host — but `ls` has no host column, so a listing can mix servers.

Worse, name collisions are checked **on the name alone**. A session called `work` on
one server blocks `work` on another, and the refusal will not say which server owns
it.

The fix is a separate library per target:

```bash
export SESSIONS_DIR=~/.opencode/sessions-local
```

Or use distinct names. Nothing else needs to change.

### Authentication

`OPENCODE_PASS` is required and is always sent as an HTTP Basic header. There are no
fallbacks by design. If the target server needs no password it ignores the header, so
any value works — but leaving the variable unset is a hard error, not a silent
anonymous request.

### Proving it without setting anything up

```bash
./opencode-bash-tool.sh selftest
```

Starts its own `opencode serve` on `127.0.0.1`, points the tool at it, and runs the
whole path — connection, session creation, model listing, model switch, prompt
round-trip. Nothing else on the machine is touched, and the server is torn down
afterwards. If that passes, pointing at a local or laptop instance will too.

---

# API notes

All verified against opencode v2.0.27 against a live server.

## Authentication

HTTP **Basic**, username literally `opencode`. Bearer tokens do not work.

```bash
AUTH=$(printf 'opencode:%s' "$OPENCODE_PASS" | base64 | tr -d '\n')
curl -H "Authorization: Basic $AUTH" "$OPENCODE_HOST/api/info"
```

The server password comes from `OPENCODE_PASSWORD`, falling back to
`OPENCODE_SERVER_PASSWORD`. `opencode serve` has **no** `--password` flag; the
documented `opencode service set password` applies to the managed background
service, not to foreground `serve`.

If neither env var is set, the server generates a random 32-character password
per boot and prints it to the journal. If you set the var, the password is
**not** printed — so there is no fallback copy if you lose it.

## Response shapes

**Success responses are wrapped in `data`:**

```json
{ "data": { "id": "ses_...", ... } }
```

**Error responses are NOT wrapped:**

```json
{ "_tag": "SessionNotFoundError", "sessionID": "ses_bogus", "message": "Session not found" }
```

A uniform `.data` access breaks on the failure path. Check the status code first.

## Status codes

`POST /api/session/{id}/model` returns **`204 No Content`** on success, not 200.
Other documented responses: `400` invalid request, `401` unauthorized, `404`
session or location not found.

## Message arrays are newest-first

`GET /api/session/{id}/message` returns `[0]` as the *most recent* message. To
show recent messages use `.data[:3]`, not `.data[-3:]` — the latter returns the
oldest three.

## Events

Events arrive as SSE `data:` frames carrying a JSON envelope:

```json
{
  "id": "evt_...",
  "type": "session.text.delta",
  "location": { "directory": "/projects" },
  "data": { "sessionID": "ses_...", "delta": "..." },
  "durable": { "aggregateID": "ses_...", "seq": 14, "version": 1 }
}
```

**Filter by `data.sessionID`, not `location`.** Several event types
(`session.execution.started`, `session.execution.failed`) carry no `location` at
all.

**`durable.seq` increments per session**, which enables gap detection on
reconnect. But not every event is sequenced — `session.usage.updated` carries no
`durable` field — and a filter can hide events entirely. A seq discontinuity does
**not** by itself mean data was lost. Confirm with `GET /session/{id}/message`
before assuming.

**`session.text.ended` carries the complete text.** Accumulate `delta` events
only for live rendering; for a finished message take it from the `ended` event.

## Stream behaviour

Live-only. No replay, no automatic reconnection, no resume via `Last-Event-ID`.
A late subscriber receives a `server.connected` marker, not missed events.

Idle connections are kept alive by periodic `: heartbeat` SSE comments.

Sessions persist server-side in `~/.local/share/opencode/opencode.db`, so a
dropped stream costs you nothing but real-time updates. The session ID is the
durable handle — persist it and you can always re-sync.

---

# Gotchas hit while building this

Worth keeping, because each one failed silently or misleadingly.

1. **The directory must exist on the server.** The server attaches a session to a
   real directory; a placeholder path fails session creation.

2. **Responses are wrapped in `data`.** The typed `@opencode/client` unwraps
   envelopes for you, which is why its examples show bare objects. Raw `curl`
   needs `.data.id`. Assuming a top-level `id` made a working server look broken.

3. **`204` is a success status.** Rejecting anything but 200/201 turned a
   successful model switch into a reported failure — and because 204 has no body,
   the error message read `server said:` with nothing after it.

4. **Message arrays are newest-first**, so `[-3:]` silently returns the oldest
   messages. Looks correct only when there happen to be three of them.

5. **Model IDs are not validated at switch time.** `model definitely-not-real`
   returns success and fails later, when you `ask`. Use `models` as the
   authoritative check.

6. **Don't swallow responses in scripts.** The first version of `new` replaced
   the server's error body with a generic guess, which made diagnosis impossible.
   All POSTs now separate status from body and report what the server actually said.

7. **A blocked agent emits no events.** When the agent asks a question or requests
   permission it goes quiet while waiting. A script that only waits for a terminal
   event hangs until its guard expires. `ask` now gives up after 12s of silence and
   says so, rather than looking frozen.

8. **`new` inherits the server's default model**, which may be one your account
   can't afford. A fresh session then fails instantly with a 402 and produces no
   text at all — indistinguishable from a broken client. Always pass the model:

   ```bash
   ./opencode-bash-tool.sh new /projects space-bunny-free
   ```

9. **When output is blank, run `history`.** It is ground truth: it shows the exact
   prompt text that was sent, the model used, and any error. A blank `ask` has
   several possible causes and terminal output alone doesn't distinguish them.

10. **A default model is a silent trap.** A session created without an explicit
    model inherits the server default, which may be unfunded or broken. The
    failure looks like a client bug. Check the `model` field in `history`, or set
    the default server-side.

11. **Blank output is a symptom, not a cause.** Rejected prompt, failed model,
    stopped service and unparseable stream all produce identical silence. Resist
    theorising past an available measurement — `history` first, always.

12. **A test that cannot fail is not a test.** `selftest` checks the port is free
    before starting and verifies `/api/info`'s `pid` matches the process it
    spawned. Without those, a leaked server from a previous run answers the
    readiness probe and every check passes against the wrong process. It also
    confirms its own server actually died, by pid *and* by port — `kill` alone
    does not prove the process is gone.

    Symptom seen in practice: an orphaned test server held port 4997 for eight
    hours while each `selftest` run reported all checks passed.

## Finding directories on the server

A session is bound to a directory, and that directory must exist on the server or
`new` fails with `LocationNotFoundError`. Two commands tell you what is actually
there:

```bash
./opencode-bash-tool.sh locations          # active session's dir + what the server knows
./opencode-bash-tool.sh dirs               # starts at the server's working directory
./opencode-bash-tool.sh dirs /             # browse from the root
./opencode-bash-tool.sh dirs /projects     # or any path
```

```
  /projects
  [dir]  /projects/README.md
  [dir]  /projects/subdir
```

`dirs` returns entries relative to a location and resolves `..` segments itself,
so paths print absolute and readable rather than as `../../..`. A path that does
not exist prints nothing, which is a quick way to check before running `new`.

With no argument, `dirs` sends no path at all and lets the
server pick. It replies with the location it used, which the header shows, and
says so on stderr:

```
  /projects
  [dir]  /projects/AI1

  this is the server's own working directory
  pass a path to browse elsewhere:  ./opencode-bash-tool.sh dirs /some/path
```

That note only appears when the path came from the server. With a path given
or an explicit argument, the listing stands alone — otherwise you cannot tell a
deliberate listing from a defaulted one. Being on stderr, it stays out of the way
if you pipe the output.

This works on a freshly booted server — it does not depend on the server having
warmed up any state.

### Why not `/api/debug/location`

It looks like the obvious endpoint for "where does this server work", and it is
what `locations` prints. But it is **usage-derived and lazily populated**: on a
cold server it returns `[]`, and the first call warms the server so the second
one succeeds. A client that chains off it gets an empty result on first contact
and silently falls through to `/projects`'s parent — or to `/`.

`/api/fs/list` with no path parameter resolves against the server's working
directory, which exists from process start. One round trip, and the response
names the location it picked.

Note that a directory used by an earlier session stays listed under *projects*
even if it has since been deleted — the server keeps the record.

## Diagnosing a blank `ask`

Blank output was the single most expensive symptom on this setup — it looks
identical whether the prompt was rejected, the model failed, or the server is
down. `history` resolved it every time, faster than any amount of theorising.

Work down this list — each step eliminates a class of cause:

```bash
./opencode-bash-tool.sh history     # prompt text? which model? what error?
curl -sN -u opencode:OPENCODE_PASS OPENCODE_HOST/api/event    # are events flowing at all?
./opencode-bash-tool.sh models X    # does this server actually have the model?
```

`provider.quota` 402 means billing, not code. Empty history means the prompt never
became a message. Events flowing but no output means the client is at fault.

## Known limitation

`ask` can display the reply and detect that the agent is blocked, but it **cannot
answer a question or grant permission**. Those need the form and permission reply
endpoints (`POST /api/session/{id}/form/{formID}/reply` and
`POST /api/session/{id}/permission/{requestID}/reply`), which take structured
answers — beyond a shell script's scope.

Until that exists, answer from the web UI, or steer the prompt toward a
non-interactive outcome: *"don't ask me questions, make reasonable assumptions and
proceed"*.

---

## Other clients

`opencode-bash-tool.sh` is not the only way in.

**TUI**, from any machine on the LAN:

```bash
export OPENCODE_PASSWORD='your-password'
opencode --server http://<SERVER_IP>:4096
```

**Web UI, desktop or mobile app** — open `http://<SERVER_IP>:4096` in a browser,
then pair it from the server:

```bash
sudo -u opencode -H opencode pair
```

That prints a one-time link with a 5-minute expiry and a QR code. Sessions last
**30 days**, so treat scanning it as granting that machine the server's full
capability — provider keys, write access to `/projects`, and the ability to shell
out. Rotating the password revokes all of them at once.

No CORS configuration is needed unless you serve a *custom* web client from a
different origin. CORS does not bypass server authentication either way.

## The SSE constraint that matters for real code

Subscriptions are **live-only**:

- No replay of past events.
- **No automatic reconnection.** A source failure ends current subscriptions;
  you resubscribe after recovery.
- A late subscriber gets the current `server.connected` marker, not missed events.
- Idle connections are kept alive by periodic `: heartbeat` comments.

Events carry a per-session `durable.seq`, but not every event is sequenced — a
gap does not by itself prove data was lost. Filter by `data.sessionID`, not by
`location`; some events carry no location at all.

So a consumer needs an explicit backoff-and-resubscribe loop, and must persist
events elsewhere if it needs history. Do not treat the stream as durable.

---

# Cost

`gemini-4-argon` (provider `opencode`) returns `402 Insufficient account funds`
at zero balance. `space-bunny-free` returns `cost: 0` at the same balance — the
balance gate is **per-model**, not per-account.

```bash
./opencode-bash-tool.sh model space-bunny-free
```

Session-scoped only; new sessions revert to the server default. To make it global,
set `model` in the server's `opencode.json`.

## Bare id vs `provider/model`

The same string is correct in one place and wrong in the other. This has already
caused a real bug, so it is worth stating plainly:

| Where | Format | Example |
|---|---|---|
| API — `/api/model`, `POST /api/session/{id}/model`, this script's commands | bare `modelID` | `space-bunny-free` |
| Config — `opencode.json` `"model"` | **`provider/model`** | `opencode/space-bunny-free` |

`GET /api/model` returns `"id": "space-bunny-free"` with a separate
`"providerID": "opencode"`, so a bare id looks right everywhere the API is
concerned. Put that bare id in a config file and it is silently discarded at boot:

```text
WARN message="configuration normalization diagnostic"
  path=$.model kind=invalid action="skipped malformed recognized value"
```

Logged at `WARN`, reported nowhere else, and the server then runs with no default
model at all. Check after every config change:

```bash
grep 'normalization diagnostic' ~/.local/share/opencode/log/opencode.log | tail -3
```

Silent means clean. See [server.md](./server.md) for the server-side fix.
