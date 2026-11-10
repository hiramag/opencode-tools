# opencode-bash-tool.sh

Exploring opencode internal via a bash script.  Tool for testing and driving an OpenCode server's event stream over SSE.

**Point it at a local opencode instance, or at a server running opencode.** 

```bash
# Pre-req is that you have opencode installed locally or on a remote server
# One way to start it in the background is by typing:
opencode serve &

# once it's up, you'll get something like this:
# server listening on http://127.0.0.1:4096
# server password <generated password>

# a local instance, on this machine
export OPENCODE_HOST='http://127.0.0.1:4096'

# or a server running opencode, anywhere
export OPENCODE_HOST='http://<server-host>:4096'

export OPENCODE_PASS='<generated password>'     # sent as Basic auth

```

[server.md](./server.md) is one way to stand up a server on a Proxmox LXC. It is a
deployment guide, not a prerequisite — the tool knows nothing about Proxmox, systemd,
or your LAN.

See [Pointing somewhere else](#pointing-somewhere-else) if you use more than one
target.

| File                    |                                                       |
| ----------------------- | ----------------------------------------------------- |
| `opencode-bash-tool.sh` | Drive and inspect the server's event stream over HTTP |
| `README.md`             | This file — client reference                          |
| `server.md`             | Server deployment, verification and traps             |
| `tests/`                | Unit tests for the fiddly logic — `./tests/run.sh`    |

## Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Is it connected?](#is-it-connected)
- [Commands](#commands)
- [Sessions](#sessions)
- [Configuration](#configuration)
- [Security](#security)
- [Events and streaming](#events-and-streaming)
- [API notes](#api-notes)
- [Troubleshooting](#troubleshooting)
- [selftest](#selftest)

---

## Requirements


|            |                                                                                                                                                                                                                                                                                       |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bash`     | 3.2 or newer.                                                                                                                                                                                                                                                                         |
| `curl`     | Preinstalled on macOS and most Linux                                                                                                                                                                                                                                                  |
| **`jq`**   | **Required.** Parses SSE event payloads and builds request bodies. <br>`jq` is a hard dependency, not optional. The script parses model output from the event stream,<br>arbitrary text containing quotes, escapes and newlines — and constructs JSON request bodies from your prompt |
| `base64`   | Builds the Basic auth header. Preinstalled on macOS and most Linux                                                                                                                                                                                                                    |
| `opencode` | local or remote opencode instance                                                                                                                                                                                                                                                     |


The script checks for missing dependencies at startup and names the one it
cannot find, so you will not get a confusing error mid-run.

```bash
brew install jq          # macOS
apt install jq           # Debian/Ubuntu, including the server
```

---

## Quick start

Now point it at a server. Set the two required variables — see
[Configuration](#configuration) — and confirm the connection before anything else.

```bash
./opencode-bash-tool.sh ping                                 # reachable + authenticated
./opencode-bash-tool.sh models <filter>                      # what can this server run?
./opencode-bash-tool.sh new <path>                           # session on the server's default model
./opencode-bash-tool.sh ask "explain this repo"              # reply appears here
```

Run `watch` in a second terminal when you want the raw event stream rather than
just the reply.

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


| Output         | Meaning                                                      |
| -------------- | ------------------------------------------------------------ |
| `status 200`   | connected and authenticated                                  |
| `status 401`   | reachable, **password is wrong** — usually a rotation        |
| `status 000`   | **not reachable** — wrong host, stopped service, or firewall |
| `session none` | connected fine, just needs `new`                             |


The session library lives in `~/.opencode/sessions`, not `/tmp`, so a reboot
clears nothing. `session` shows `none` only before your first `new`.

---

## Commands

`./opencode-bash-tool.sh <command> [options] [arguments]` — run it with no arguments for
the same list.

> **Full reference: [`COMMANDS.md`](COMMANDS.md)** — every command, argument, flag and
> variant in table form, with worked examples, a section on commands that take more
> than one argument, and a table decoding every failure message.

Two kinds of command. **One-shot** commands call the server and keep nothing:
no session, no history, no event stream. **Session-bound** commands read the
active session from `~/.opencode/sessions` — the one `new` or `use` selected —
and act on it.

---

### One-shot — no session

| Command | |
|---|---|
| `ask "<text>"` | One reply. `--model` and `--provider` choose the model; no session is created |
| `raw-ask "<text>"` | Same call, but prints the server's raw JSON body instead of extracting `.data.text` |
| `info` | Server version, pid, capabilities. First thing to run |
| `ping` | Check reachability and auth, naming which failed |
| `models [filter]` | Available model ids |
| `dirs [path]` | Browse the server's filesystem. Defaults to the server's own working directory |
| `raw` | Unfiltered event stream. Not one-shot in the model sense — it streams every session's events, with no filter of any kind |
| `delete --session-id <id>` | Delete a session by id. Needs no local record |
| `selftest` | End-to-end checks against a throwaway server on localhost |
| `--version` | Version, path and line count of this copy |

---

### Bound to the current session

| Command | |
|---|---|
| `new [dir] [model] [provider]` | Create a session, set its model, register it in `~/.opencode/sessions/`, and make it current |
| `new ... --as <name>` | As above, under a name for later `use` |
| `ls` | List named sessions with id, directory, model and creation time |
| `use <name>` | Make a named session the active one |
| `rm <name>` | Forget a named session. Does not delete it on the server |
| `delete <name>` | Delete a named session **on the server too**, and every message in it. Prompts for confirmation; `-y` skips it |
| `model <id> [provider]` | Switch this session's model. Session-scoped: new sessions revert to the server default |
| `history` | Last three messages, raw JSON |
| `wait` | Block until the session is idle |
| `watch` | Stream events, filtered to this session |
| `ask --live\|--wait\|--raw` | Run inside this session, with its tools, files and earlier turns. `--model` switches the session's model first |
| `locations` | Show this session's directory, plus the server's cached locations and project registry |

---

### One command, two modes

`ask` is one-shot by default and becomes session-bound only with `--live`,
`--wait` or `--raw`. `raw-ask` is always one-shot and rejects those flags — it
has no session to attach to.

`--model` works in both, but it means something different each time:

- **One-shot** — the model for that call. Nothing is stored.
- **Session mode** — the session's model is switched first and the change
  persists. The script prints a note when it does that, so the side effect is
  visible rather than silent.

In session mode the model cannot be per-request: the server keeps it on the
session, not on the message.

---

### What each command actually needs

Requiring network credentials for a command that never touches the network is
just friction. The check is scoped to what each command uses:


| Commands                                                         | Requires                                          |
| ---------------------------------------------------------------- | ------------------------------------------------- |
| `ls`, `rm`                                                       | **nothing** — purely local files                  |
| `ping`, `use`, `ask`, `raw-ask`, `history`, `model`, `wait`, `watch`, `raw` | `OPENCODE_HOST`, `OPENCODE_PASS`                  |
| `new`, `delete`, `info`, `models`, `dirs`, `locations`           | `OPENCODE_HOST`, `OPENCODE_PASS`                  |
| `selftest`                                                       | nothing — supplies its own, on a throwaway server |


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

---

## Sessions

---

### What a session is

There is **one store**, in `~/.opencode/sessions`, one JSON file per session:

```json
{"id":"ses_<id>","directory":"<server-workdir>/<name>","model":"<provider>/<model>",
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

---

### Every session gets a name

```bash
./opencode-bash-tool.sh new <server-workdir>/api   # -> api
./opencode-bash-tool.sh new <server-workdir>/notes --as tidy   # -> tidy
./opencode-bash-tool.sh new /                     # -> 20260101-0000, no basename to use
```

A name is derived from the directory's last segment unless `--as` says otherwise,
so a session can never exist on the server without being findable here.

**A taken name is refused, not suffixed:**

```
$ ./opencode-bash-tool.sh new <server-workdir>/api
a session named "api" already exists  (ses_<id>..., <server-workdir>/api)

use api                   continue it
new <server-workdir>/api --as api2 start a separate one
```

Nothing is created and nothing is attached. The two outcomes — continue old
context, or start clean — are opposites, and the script cannot know which you
meant. You only get `ha-2` by asking for it.

---

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

---

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

---

### `ls`

```
NAME              ID                                DIRECTORY               MSGS  MODEL  LAST_USED
api               ses_<id>                        <server-workdir>/api      12  -      2026-01-01 23:10 *
probe             ses_<id>                        <server-workdir>          4  -      2026-01-01 22:55
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

---

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


| Value                       |                                              |
| --------------------------- | -------------------------------------------- |
| `http://<server-host>:4096` | correct                                      |
| `<server-host>:4096`        | no scheme — treated as a hostname            |
| `<server-host>`             | no scheme, no port — tries port 80 and hangs |


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

---

### Pointing somewhere else

`OPENCODE_HOST` is the only thing that decides which server you talk to. Change it
and everything else follows — nothing in the script is tied to a LAN, a Proxmox
host, or a particular subnet.


| Target                                   | Value                                              |
| ---------------------------------------- | -------------------------------------------------- |
| This machine                             | `export OPENCODE_HOST='http://127.0.0.1:4096'`     |
| A laptop on the same network             | `export OPENCODE_HOST='http://<laptop-host>:4096'` |
| A shared or remote instance              | `export OPENCODE_HOST='https://<host>'`            |
| A throwaway, for checking the tool works | `./opencode-bash-tool.sh selftest`                 |

---

### Authentication

`OPENCODE_PASS` is required and is always sent as an HTTP Basic header. There are no
fallbacks by design. If the target server needs no password it ignores the header, so
any value works — but leaving the variable unset is a hard error, not a silent
anonymous request.

---

### Proving it without setting anything up

```bash
./opencode-bash-tool.sh selftest
```

Starts its own `opencode serve` on `127.0.0.1`, points the tool at it, and runs the
whole path — connection, session creation, model listing, model switch, prompt
round-trip. Nothing else on the machine is touched, and the server is torn down
afterwards. If that passes, pointing at a local or laptop instance will too.

Model ids are written two different ways depending on where they go — bare in
commands, `provider/model` in `opencode.json`. Getting it wrong is silent, so it has
its own note in
[COMMANDS.md](./COMMANDS.md#bare-id-vs-providermodel).

---

## Security

Read this before exposing anything to a network you do not fully control.

**Warning, the transport is plain HTTP.** `OPENCODE_HOST` is whatever URL you give it, and
the examples here are `http://`.  Authentication is HTTP Basic — a base64 string,  
which is encoding, not encryption. Anyone able to observe the traffic can recover the password from it. 

Deploying it to an untrusted network without putting HTTPS in front is not a good
idea.

---

### Containment follows the server

Sessions can only be created **under the server's own working directory**. The tool
reads that from the server instead of assuming a path, so the boundary moves with
whatever you point at.

If it cannot read the working directory, it creates nothing.

---

## Events and streaming

---

### Events

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

---

### Stream behaviour

The stream is live. You see what happens while you are connected, and nothing else.

- **Nothing is replayed.** Connect late and you miss the earlier events.
- **There is no automatic reconnect.** If the connection drops, reconnect yourself.
- **You cannot resume** from the last event you saw.
- **Connecting does not fill you in.** The server sends one `server.connected`
  marker so you know the stream is open, but it is not a summary of what you missed.

While nothing is happening, the server sends a `: heartbeat` comment now and then to
stop the connection timing out. You can ignore it.

Losing the stream does not lose work. Sessions live on the server in
`~/.local/share/opencode/opencode.db`, so reconnecting picks up where the session
left off. Keep the session ID — that is what you reconnect to.

If you are writing a client, that means you need your own retry loop with a
backoff, and your own storage if you need history. Do not treat this stream as a
record of what happened.

---

### The raw SSE stream

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


|                |                                                                            |
| -------------- | -------------------------------------------------------------------------- |
| `data: <json>` | One event. The JSON occupies a single line                                 |
| *(blank)*      | Event boundary                                                             |
| `: heartbeat`  | A comment. Held on the wire to keep the connection alive, never dispatched |


Note that `\n` inside `delta` is **two literal characters**, not a newline. JSON
escapes are never resolved on the wire, which is the concrete reason the script
needs `jq` rather than `sed` — see [Requirements](#requirements).

`raw` uses `exec`, so curl owns the terminal. Streaming is unbuffered and Ctrl-C
exits cleanly. No saved session is required, so it works before you have run
`new`.

---

### When to use it

It is the only command that shows what the server emits **before** any filtering,
so it is a monitor and a diagnostic rather than something to build a workflow on:

- **Watch a session you are not driving** — another TUI, the web UI, a script.
  `watch` cannot do this; it filters to the current session.
- **Prove the connection** — `raw -i` shows the response headers: `200` with a
  stream, versus `401` with no body.
- **Learn the event shapes** — what `session.text.delta`, `session.step.failed`
  and the rest actually look like, before writing a filter or a parser.
- **Diagnose a stuck agent** — silence from `ask` has several causes; `raw` shows
  whether events are arriving at all, which separates "blocked on a question"
  from "slow model" from "not connected".
- **Check liveness** — `: heartbeat` comments prove the stream is still open.
- **Capture for later** — pipe to a file and inspect the frames afterwards.
- **See everything at once** — every session and every workspace.

---

### Raw frames from a prompt

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

For a one-shot prompt with no session behind it, `raw-ask` prints the server's
raw JSON body instead:

```bash
./opencode-bash-tool.sh raw-ask --model deepseek-v4.1-flash "what does this repo do?"
```

It uses the same stateless endpoint as `ask`, so there are no frames to show —
only the response body, exactly as the server returned it.

Both say "raw", and they do not show the same thing:

| | `raw-ask "..."` | `ask --raw "..."` |
|---|---|---|
| Endpoint | `/api/experimental/generate/text` | `/api/session/{id}/prompt` plus `/api/event` |
| Session | none | the saved session |
| History | none kept | kept, and the session keeps growing |
| Output | one JSON body | SSE `data:` frames |
| Tools and files | no | yes — the session's agent |
| `--model` | yes, for that call only | yes, and it changes the session's model |

`raw-ask` asks one question and prints the JSON the server sends back. It keeps
nothing, so it is the same call as `ask` without a session flag.

`ask --raw` runs inside the saved session and prints the agent's event frames —
no JSON decoding, no rendering, so `\n` stays two literal characters.

**Rule of thumb:** `raw-ask` to see the response, `ask --raw` to see the stream.

---

## API notes

---

### API authentication

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

---

### Response shapes

**Success responses are wrapped in `data`:**

```json
{ "data": { "id": "ses_...", ... } }
```

**Error responses are NOT wrapped:**

```json
{ "_tag": "SessionNotFoundError", "sessionID": "ses_bogus", "message": "Session not found" }
```

A uniform `.data` access breaks on the failure path. Check the status code first.

---

### Status codes

`POST /api/session/{id}/model` returns **`204 No Content`** on success, not 200.
Other documented responses: `400` invalid request, `401` unauthorized, `404`
session or location not found.

---

### Message arrays are newest-first

`GET /api/session/{id}/message` returns `[0]` as the *most recent* message. To
show recent messages use `.data[:3]`, not `.data[-3:]` — the latter returns the
oldest three.

---

### Finding directories on the server

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

---

## Troubleshooting

---

### Diagnosing a blank `ask`

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

---

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
