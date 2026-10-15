# COMMANDS.md — command reference

Complete reference for every command, flag and variant of `opencode-bash-tool.sh`.

For installation and architecture see `README.md` (client) and `server.md` (server).

Every behaviour documented here was read out of the script's own argument handling
and then checked by running it. Where something is a limit rather than a bug, it says
so.

---

## Conventions

### Notation

| Notation | Means |
|---|---|
| `<angle-brackets>` | you supply this value |
| `[square-brackets]` | optional |
| `a \| b` | choose one of these |
| `...` | one or more, repeatable |
| `CAPS` | a literal, typed exactly as shown |

### Placeholders

Every example uses placeholders, not a real machine's values. Substitute before running.

| Placeholder | Meaning | Example value |
|---|---|---|
| `<server-host>` | hostname or IP of the opencode server | `opencode.example.lan` |
| `<port>` | TCP port the server listens on | `3000` |
| `<password>` | the server account password | *(never shown here)* |
| `<name>` | a session name you chose | `research` |
| `ses_<id>` | a server-assigned session id | `ses_000000000000` |
| `<path>` | an absolute path on the **server's** filesystem | `/projects` |
| `<model-id>` | a model identifier, no provider prefix | `some-model` |
| `<provider-id>` | a provider identifier | `opencode` |
| `<pattern>` | a shell glob, anchored at the start | `res*` |

### Files

| Path | What |
|---|---|
| `<server-workdir>` | the server's working directory; sessions may only be created beneath it |
| `~/.opencode/sessions/` | the local session library, one JSON file per name |

### Commands that take no arguments

`ping`, `info`, `locations`, `history`, `wait`, `watch`, `selftest`, `raw`, `--version`

They ignore everything after the subcommand.

---

## Configuration

Two variables are required. There are **no fallbacks** — a missing value is a hard
error, never a silent default.

```bash
export OPENCODE_HOST='http://<server-host>:<port>'
export OPENCODE_PASS='<password>'
```

`OPENCODE_HOST` **must** include both the scheme and the port. Without them curl
defaults to port 80 and hangs:

| Value | Result |
|---|---|
| `http://<server-host>:<port>` | correct |
| `<server-host>:<port>` | wrong — no scheme |
| `<server-host>` | wrong — no scheme and no port |

`OPENCODE_HOST` and `OPENCODE_PASS` are deliberately namespaced. A bare `HOST` would
collide with the standard shell parameter of the same name that holds your machine's
hostname, which corrupts the shell prompt. The tool will not accept the old `HOST`
or `PASS` names; it fails loudly and tells you which variable is missing.

---

## First five minutes

```bash
# 1. Is the server up, and is the password right?
./opencode-bash-tool.sh ping

# 2. Create a session. No directory means an interactive picker.
./opencode-bash-tool.sh new <path> --as <name>

# 3. Ask something.
./opencode-bash-tool.sh ask --wait "your message here"

# 4. See what you have.
./opencode-bash-tool.sh ls

# 5. Switch between sessions.
./opencode-bash-tool.sh use <name>
```

Expected `ping` output:

```
  server     http://<server-host>:<port>
  status     200
  auth       ok
  version    <version>
  pid        <pid>
  session    <name>  (ses_<id>)
```

---

## Commands

### `ping`

Check reachability and authentication, unambiguously.

```
ping
```

**Arguments:** none. **Flags:** none.

| Field | Meaning |
|---|---|
| `status 2xx` | connected |
| `auth ok` | the password matched |
| `auth FAILED` | reached the server, password rejected |
| `reachable no` | could not connect at all |
| `?` for version or pid | connected, but the server did not return that field |

**Why not just `info`:** every `info` failure prints nothing, so an unreachable host,
a wrong password and a broken server all look identical. `ping` distinguishes them.

| Exit | When |
|---|---|
| 0 | `2xx` |
| 1 | `401`, `403`, `000` (no connection), or any other unexpected code |

