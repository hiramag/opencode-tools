# Tests

```bash
./tests/run.sh            # all suites
./tests/run.sh store      # one suite
```

Exits non-zero if any case fails, so it works as a gate. Takes about a second.
Needs `jq`; nothing here touches the network or your server.

## What these actually check

Three questions, all about the fiddly decisions the script makes.

**When you create a session, what do we call it?** You type `/projects/ha` and
the script has to invent a name. It takes the last piece of the path — `ha`. The
cases check that a trailing slash doesn't break it, that `/a/b/c/path` gives
`path`, and that a bare `/` — no last piece to use — falls back to a timestamp
rather than an empty name.

**Can you only create sessions inside `/projects`?** The server's working
directory is meant to be a hard wall. `/projects` and `/projects/ha` are allowed;
`/etc`, `/`, and `/projects2` are refused. That last one matters: `/projects2`
begins with the same characters, so a lazy prefix check would wave it through.

**When the script reads a session file, do the fields land in the right
columns?** Session records have a `model` field that is usually empty. Bash
treats a tab as whitespace, so two tabs in a row collapse into one and the empty
field disappears — every field after it shifts one place left. That is how a
session's creation date came to be displayed as its model, with the real
"last used" column blank. Nothing looked broken; the values were real, just in
the wrong columns. Both behaviours are pinned so it cannot come back.

Plus the session library itself: that "current session" is derived from the
newest timestamp rather than read from a pointer file, that a session can be
named by its label *or* its ID, and that `ls` reads cached numbers instead of
asking the server once per session.

## These are regressions

Every case corresponds to something that actually went wrong. The comment above
each group says what broke and how it was found. If a case fails, **read that
comment before changing the code** — the case is often the only record of the
reason.

| Suite | Covers |
|---|---|
| `test_pure.sh` | name derivation, root containment, field parsing |
| `test_store.sh` | the session library — identity, current, caching |
| `test_harness.sh` | the runner itself |

`test_harness.sh` generates a deliberately broken suite, runs `run.sh` against
it, and asserts the runner reports FAIL. Without it, a harness that always says
OPENCODE_PASS is invisible — and that is exactly the failure this suite was written
after.

## Not covered

Anything needing a live server. For that, use the tool's own end-to-end checks,
which start a throwaway server with an isolated database:

```bash
./opencode-bash-tool.sh selftest
```

More importantly: the failures that cost the most time were all **server-side**
— the directory check that mistook `/projects` for missing, the location endpoint
that is empty on a freshly booted server, the `500` from the systemd unit. None
are reachable from here. They are written up in [server.md](../server.md) as
traps, but a trap in a document does not fail when it regresses. Only a test
does.

## Adding a case

Put it with the behaviour it protects, and say where that behaviour came from:

```bash
section "some behaviour"

# Origin: <what broke, and how it was found>
assert_eq "what this proves" "expected" "$(the_thing)"
```

Helpers in `lib.sh`: `assert_eq`, `assert_contains`, `assert_not_contains`,
`assert_rc`, `section`, `fresh_store`, `put_session`, `summary`.

`fresh_store` gives a scratch `SESSIONS_DIR`, so suites cannot see each other's
records or touch `~/.opencode/sessions`. Both are cleaned up on exit.

Two traps worth knowing before you write one:

- **The tool sets `set -e`, and a test suite must not inherit it.** `lib.sh`
  turns it back off after sourcing. Without that, a suite stops at the first
  failing command and looks like one that passed.
- **Never call a function that ends in `die` directly** — `die` exits, taking
  the suite with it. Run it in a subshell: `( sid_of )`.

## A warning worth keeping

Two cases written during this build passed for the wrong reason: one because a
missing variable made every lookup fail identically, another because the
reimplementation under test was missing a prerequisite and every request 401'd.
Both printed exactly what a genuine pass prints.

When a test fails everywhere at once, suspect the test. When it fails nowhere,
suspect it harder.