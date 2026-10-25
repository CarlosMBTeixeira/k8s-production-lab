#!/usr/bin/env bash
# reveal.sh S01 — show a scenario's solution (root cause, fastest path, fix,
# and the injected fault). Only after its row on scoring-sheet.md is filled.
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
id=${1:?usage: reveal.sh S01}
f="$D/scenarios/$id/solution.b64"
[ -f "$f" ] || { echo "no scenario $id"; exit 1; }
read -r -p "Is $id scored on the sheet already? [y/N] " a
[ "$a" = y ] || { echo "Score it first."; exit 0; }
base64 -d "$f" | ${PAGER:-less}