```bash
./opencode-bash-tool.sh ping
```

---

### `info`

Raw server info, pretty-printed JSON.

```
info
```

**Arguments:** none. **Flags:** none.

Unfiltered — the output shape is the server's, not this tool's. Use `ping` for
anything you intend to read as a pass/fail.

```bash
./opencode-bash-tool.sh info | jq '.version'
```

---

### `new`

Create a session and register it in the local library.

```
new [<path>] [<model-id>] [<provider-id>] [--as <name>]
new [--dir <path>] [--model <id>] [--provider <id>] [--as <name>]
```

Positional order is preserved: **directory, then model, then provider**. Flags may
appear anywhere and override the corresponding positional slot.

#### Arguments

| Position | Argument | Required | Default | Notes |
|---|---|---|---|---|
| 1 | `<path>` | no | interactive picker | Must exist **on the server** and be under `<server-workdir>` |
| 2 | `<model-id>` | no | server default | Bare id; the provider is the next positional |
| 3 | `<provider-id>` | no | `opencode` | |
| — | `--as <name>` | no | last path segment | Registers the session under a name |

#### Flags

| Flag | Takes | Effect |
|---|---|---|
| `--as` | name | Register under this name |
| `--dir` | path | Same as positional 1 |
| `--model` | id | Same as positional 2 |
| `--provider` | id | Same as positional 3 |

Any other `-`-prefixed argument is an error: `unknown option for new: <arg>`.
A fourth positional is an error: `too many arguments to new`.

#### Naming

| Situation | Resulting name |
|---|---|
| `--as <name>` given | `<name>` |
| Otherwise | the last path segment — `new /projects/research` → `research` |
| Path has no last segment | a UTC timestamp, `YYYYmmdd-HHMM` |

A name that already exists is **refused**, not auto-suffixed. Checking happens
*before* the session is created, so a refusal leaves nothing behind on the server.

#### What it refuses, and why

| Condition | Message | Exit |
|---|---|---|
| Directory absent on the server | `directory not found on the server: <path>` | 0, then offers the picker |
| Server unreachable | `could not reach the server to check <path>` | 1 |
| Directory outside `<server-workdir>` | `<path> is outside the server working directory` | 1 |
| `<server-workdir>` could not be determined | `cannot verify the server working directory` | 1 |
| Name collision | `a session named "<name>" already exists` | 1 |

The containment check **fails closed**. If the server's working directory cannot be
read, the tool declines to create anything rather than assuming anywhere is allowed.

#### Examples

```bash
# Explicit, named
./opencode-bash-tool.sh new /projects --as research

# Interactive: no path at all
./opencode-bash-tool.sh new

# Positional, all three slots
./opencode-bash-tool.sh new /projects <model-id> <provider-id> --as research

# Flags instead of positionals
./opencode-bash-tool.sh new --dir /projects --model <model-id> --as research

# Invalid directory — offers the picker rather than creating a broken session
./opencode-bash-tool.sh new /does/not/exist --as typo
```

#### Note

If a model switch fails, the session **has already been created on the server** and is
reported as `not keeping the unusable session`. It exists server-side but has no local
record. Recover with `ls` on another session's id, or delete it via
`delete --session-id <id>`.

---

### `ls`

List registered sessions.

```
ls [<pattern>] [--refresh]
```

#### Arguments

| Position | Argument | Required | Notes |
|---|---|---|---|
| 1 | `<pattern>` | no | Shell glob, **anchored at the start** |

Matching is shell-glob semantics, not substring: `ls res` matches `research` but not
`my-research`; `ls 'res*'` matches both. A non-matching pattern prints the available
names and exits 1. Supplying several non-flag arguments is accepted; the **last** one wins.

#### Flags

| Flag | Effect |
|---|---|
| `--refresh` | Ask the server for exact message counts and models instead of using the cache |

Any other `-`-prefixed argument is an error.

#### Output

