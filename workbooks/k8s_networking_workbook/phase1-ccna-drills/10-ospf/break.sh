#!/usr/bin/env bash
# Lab 1.10 — break/fix injector.
# Run: netlab-c, root, in your local copy (~/wb/phase1-ccna-drills/10-ospf):  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKY2QgIiRQSEFTRV9ESVIvdG9wbyIKY29udGFpbmVybGFiIGRlcGxveSAtdCByb3V0ZWQuY2xhYi55bWwgLS1yZWNvbmZpZ3VyZSA+L2Rldi9udWxsICYmIGJhc2ggcm91dGVkLXNldHVwLnNoID4vZGV2L251bGwKb3NwZigpIHsgbG9jYWwgcj0kMSBpZD0kMjsgc2hpZnQgMjsgbG9jYWwgYT0oLWMgJ2NvbmYgdCcgLWMgJ3JvdXRlciBvc3BmJyAtYyAib3NwZiByb3V0ZXItaWQgJGlkIik7IGZvciBuIGluICIkQCI7IGRvIGErPSgtYyAibmV0d29yayAkbiBhcmVhIDAiKTsgZG9uZTsgZG9ja2VyIGV4ZWMgY2xhYi1wMXItJHIgdnR5c2ggIiR7YVtAXX0iID4vZGV2L251bGw7IH0KIyAtLS0gdGhlIGZhdWx0IChiZWZvcmUgT1NQRiBzdGFydHMsIGFzIGFmdGVyIGEgaGFyZHdhcmUgc3dhcCkgLS0tCmRvY2tlciBleGVjIGNsYWItcDFyLXIyIGlwIGxpbmsgc2V0IGV0aDEgbXR1IDE0MDAKb3NwZiByMSAxLjEuMS4xIDE3Mi4xNi4xLjAvMjQgMTAuMC4xMi4wLzI0IDEwLjAuMTMuMC8yNCAxLjEuMS4xLzMyCm9zcGYgcjIgMi4yLjIuMiAxNzIuMTYuMi4wLzI0IDEwLjAuMTIuMC8yNCAxMC4wLjIzLjAvMjQgMi4yLjIuMi8zMgpvc3BmIHIzIDMuMy4zLjMgMTAuMC4xMy4wLzI0IDEwLjAuMjMuMC8yNCAzLjMuMy4zLzMyCnNsZWVwIDUwCmNhdCA8PCdUJwoKVElDS0VUICBBZnRlciByMidzIE5JQyByZXBsYWNlbWVudCwgdHJhZmZpYyBmcm9tIGgxIHRvIGgyIHRha2VzIHRoZSBsb25nIHdheQogICAgICAgICh2aWEgcjMpIGFuZCB0aGUgcjHigJNyMiBsaW5rIHNpdHMgaWRsZToKICAgICAgICAgIGRvY2tlciBleGVjIGNsYWItcDFyLWgxIHRyYWNlcm91dGUgLW4gMTcyLjE2LjIuMTAKICAgICAgICBPU1BGIGlzIGNvbmZpZ3VyZWQgaWRlbnRpY2FsbHkgdG8gYmVmb3JlLiByMSBhbmQgcjIgcGluZyBlYWNoIG90aGVyLgpUCg=='
base64 -d <<<"$P" | bash -s -- "$@"
