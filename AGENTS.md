# opencode-tools

A portable Bash script that drives an OpenCode server over HTTP and SSE.

## Layout

| Path | What it is |
|---|---|
| `opencode-bash-tool.sh` | The tool. Bash 3.2 compatible. |
| `tests/run.sh` | Test harness. Runs every `tests/test_*.sh`. |
| `README.md` | Client reference. |
| `COMMANDS.md` | Command reference. |
| `server.md` | Server deployment guide. |

## Verify

```sh
./tests/run.sh
```

Run one suite with `./tests/run.sh store`. A failing case is a regression:
read the comment above it before changing the code.

## Constraints

- macOS ships Bash 3.2. Do not use associative arrays, `mapfile`, `${var,,}`,
  or other Bash 4+ features.
- `jq` is a hard dependency. Do not replace it with `sed`/`grep`.
- Keep the script self-contained. No new runtime dependencies beyond `bash`,
  `curl`, `jq`, and `base64`.
- Preserve the existing help and usage text style.

## Safety

- Do not print `OPENCODE_PASS` or any credentials from the environment.
- Do not run a self-test against a remote host unless asked.