| Column | Notes |
|---|---|
| `NAME` | Your chosen name |
| `ID` | Server session id |
| `DIRECTORY` | Server path the session is bound to |
| `MSGS` | Message count, or `?` if unknown |
| `MODEL` | The session's own model, or `inherits <default>` |
| `LAST_USED` | ISO timestamp, truncated to 16 characters |
| `*` | The current session |

There is no separate current-session file. The current session is **derived** — it is
whichever record has the newest `last_used`. `use` updates that timestamp, so switching
is what makes a session current.

#### Reading the values

| You see | It means |
|---|---|
| `?` in `MSGS` | The count is unknown — cached value never filled in. Use `--refresh`. |
| `inherits <default>` | This session has no model of its own; it uses the server's |
| `inherits (default unknown)` | The server's default could not be read. Not a model named `(default unknown)`. |
| `-` | Field absent from the record |

A `?` means unknown. It is never a real value and is never written to disk.

#### Examples

```bash
./opencode-bash-tool.sh ls                 # everything, cached
./opencode-bash-tool.sh ls --refresh       # exact counts, one round trip per session
./opencode-bash-tool.sh ls 'res*'          # by glob
```

---

### `use`

Switch the current session.

```
use <name|ses_<id>|->
```

#### Arguments

| Position | Argument | Notes |
|---|---|---|
| 1 | `<name>` or `ses_<id>` or `-` | `-` selects the previously current session |

Resolution tries the **name** first, then falls back to matching the **session id**.
Both work for `use`, `rm` and `delete`.

```bash
./opencode-bash-tool.sh use research
./opencode-bash-tool.sh use ses_<id>
./opencode-bash-tool.sh use -          # back to the previous one
```

Only one previous session is tracked, so `use -` twice in a row may have nothing to
return to.

If a record was created against a different server, `use` says so rather than silently
pointing at the wrong machine.

---

### `ask`

Send a prompt to the current session.

```
ask [--live|--wait|--raw] "<text>"
```

#### Arguments

| Position | Argument | Required | Notes |
|---|---|---|---|
| 1 | `--live` \| `--wait` \| `--raw` | no | Output mode. May be repeated; the last one wins. |
| 2..n | `<text>` | yes | Every remaining word, joined with single spaces |

#### Modes

| Mode | Behaviour |
|---|---|
| `--live` | Stream the reply as it is written (default) |
| `--wait` | Print the reply once, when complete |
| `--raw` | Print raw SSE frames instead of a rendered reply |

`ASK_MODE` in the environment sets the default mode when no flag is given.

#### Your message is every remaining word

Words are joined with single spaces, so all of these send the same text:

```bash
./opencode-bash-tool.sh ask "what is in this directory?"
./opencode-bash-tool.sh ask what is in this directory
./opencode-bash-tool.sh ask --wait what is in this directory
```

Quote it anyway. Unquoted text is subject to your shell's word splitting, glob
expansion and alias expansion — a message containing `*` or `$` can be rewritten
before the tool ever sees it. Quoting is insurance against your shell, not a
requirement of the tool.

If no text is given at all, the tool says so and exits rather than sending nothing.

#### Examples

```bash
./opencode-bash-tool.sh ask "what is in this directory?"
./opencode-bash-tool.sh ask --wait "summarise the README"
./opencode-bash-tool.sh ask --raw "show me the raw frames"
```

---

### `wait`

Block until the current session is idle, then print the server's JSON response.

```
wait
```

**Arguments:** none. **Flags:** none.

Useful in scripts: send a prompt, then wait, then read the result.

---

### `watch`

Stream server events, filtered to the current session.

```
watch
```

**Arguments:** none. **Flags:** none.

Runs until interrupted. Events for other sessions are filtered out.

---

### `history`

The last three messages of the current session, as raw JSON, newest first.

```
history
```

**Arguments:** none. **Flags:** none.

The count is **fixed at three** with no option to change it. For the full transcript:

```bash
./opencode-bash-tool.sh history | jq '.data'
```

