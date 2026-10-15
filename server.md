# OpenCode server

The server half of this setup: a LAN-only OpenCode instance running as an
unprivileged systemd service, confined to writing `/projects`.

For the client half — `opencode-bash-tool.sh`, its commands and API shapes — see
[README.md](./README.md).

- **Server**: an OpenCode container, reachable on the LAN, `opencode` v2.0.26
- **Client**: any machine on the same LAN, running `opencode-bash-tool.sh`

---

## Getting the binary

Everything below assumes OpenCode is installed. Reference:
[opencode.ai/v2/docs](https://opencode.ai/v2/docs/).

```bash
# quickest path
curl -fsSL https://opencode.ai/v2/install | bash
```

Other methods: `brew install anomalyco/tap/opencode-v2`,
`npm install -g @opencode/cli`, `bun install -g --trust @opencode/cli`,
`pnpm add -g --allow-build=@opencode/cli @opencode/cli`,
`yarn global add @opencode/cli`. Docker images are tagged by version, e.g.
`ghcr.io/anomalyco/opencode:2.0.0`.

### For a headless server, the standalone tarball

No Node, npm or package manager needed, and nothing to keep updated underneath:

```bash
# pick glibc for Debian/Ubuntu, musl for Alpine
curl -fsSL -o /tmp/opencode.tar.gz \
  https://opencode.ai/update/api/latest/cli/opencode/opencode-linux-x64.tar.gz
tar -xzf /tmp/opencode.tar.gz -C /tmp opencode
install -m 755 /tmp/opencode /usr/local/lib/opencode/opencode
```

Swap `x64` for `arm64` as needed; add `-baseline` for the `x64` build without
CPU-specific instructions, and `-musl` for Alpine.

### Then check where it actually landed

```bash
opencode --version
opencode debug paths bin      # authoritative — no guessing at a path
```

`debug paths bin` is worth trusting over any remembered location. An install run
as root puts the binary under `/root/.opencode/bin/`, which the service user
cannot traverse — see Trap 1. Installing straight to
`/usr/local/lib/opencode/` avoids the copy entirely.

### Pin a version

This build was verified against **2.0.26**. Environment variable names and some
response shapes differ between releases — `/api/info` returns `paths.tmp` only on
this build, with no `cwd`. Record what you installed and re-verify after any
upgrade.

`latest` is a moving target — at the time of writing it resolves to 2.0.29. The
download URL takes a version, so pin it for a reproducible build:

```bash
# latest  →  https://opencode.ai/files/bin/2.0.29/opencode-linux-x64.tar.gz
curl -fsSL -o /tmp/opencode.tar.gz \
  https://opencode.ai/files/bin/2.0.26/opencode-linux-x64.tar.gz
```

Keep that URL next to the unit. An upgrade is a new tarball, not a rebuild.

---

## The unit

`/etc/systemd/system/opencode.service`, written as one file. Do not use
`systemctl edit` — see Traps.

```ini
[Unit]
Description=OpenCode Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=opencode
Group=opencode
WorkingDirectory=/projects
Environment=HOME=/var/lib/opencode
EnvironmentFile=/etc/opencode/server.env
ExecStart=/usr/local/lib/opencode/opencode serve --hostname 0.0.0.0 --port 4096
Restart=always
RestartSec=5

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/projects /var/lib/opencode
ProtectHome=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
```

`AF_NETLINK` is required. Without it `/api/info` returns 500 — see Traps 7.

Supporting setup:

```bash
useradd -r -m -d /var/lib/opencode -s /bin/bash opencode
mkdir -p /projects /etc/opencode /usr/local/lib/opencode
chown -R opencode:opencode /projects /usr/local/lib/opencode

# binary must NOT live under /root — see Traps 1
cp /root/.opencode/bin/opencode /usr/local/lib/opencode/opencode
chmod 755 /usr/local/lib/opencode/opencode

openssl rand -hex 24
install -o root -g root -m 600 /dev/null /etc/opencode/server.env
echo "OPENCODE_PASSWORD=<generated>" >> /etc/opencode/server.env
```

Storage layout — state and code are deliberately on separate filesystems:

```
/dev/mapper/pve-vm--<ctid>--disk--0   7.8G  → /          system, opencode state
/dev/mapper/pve-vm--<ctid>--disk--1   4.9G  → /projects  code, agent workspace
```

`/var/lib/opencode` (database, credentials) is **not** under `/projects`, so no
agent file operation can reach it.

---

## Provider credentials

```bash
sudo -u opencode -H opencode auth
```

Run it as the service user. As root you would be managing root's own service
registration — a different one — which is how two instances ended up fighting
over the same database. See Trap 5.

The environment variable names used by `serve` are internal strings, not a
stable public contract, so confirm them against the version actually installed
rather than trusting a document:

```bash
opencode --version
OPENCODE_PASSWORD=test-password opencode serve --hostname 127.0.0.1 --port 4991 &
sleep 3; curl -s -u opencode:test-password http://127.0.0.1:4991/api/info
kill %1
```

A `200` with a JSON body confirms both the password variable name and the Basic
auth scheme in one shot. The server currently runs **2.0.26** while the client
runs 2.0.27; everything verified matched, but `/api/info` on the older build
returns only `paths.tmp` — no `cwd`, no other path fields.

---

## Which machine am I on

The single most common source of wrong conclusions on this setup. Four times in
one session, and every instance looked like a real finding:

| Prompt | Machine | `opencode-bash-tool.sh` | `systemctl` / `ps` | `pct` |
|---|---|---|---|---|
| `<user>@… %` | the client (Mac) | ✅ runs here | ✗ | ✗ |
| `root@<proxmox-host>:~#` | the Proxmox host | ✗ | ✗ no such unit | ✅ |
| `root@<container-host>:~#` | the server (container) | ✗ | ✅ | ✗ |

Confirm with `hostname` before trusting any result.

**The dangerous pattern is a silent wrong answer.** The server has no
`opencode-bash-tool.sh`, so nothing runs there. But the *host* answers questions about
a container it knows nothing about:

```bash
# on <proxmox-host> — returns empty, not an error
systemctl show opencode -p WorkingDirectory     #  → WorkingDirectory=
```

An empty result reads as "not configured" when it means "no such unit on this
machine". Same for `ldd /usr/local/lib/opencode/opencode` (no such file) and for
permission probes run with a user that only exists in the container.

### Rules of thumb

- An **empty or surprising** result is more often the wrong machine than a real
  finding. Check `hostname` before theorising.
- From the host, always go through `pct exec <ctid> -- …`. It cannot be mistyped.
- Permission probes must run **inside** the container, or as a user that exists
  there:
  ```bash
  pct exec <ctid> -- sudo -u opencode -H test -r /etc/opencode/server.env
  ```
- Log counts that come back `0` are suspect for the same reason — `grep -c` on a
  path that does not exist returns `0`, which is indistinguishable from a clean
  log.

---

### Process identity — the check that matters most

```bash
PID=$(curl -sS -u "opencode:$OPENCODE_PASS" http://127.0.0.1:4096/api/info | jq -r .pid)
ps -o user= -p "$PID"     # must print: opencode
```

### Is the unit actually managing the process

A working server does **not** prove systemd is running it. A hand-typed
`opencode serve` in a terminal answers every request identically and has no
seccomp filter at all — so it passes all the tests below, and then dies at the
next reboot with the hardening silently gone.

Three checks, in order of how much they tell you:

```bash
systemctl is-enabled opencode
systemctl show opencode -p MainPID -p FragmentPath -p RestrictAddressFamilies
ps -eo pid,ppid,user,args | grep -E '[o]pencode'
```

`is-enabled` is the one most often skipped, and `WantedBy=multi-user.target` in
the unit does **nothing** without it. A unit that is not enabled passes every
manual `systemctl restart` and is still gone at the next power cycle.

`systemctl show` reads systemd's **in-memory merged state**, not the file on
disk. That is the reason to run it rather than `cat` the unit: a file can be
correct while systemd is running something older, and a drop-in can change what
actually got applied without the file reflecting it.

Each `-p` selects one property; they can be repeated. The three form a chain of
assertions:

| Property | What it asserts | A bad value looks like |
|---|---|---|
| `FragmentPath` | systemd loaded a file I recognise | empty, or an unexpected path |
| `MainPID` | and it is running *that file's* process | `0`, or a pid the API does not report |
| `RestrictAddressFamilies` | with the hardening intended | no `AF_NETLINK` — the 500 returns |

Each property alone is suggestive. Together they are conclusive.

### Confirmed state, after a cold reboot

```text
$ systemctl is-enabled opencode
enabled

$ systemctl show opencode -p MainPID -p FragmentPath -p RestrictAddressFamilies
MainPID=137
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK AF_UNIX
FragmentPath=/etc/systemd/system/opencode.service

$ ps -eo pid,ppid,user,args | grep -E '[o]pencode'
    137       1 opencode /usr/local/lib/opencode/opencode serve --hostname 0.0.0.0 --port 4096

$ ./opencode-bash-tool.sh ping        # from the client
  server     http://<server-host>:4096
  status     200
  auth       ok
  version    2.0.26
  pid        137
  session    none (run: ./opencode-bash-tool.sh new)
```

`MainPID=137` came back **identical after the reboot**. In a fresh container pids
are allocated deterministically at boot, so that is the evidence the container
genuinely cold-booted and reproduced the same layout — rather than a service
that was never restarted in the first place.

Expect that number to move. Pids increment across restarts and reset only when
the container reboots, so `MainPID` is `137` right after a cold boot and `460`
after a few restarts. A changing pid is normal; a *mismatch* against
`/api/info` is not — see below.

The boot chain is verified end to end: enabled at boot, the right file, the
right user, exactly one process, `AF_NETLINK` in force.

### Is anything else holding the database

Independent of the above, and the check Trap 5 turns on:

```bash
ps -eo pid,ppid,user,args | grep -E '[o]pencode'
```

Exactly one line is the correct answer:

```text
137       1 opencode /usr/local/lib/opencode/opencode serve --hostname 0.0.0.0 --port 4096
```

Read the columns:

- **`ppid 1`** — orphaned to init, which is how a systemd child appears. This is
  what confirms the process really is systemd's and not something a shell
  started. A `ppid` pointing at a terminal means it is not.
- **`user opencode`** — the unprivileged service user, never root.
- **exactly one line** — two or more means a stray managed instance is
  contending for the same SQLite database. See Trap 5.

The `[o]` bracket in the grep pattern is what stops `grep` matching itself; without
it you get a second, meaningless line every time.

### The reported pid should match MainPID

`GET /api/info` returns a `pid`. It should equal `systemctl show -p MainPID`.
After a cold reboot, confirmed:

```text
MainPID=137          ← systemctl
"pid": 137           ← /api/info
```

An earlier reading showed `136` against the same `MainPID` of `137`, which
looked like a stable off-by-one and was written up as a quirk here. **It did not
survive the reboot.** So treat a mismatch as a live signal, not something to
explain away:

```bash
ps -eo pid,ppid,user,args | grep -E '[o]pencode'
```

One process with the numbers still disagreeing means the server is reporting a
pid cached from an earlier start — check whether the service was restarted
without the container rebooting. Two lines is Trap 5 and needs fixing regardless
of what the API claims.

Recording this because it is the second time on this build that a plausible
explanation was written down and then contradicted by the next measurement. The
first was `paths.cwd`, which does not exist in this API version.

### Write boundary

| Path | Result | Enforced by |
|---|---|---|
| `/projects/...` | succeeds | the allowed write path |
| `/escape-test` (`/`) | refused | `ProtectSystem=strict` |
| `/srv/escape-test` | refused | `ProtectSystem=strict` |
| `/etc/escape-test` | refused | `ProtectSystem=strict` |
| `/root/escape-test` | refused | `ProtectHome=true` + mode 700 |
| `/tmp/escape-test` | succeeded **inside the service only** | `PrivateTmp=true` private tmpfs |

Confirming nothing escaped:

```bash
ls -la /tmp/escape-test     # No such file or directory
ls -la /projects/tmp        # No such file or directory
```

### Credentials are unreadable by the service

```bash
sudo -u opencode -H test -r /etc/opencode/server.env && echo READABLE || echo "not readable"
```

Mode `600 root:root`, service runs as `uid=999`. **Check the file size too** —
28 bytes means the placeholder is still there; a generated 48-char hex password
makes it 67.

### Reads are NOT contained

This was tested and is a real limitation:

```
ask "copy /etc/systemd/system/opencode.service"
→ Copied successfully to /tmp/opencode/opencode.service (560 bytes)
```

`ProtectSystem=strict` restricts **writes**. Any file the `opencode` user can read
remains readable — mode `644` files including `/etc/systemd/system/opencode.service`.
Genuinely unreadable: `/root` and `/etc/shadow` (mode `640 root:shadow`, process
not in the `shadow` group).

True read isolation would require a chroot (`RootDirectory=`) or bubblewrap, both
of which break the runtime — the binary needs libc, `/dev/urandom` and `/proc`.
A weaker middle option is `TemporaryFileSystem=/` plus `BindReadOnlyPaths` for
each path the binary genuinely needs, which gives chroot-style isolation without a
full chroot. That one is untested here; see **Outstanding** for what closing it
would take.

Note this is the read side only. Whether the container can reach *out* is a
separate question, and the answer is yes — see **Egress is unrestricted** under
Outstanding.

### Defence layers actually present

1. **OS permissions** — `opencode` cannot read `/root` or `/etc/shadow`
2. **systemd namespace** — writes confined to `/projects` and `/var/lib/opencode`
3. **Agent judgement** — declined the credential dump and the copy

Layer 3 is not a boundary to rely on, but it is not nothing.

---

## Tests

The client has a unit suite: `./tests/run.sh`, about a second, no network.

```bash
./tests/run.sh            # all suites
./tests/run.sh store      # one suite
```

It covers the fiddly logic — name derivation, the root boundary, field parsing,
and the session library — with a case for every bug listed below that is
reachable from the client. See [tests/README.md](./tests/README.md).

**None of the server-side traps are covered.** Traps 3, 4 and 8 — the
`ReadWritePaths` failure at boot, the `AF_NETLINK` 500, and the cold-empty
location endpoint — reproduce only against a live container. They are written up
here because a note does not fail when it regresses, but only a test does. The
tool's own `selftest` covers the end-to-end path with a throwaway server.

---

## Traps encountered

Each of these failed in a way that pointed somewhere else.

### 1. The binary must not live under `/root`

With `User=opencode`, the service cannot traverse `/root` (mode `700`):

```
Failed to execute /root/.opencode/bin/opencode: Permission denied
Main process exited, code=exited, status=203/EXEC
```

Move it to `/usr/local/lib/opencode/`, or somewhere the service user can reach.

### 2. `systemctl edit` appends `ExecStart` rather than replacing it

```
Service has more than one ExecStart= setting, which is only allowed for
Type=oneshot services. Refusing.
```

A drop-in adds to the inherited list. Either write the whole unit in one file, or
use the reset idiom:

```ini
ExecStart=
ExecStart=/usr/local/lib/opencode/opencode serve --hostname 0.0.0.0 --port 4096
```

### 3. `ReadWritePaths` must cover `HOME`

`ProtectSystem=strict` without `/var/lib/opencode` in `ReadWritePaths` makes the
filesystem read-only, and the server cannot open its own log:

```
Error: EROFS: read-only file system, open
'/var/lib/opencode/.local/share/opencode/log/opencode.log'
```

Service exits at boot. An earlier, milder form of this surfaced as an HTTP `500`
on `/api/info` rather than a crash.

### 4. `RestrictAddressFamilies` without `AF_NETLINK` breaks `/api/info`

`getifaddrs` returned an error, and `/api/info` returned `500` on every call:

```
Error: A system error occurred: getifaddrs returned an error
    at networkInterfaces (unknown)
    ... http.method=GET http.url=/api/info http.status=500
```

`/api/info` builds its `urls` field by enumerating interfaces, and on Linux that
goes through libc `getifaddrs()`, which uses a **netlink socket —
`AF_NETLINK`**. `RestrictAddressFamilies` blocks `socket()` for any family not on
the list, so the call fails with `EAFNOSUPPORT` and the handler throws.

This one is nasty because of its shape:

- **Only that endpoint fails.** Sessions, `locations`, `dirs`, `ask` and SSE all
  work. It reads like an application bug.
- **Restarting does not help.** The same error appeared under two different run
  IDs across a restart. A static policy, not a transient fault.
- **journald shows nothing.** The service logs `Sent HTTP response` to its own
  file, not the journal:

  ```bash
  tail -80 /var/lib/opencode/.local/share/opencode/log/opencode.log
  ```

Fix: add `AF_NETLINK` to the list. That adds exactly one family — the netlink
route protocol, the same thing `ip`, `ss` and `dig` use. Not a meaningful hole
next to the write containment already in place.

### 5. A managed background instance survives the rebuild

An `opencode serve --service` process started under root kept running after the
unit was fixed:

```
root  906  1  /root/.opencode/bin/opencode serve --service
LISTEN 127.0.0.1:49374
```

It was loopback-only (not LAN-reachable) but is still a root process on the old
binary. **Resolved on this host**, but the trap generalises: check
`ps -ef | grep opencode` after any rebuild, not just your unit.

This is not only a rebuild-time problem. **Any `opencode` CLI command spawns
it**, so check after ordinary admin use too:

```bash
sudo -u opencode -H opencode auth list     # spawns a managed instance
# ... and now there are two processes holding the same database

ps -ef | grep opencode | grep -v grep     # expect exactly one
```

Two instances mean SQLite contention on
`/var/lib/opencode/.local/share/opencode/opencode.db`.

Stop it, and stop it respawning:

```bash
sudo -u opencode -H opencode service stop
sudo -u opencode -H opencode service set disabled true
```

The `-u opencode` matters. Run as root and you manage *root's* service
registration — a different one, which is what made this confusing twice: first a
root instance survived a rebuild, then an `opencode` one appeared after `auth`
commands.

If you use the CLI on the server for admin tasks, run it as the service user
so it talks to your systemd service instead of spawning its own:

```bash
sudo -u opencode -H opencode
```

**`opencode service` does not manage systemd units.** Its subcommands are only
`start`, `restart`, `status`, `stop`, `get`, `set`, `unset` — there is no
`install` or `uninstall`, and its registration lives at
`~/.local/state/opencode/service.json`. Typing `opencode` can never delete
`/etc/systemd/system/opencode.service`. Worth stating explicitly, because it is
the obvious suspect when a unit file goes missing.

### 6. `/tmp` is not a valid containment probe

`PrivateTmp=true` gives the service its own tmpfs. A write there succeeds and is
invisible from outside, so a successful `/tmp` write proves nothing. Probe
`/srv` or `/etc` instead — those are genuinely read-only.

### 7. `/api/fs/list` resolves `path` relative to a location

Absolute paths outside the current location return nonsense rather than an error.
Not a "does this exist" primitive — do not build existence checks on it.

Omitting `path` entirely is different: the server resolves against its own
working directory and replies with `.location.directory`. That makes it the
reliable way to ask a server where it works.

### 8. `/api/debug/location` is cold-empty and self-warming

It looks like the endpoint for "where does this server work", and `locations`
prints it. It is not configured state — it is **usage-derived and lazily
populated**:

```
$ curl .../api/debug/location
[]                      # first call, cold server

$ curl .../api/debug/location
[{"directory":"/projects"}]   # second call — the first one warmed it
```

Measured on the same cold process, at the same instant:

```
debug/location : []                       ← empty
fs/list no path: "/…/proj"                 ← resolves correctly
```

Anything that chains off `debug/location` gets an empty result on first contact
and silently falls through to a default. Use `/api/fs/list` with no path.

### 9. `/api/fs/read` is not a root check

The server resolves relative paths, so probing for `/` returns
`FileNotFoundError` with a relative `path` in the error — inconclusive. Use
`ps -o user= -p $PID` instead.

### 10. There is no API for removing a project

`/api/project` is `GET` only. `/api/project/{projectID}` is `PATCH` only, and its
body accepts `canonical`, `name`, `icon` and `commands` with
`additionalProperties: false`. **There is no `DELETE`, and no way to set
`archived`** — the parameter exists only as a filter on reads.

Check the live spec rather than trusting a doc or a recollection:

```bash
curl -sS -u opencode:"$OPENCODE_PASS" "$OPENCODE_HOST/openapi.json" \
  | jq -r '.paths | keys[] | select(test("project"))'
```

Stale registry entries are therefore **not cleanable through the API**. They are
also not a fault: a project registry is history, not inventory, and
`locations` already prints them under a heading saying they may not exist.

The only mechanism left is a direct sqlite write against a database the server
holds open, which the OpenCode documentation explicitly warns against. Leave
them.

Recorded because this was the third endpoint on this build that looked obvious
and was not — after `paths.cwd`, which does not exist in this API version, and
`DELETE /api/project`, which is not implemented. **Check `openapi.json` before
building on an endpoint you have not exercised.**

### 11. Tab is IFS whitespace, so `read` swallows empty fields

`IFS=$'\t' read -r a b c d e` against `a<TAB><TAB>b<TAB>c` puts `b` in `b`, not
an empty string:

```text
input fields:  a, (empty), b, c
tab IFS:       x=[a] y=[b] z=[c] w=[]      ← empty field vanished
\x1f IFS:      x=[a] y=[] z=[b] w=[c]      ← correct
```

Every field after the empty one shifts left by one. Here it meant a session with
no model set printed its **created** timestamp under `MODEL` and left
`LAST_USED` blank — the columns looked plausible, just wrong, and the timestamps
were real values so nothing looked broken.

Use a delimiter that is not IFS whitespace:

```bash
IFS=$'\x1f' read -r a b c d e < <(jq -r '[...] | join("\\u001f")' "$f")
```

A literal `0x1f` byte also works but is invisible in the source; prefer the
`\\u001f` escape.

### 12. A string prefix is not a path relationship

The root boundary must compare with a separator:

```bash
[[ "$dir" == "$root" || "$dir" == "$root/"* ]]   # correct
[[ "$dir" == "$root"* ]]                        # accepts /projects2
```

The second form accepts a sibling directory that merely shares a string prefix.

Both sides also need normalising for macOS's `/var` → `/private/var`. Without
it the server reports its root as `/private/var/...` while you type `/var/...`,
and the comparison calls the server's own working directory outside itself —
which is what the first version did.

### 13. Multi-line commands through `pct exec` hang

```bash
pct exec <ctid> -- sh -c '
...several lines with $vars...
'
```

If the quoting does not survive the paste, `sh -c` gets an unterminated string
and **blocks reading stdin forever**. No output, no error, no timeout — it just
sits there.

`$var` also expands in the *outer* shell, which is the Proxmox host, not the
container. Write a script and push it instead:

```bash
pct push <ctid> /tmp/fix.sh /tmp/fix.sh --perms 0755
pct exec <ctid> -- /bin/sh /tmp/fix.sh
```

`pct push` carries the contents verbatim, with no shell in the middle to mangle
anything. Single simple commands like `systemctl restart opencode` are fine.

Also: a container's `/etc/systemd/system` is on the **container**. Listing it on
the Proxmox host shows a different directory that legitimately has no unit in it.

---

## The malformed server config

The server's `opencode.json` carried a `model` value that was rejected at boot,
and the server **silently discarded it**:

```
WARN message="configuration normalization diagnostic"
  source=/var/lib/opencode/.config/opencode/opencode.json
  path=$.model kind=invalid action="skipped malformed recognized value"
```

`skipped malformed recognized value` means the key was recognised and thrown
away. The server then runs with no default model, and every session created
without an explicit model inherits the problem.

### It is `provider/model`, not a bare id

The config field requires a provider prefix. The API does **not**:

```text
GET /api/model  →  { "modelID": "space-bunny-free",
                     "providerID": "opencode",
                     "id": "space-bunny-free" }
```

`id` is the bare model id, so `"space-bunny-free"` looks correct everywhere the
API is concerned — and is wrong in the config. Verified by starting a throwaway
server with each value and counting warnings in its log:

| `model` value | warnings |
|---|---|
| `"space-bunny-free"` | 8 per boot, silently discarded |
| `"opencode/space-bunny-free"` | **0** |

Confirmed on the live server by comparing counts across a restart — an unchanged
count means the new run logged nothing:

```bash
before=$(grep -c 'normalization diagnostic' /var/lib/opencode/.local/share/opencode/log/opencode.log)
systemctl restart opencode; sleep 3
after=$(grep -c 'normalization diagnostic' /var/lib/opencode/.local/share/opencode/log/opencode.log)
echo "before=$before after=$after"
```

The client had the identical bug — same file, same diagnostic, **48 occurrences**
in its log. Sessions still worked there only because the client sets the model
explicitly through the API when creating a session. The config default had never
been in effect on either machine. Its own check reported `before=48 after=48`
once the prefix was added.

One trap in that comparison: run it as **root** on the server and the log path
does not exist, so both counts come back `0` and it looks like a pass. A count of
`0` there means you are in the wrong shell, not that the config is clean.

Correct file:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode/space-bunny-free"
}
```

To apply it:

```bash
# on the server
sudo -u opencode -H mkdir -p /var/lib/opencode/.config/opencode
cat > /var/lib/opencode/.config/opencode/opencode.json <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "opencode/space-bunny-free"
}
EOF
chown -R opencode:opencode /var/lib/opencode/.config
systemctl restart opencode
```

Check for the warning after **every** config change — it is logged at `WARN`,
not `ERROR`, and nothing else reports it:

```bash
grep 'normalization diagnostic' /var/lib/opencode/.local/share/opencode/log/opencode.log | tail -3
```

Silent on success. Any output means a value was thrown away without anyone
noticing.

Billing is **per model**, not per account: `gemini-4-argon` returns 402 at zero
balance while `space-bunny-free` returns `cost: 0` at the same balance. Both live
under the `opencode` provider.

---

## Lessons worth carrying to the next setup

**Test permissions, do not reason about them.** The claim that the service could
not read `/etc/opencode/server.env` was correct — mode `600 root:root`, process
running as `uid=999` — but it went unverified for hours while other theories were
chased. One command settles it.

**Reach for ground truth before forming a hypothesis.** Several diagnoses on
this build were wrong, each because a single command would have answered it.
`history` on the client, `journalctl -u opencode` on the server, and `test -r`
are all fast and definitive. Repeatedly theorising past an available measurement
is the slowest failure mode available.

**A working service is not the same as a correctly managed one.** A hand-typed
`opencode serve` answers every request, passes every functional test, and has no
hardening at all. Check `MainPID` and `FragmentPath`, not just the output.

**Verify a field name before you build on it.** The fix for the `/api/info` 500
was going to chain off `paths.cwd` from that same endpoint. The actual response
was `"paths": { "tmp": "/tmp/opencode" }` — no `cwd`. The idea was abandoned
before it shipped because someone checked instead of recalling.

**When a test contradicts the spec, distrust the test first.** `/api/fs/list`
appeared to return nothing for `/`, which looked like a location-resolution
problem. It was actually a one-line shell bug — `${1##*/}` on a path ending in
`/` yields empty, and the trailing slash was being stripped after the fact.

**Record what was not proven.** `/etc/shadow` was refused by agent policy, and
the OS-level denial was never exercised. Writing that down as "blocked" would
have overstated the control.

**Distrust a check that reports nothing.** An early version of the client
swallowed the server's response and printed a generic guess, which turned a
working server into an apparently broken one for hours. When output is empty, the
tool is the first suspect.

---

## Network exposure

Two layers exist, and only one is configured here:

- **Container firewall** — allow TCP 4096 from the LAN subnet. Not a blanket rule.
- **Proxmox host** — the common gap. The host can be forwarding or exposing that
  port through its own iptables or bridge configuration, which would bypass the
  container firewall entirely.

Verify **positively and negatively**. A positive test alone proves nothing about
exposure:

```bash
# from a machine on the LAN — expect a response
curl -s -u opencode:'$OPENCODE_PASS' http://<SERVER_IP>:4096/api/info

# from off-network (cellular, or an external host) — expect timeout
curl -s --max-time 5 http://<SERVER_IP>:4096/api/info
```

No TLS. There is no documented TLS story for foreground `serve`, so the password
travels in cleartext over HTTP. Basic auth is base64, not encryption — it stops
casual shoulder-surfing and nothing more. Fine on a trusted LAN; not fine across
anything you do not control.

---

## Blast radius

This server holds provider API keys, has write access to `/projects`, and can
shell out. Anyone who reaches it and knows the password has all three. That is
acceptable on a trusted LAN; it is not acceptable on a shared or guest-laden one.

Paired sessions are the quiet part. `opencode pair` issues a 30-day credential to
that same capability, delivered as a QR code. Do not treat scanning one as casual.

---

## Outstanding

- **Password rotation.** The original password was a placeholder, travelled in
  cleartext HTTP across the LAN, and appears in transcripts. Rotating revokes all
  paired sessions (30-day lifetime). Procedure is in
  [README.md](./README.md#rotating-the-password).
- **Read containment.** Untested as an option:
  `TemporaryFileSystem=/` with `BindReadOnlyPaths` for each readable directory
  gives chroot-style read isolation. Needs a verification loop before it is
  trusted.
- **Egress is unrestricted.** The boundary is one-directional: the container
  firewall controls what may reach the server, but nothing limits where the
  server may reach out. `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
  AF_NETLINK` constrains which socket *families* can be created, not which
  destinations they may connect to, and `AF_INET` is present — so an agent
  asked to fetch a URL will reach the public internet. This was observed, not
  inferred: the agent returned a public IP address. To close it:
  ```ini
  IPAddressDeny=any
  IPAddressAllow=localhost
  IPAddressAllow=<lan-subnet>
  ```
  Needs the same verification loop as read containment, with one extra
  hazard: a denied egress breaks the model's own API call, so a wrong allow
  list looks like a broken model rather than a blocked network. Verify with a
  deliberate outbound fetch before trusting it.
- **The `status=9/KILL` at 2026-10-14 19:47:54.** An external SIGKILL — manual
  `kill -9` or the OOM killer. Unexplained. Check:
  ```bash
  journalctl -k -b --no-pager | grep -iE 'oom|killed process'
  ```
  Silence means someone killed it; an OOM line means it will happen again.
  Note that a *clean* stop also logs `status=130` plus a misleading
  `Failed with result 'exit-code'` — 130 is SIGINT, systemd's default stop
  signal, and it is not in the default `SuccessExitStatus`. Every routine
  `systemctl restart` produces one. Only `9/KILL` is anomalous.
- **Hardening is verified working, not fully attributed.** All six directives are
  in the unit and the boundary tests pass, but they were applied as a set. Only
  `RestrictAddressFamilies` has since been individually implicated (Trap 4).

---

## Client

The client checkout — `opencode-bash-tool.sh`, `README.md`, `COMMANDS.md`.
See the README for commands, verified API shapes, and the blank-output
diagnostic.