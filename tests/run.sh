#!/usr/bin/env bash
# Harness. Runs every test_*.sh in this directory and reports.
#
#   ./tests/run.sh              all suites
#   ./tests/run.sh store        just tests/test_store.sh
#
# Exit status is non-zero if any case fails, so it is usable in a pre-commit
# hook or a `git && ./tests/run.sh` gate.

set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[[ -t 1 ]] || { RED=""; GREEN=""; DIM=""; OFF=""; }

TOOL="${TOOL:-$HERE/../opencode-bash-tool.sh}"
if [[ ! -f "$TOOL" ]]; then
  echo "cannot find the tool at $TOOL" >&2
  exit 2
fi

if ! command -v jq >/dev/null; then
  echo "jq is required — every suite uses it to read records" >&2
  exit 2
fi

printf '%stesting %s%s\n\n' "$DIM" "$(cd "$(dirname "$TOOL")" && pwd)/$(basename "$TOOL")" "$OFF"

declare -a files=()
if (( $# )); then
  for want in "$@"; do files+=("$HERE/test_${want}.sh"); done
else
  while IFS= read -r f; do files+=("$f"); done < <(ls "$HERE"/test_*.sh 2>/dev/null)
fi

(( ${#files[@]} )) || { echo "no test_*.sh found in $HERE" >&2; exit 2; }

failed=0
declare -a failed_suites=()

for f in "${files[@]}"; do
  [[ -f "$f" ]] || { echo "${RED}no such suite: $f${OFF}" >&2; failed=1; continue; }
  name=$(basename "$f" .sh)
  if out=$(TOOL="$TOOL" bash "$f" 2>&1); then
    printf '%s  %s — PASS%s\n' "$GREEN" "$name" "$OFF"
  else
    printf '%s  %s — FAIL%s\n' "$RED" "$name" "$OFF"
    printf '%s\n' "$out" | sed 's/^/    /'
    failed=1; failed_suites+=("$name")
  fi
done

echo
if (( failed )); then
  printf '%sFAILED:%s %s\n' "$RED" "$OFF" "${failed_suites[*]:-none}"
  echo
  echo "These cases are regressions. Each one shipped as a bug at some point —"
  echo "check the comment above a failing case before changing the code."
  exit 1
fi

printf '%sall suites passed%s\n' "$GREEN" "$OFF"
echo
echo "Not covered here: anything needing a live server. Run the tool's own"
echo "end-to-end checks for that:"
echo
echo "    ./opencode-bash-tool.sh selftest"