Rendered text only:

```bash
./opencode-bash-tool.sh history \
  | jq -r '.data[] | select(.type=="assistant") | .parts[].text'
```

Expect `idle` entries in the array — those are server-side markers, not messages.

---

### `model`

Change the model for the current session.

```
model <model-id> [<provider-id>]
```

#### Arguments

| Position | Argument | Required | Default |
|---|---|---|---|
| 1 | `<model-id>` | yes | — |
| 2 | `<provider-id>` | no | `opencode` |

The id and the provider are **separate** here. A bare model id is not enough — the
server needs both to identify a model, and a missing provider is silently discarded
rather than rejected.

Scoped to the current session. New sessions revert to the server default, and the
tool says so on success.

| Server error | Meaning |
|---|---|
| `LocationNotFound` | The session's directory no longer exists on the server |
| `SessionNotFound` | No such session |

```bash
./opencode-bash-tool.sh model <model-id>
./opencode-bash-tool.sh model <model-id> <provider-id>
```

---

### `models`

List models the server offers.

```
models [<filter>]
```

#### Arguments

| Position | Argument | Required | Default |
|---|---|---|---|
| 1 | `<filter>` | no | `.` (everything) |

The filter is a **regular expression**, matched case-insensitively against the model
id. Not a glob — `.` and `*` mean themselves.

```bash
./opencode-bash-tool.sh models              # all
./opencode-bash-tool.sh models ^opencode/   # provider-prefixed ids
./opencode-bash-tool.sh models '^opencode/' # provider-prefixed
```

Output is `id<TAB>name`.

---

### `dirs`

Browse the server's filesystem.

```
dirs [<path>]
```

#### Arguments

| Position | Argument | Required | Default |
|---|---|---|---|
| 1 | `<path>` | no | the server's own working directory |

Directories are shown as `[dir]`. With no argument, the tool says explicitly that the
path came from the server rather than from you — so a defaulted listing is never
mistaken for a deliberate one.

```bash
./opencode-bash-tool.sh dirs                # the server's working directory
./opencode-bash-tool.sh dirs /projects
./opencode-bash-tool.sh dirs /projects/sub
```

---

### `locations`

Show where the current session is bound, what the server has loaded, and its
historical project registry.

```
locations
```

**Arguments:** none. **Flags:** none.

Three sections:

| Section | What it is |
|---|---|
| Active session | Directory the current session is bound to |
| Locations loaded on the server | Derived from usage; empty until something uses them |
| Projects the server knows about | A **historical registry** of paths from earlier sessions |

The project registry is a record, not a check. A path listed there may no longer exist.
Verify with `dirs <path>`.

---

### `rm`

Forget sessions locally.

```
rm <name|ses_<id>> [<name> ...]
```

| | `rm` | `delete` |
|---|---|---|
| Local library | forgets the name | forgets the name |
| Server | **leaves it alone** | deletes it and every message |
| Confirmation | none | prompts you to type the name back |
| Reversible | yes — the session still exists | no |
| Arguments | one or more names | one target |

`rm` takes any number of names and processes all of them:

```bash
./opencode-bash-tool.sh rm <name>
./opencode-bash-tool.sh rm <name-a> <name-b> <name-c>
```

Every name is reported, and processing continues past a name that does not exist. The
exit status is 1 if **any** requested name was missing, so a partial success is still
visible as a failure:

```bash
./opencode-bash-tool.sh rm <exists> <does-not-exist>
#  forgot "<exists>" - the session still exists on the server
#  no session matching "<does-not-exist>"
#    available: <the names that do exist>
#  exit 1
```

With no arguments at all, the tool prints its usage and exits 1.

Because the name is the only handle you have, `rm` makes a session unreachable by name.
It remains on the server, addressable only by session id via `delete --session-id <id>`.

---

### `delete`

Delete a session on the server, permanently.

```
delete <name> [-y]
delete --session-id <ses_<id>> [-y]
```

`-y` may appear in any position, and in either form.

#### Arguments

| Argument | Required | Notes |
|---|---|---|
| `<name>` | yes, unless `--session-id` | The saved name |
| `--session-id` | no | Switches to the id form |
| `<ses_<id>>` | with `--session-id` | The id to delete |
| `-y`, `--yes` | no | Skip the typed confirmation |

#### Confirmation

Without `-y` the tool prints what will be destroyed and requires you to **type the
target back** — not `y`. A mismatch aborts.

| Form | Type back |
|---|---|
| `delete <name>` | the name |
| `delete --session-id <id>` | the session id |

On success the local record is removed too, matched by name or id. If the server delete
fails, the local record is **kept** and the tool says so — you never end up with a name
pointing at nothing.

```bash
./opencode-bash-tool.sh delete <name>
./opencode-bash-tool.sh delete <name> -y
./opencode-bash-tool.sh delete --session-id <ses_<id>> -y
```

---

### `raw`

Unfiltered server-sent event stream. No session needed.

```
raw [-i]
```

**Arguments:** none. **Flags:**

| Flag | Effect |
|---|---|
| `-i`, `--include` | Include the HTTP response headers in the stream |

An unrecognised flag is an error rather than a silent fall-through.

Hands the terminal straight to curl — true passthrough, no buffering, Ctrl-C exits
cleanly. Unlike `watch`, nothing is filtered.

```bash
./opencode-bash-tool.sh raw
./opencode-bash-tool.sh raw -i      # headers first, then frames
```

---

### `selftest`

End-to-end checks against a **local throwaway server** on a temporary port.

```
selftest
```

**Arguments:** none. **Flags:** none.

Starts its own opencode instance, exercises info, session creation, model listing, a
model switch and a prompt round-trip, then tears it down. Never touches your real
server or your session library. Useful after changing the tool, or for checking that
a machine can run it at all.

---

### `--version`, `-V`, `version`

Version, resolved path and line count of **this** copy.

```
--version | -V | version
```

Behaviour has changed under a fixed command name before. A stale copy in shell history
or a second checkout produces output that looks like a fresh bug, so this reports the
path it actually ran from.

---

## Commands taking more than one argument

| Command | Takes | Example |
|---|---|---|
| `rm` | 1..n names | `rm <name-a> <name-b> <name-c>` |
| `new` | up to 3 positionals, plus flags | `new /projects <model-id> <provider-id> --as <name>` |
| `ask` | 1..n words, plus mode flags | `ask --wait "two words minimum"` |
| `model` | up to 2 | `model <model-id> <provider-id>` |
| `ls` | 1 pattern, plus flags | `ls 'res*' --refresh` |
| `delete` | 1 target, plus `-y` | `delete --session-id <ses_<id>> -y` |
| `dirs` | 1 path | `dirs /projects` |
| `models` | 1 regex | `models ^opencode/` |
| `use` | 1 name, id, or `-` | `use -` |
| everything else | 0 | - |

`rm` is the one to reach for when tidying up:

```bash
./opencode-bash-tool.sh rm <name-a> <name-b> <name-c>
```

`ask` also accepts any number of words, but quote them so your shell cannot rewrite
them first. `new` takes at most three positionals; a fourth is an error rather than a
silent truncation.

`ls` accepts more than one pattern, but only the last one is used - there is a single
pattern variable, not a list.

---

## Failure messages

| Message | Means | Is it "missing"? | Exit |
|---|---|---|---|
| `status 000` / `reachable no` | Could not connect at all | No | 1 |
| `auth FAILED` | Reached the server; password rejected | No | 1 |
| `unexpected response from <code>` | Neither success, auth failure nor connection failure | No | 1 |
| `could not reach the server to check <path>` | Transport failure | **No** — explicitly distinguished | 1 |
| `directory not found on the server: <path>` | The server says it is absent | Yes | 0, then offers the picker |
| `cannot verify the server working directory` | Containment could not be checked | No | 1 |
| `<path> is outside the server working directory` | Refused by containment | No | 1 |
| `a session named "<name>" already exists` | Name collision | No | 1 |
| `no session matching "<name>"` | Not in the local library | Yes | 1 |
| `MSGS` shows `?` | Count unknown | — | 0 |
| `inherits (default unknown)` | Server default unreadable | — | 0 |

The distinction in row 5 is deliberate. "I could not ask" and "it is not there" are
different facts, and the tool never reports the first as the second.

---

## Platform notes

### `No route to host` while the server is provably up

The tool prints `status 000`; a direct `ping` returns `errno 65` (`EHOSTUNREACH`) —
the same error a *denied* socket produces. Distinct from a timeout, which means
something answered.

Check these in order.

**1. The command ran inside a sandbox.** Editor agents and CI runners commonly confine
terminal commands to the project directory and block outbound network. The tell:
public hosts resolve while private address ranges fail. Fix: grant the host, or run
from an unsandboxed shell.

**2. The operating system blocked the application from the local network.** On macOS,
an app that touches the LAN without declaring `NSLocalNetworkUsageDescription` in its
`Info.plist` is denied **silently** — no prompt, no entry in Privacy settings, packets
dropped below the socket, and `connect()` returns `EHOSTUNREACH`.

Confirm:

```bash
plutil -extract NSLocalNetworkUsageDescription raw \
  /Applications/<App>.app/Contents/Info.plist
```

An error means the key is absent. Fix: System Settings → Privacy & Security → Local
Network, and enable the app.

**3. A real network fault.** Test from a second machine on the same subnet.

> After granting host-specific access, `curl` and other HTTP clients work, but `ping`
> still fails — approved access is enforced through a proxy and `ping` is not an HTTP
> client. Do not use `ping` to verify this. Use `./opencode-bash-tool.sh ping`.

### `ping` works, other commands fail

`ping` is the only command that does not need a session. Failures elsewhere are often
about the session, not the connection. Check with:

```bash
./opencode-bash-tool.sh locations   # is a session active, and where is it bound?
./opencode-bash-tool.sh ls          # does the name still exist locally?
```

---

## Index

### Commands

| Command | Purpose |
|---|---|
| `ping` | Reachability and auth, unambiguously |
| `info` | Raw server info JSON |
| `new` | Create and register a session |
| `ls` | List registered sessions |
| `use` | Switch the current session |
| `ask` | Send a prompt |
| `wait` | Block until the session is idle |
| `watch` | Stream events for the current session |
| `history` | Last three messages, raw JSON |
| `model` | Change the session's model |
| `models` | List available models |
| `dirs` | Browse the server's filesystem |
| `locations` | Active session, loaded locations, project registry |
| `rm` | Forget a session locally |
| `delete` | Delete a session on the server |
| `raw` | Unfiltered event stream |
| `selftest` | End-to-end checks, local throwaway server |
| `--version`, `-V`, `version` | Version, path and line count of this copy |

### Flags

| Flag | Command | Effect |
|---|---|---|
| `--as <name>` | `new` | Register the session under a name |
| `--dir <path>` | `new` | Directory, flag form |
| `--model <id>` | `new` | Model, flag form |
| `--provider <id>` | `new` | Provider, flag form |
| `--refresh` | `ls` | Exact counts from the server |
| `--live` | `ask` | Stream the reply (default) |
| `--wait` | `ask` | Print once complete |
| `--raw` | `ask` | Raw SSE frames |
| `-y` | `delete` | Skip the typed confirmation |
| `-i`, `--include` | `raw` | Include the response headers in the stream |

### Environment

| Variable | Required | Purpose |
|---|---|---|
| `OPENCODE_HOST` | yes | Server URL, **including scheme and port** |
| `OPENCODE_PASS` | yes | Server account password |
| `ASK_MODE` | no | Default `ask` output mode |
| `PROJECT_DIR` | no | **Ignored.** Reported once, then discarded |
