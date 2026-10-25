#!/usr/bin/env bash
# Lab 4.01 — break/fix injector.
# Run: netlab-c, as root, from your local copy (~/p4/01-frr-bgp):  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKY2QgIiRMQUJfRElSIgpjb250YWluZXJsYWIgZGVzdHJveSAtdCB0b3BvLmNsYWIueW1sIC0tY2xlYW51cCA+L2Rldi9udWxsIDI+JjEgfHwgdHJ1ZQpjb250YWluZXJsYWIgZGVwbG95IC10IHRvcG8uY2xhYi55bWwgPi9kZXYvbnVsbApmb3IgaSBpbiAkKHNlcSAzMCk7IGRvCiAgZG9ja2VyIGV4ZWMgY2xhYi1iZ3AtcjIgdnR5c2ggLWMgJ3Nob3cgYmdwIHN1bW1hcnknIDI+L2Rldi9udWxsIHwgZ3JlcCAtcSAnMTAuMC4yMy4zLipbMC05XVwrICpbMC05XVwrICpOL0EnICYmIGJyZWFrCiAgZG9ja2VyIGV4ZWMgY2xhYi1iZ3AtcjIgdnR5c2ggLWMgJ3Nob3cgYmdwIG5laWdoYm9ycyAxMC4wLjIzLjMnIDI+L2Rldi9udWxsIHwgZ3JlcCAtcSAnQkdQIHN0YXRlID0gRXN0YWJsaXNoZWQnICYmIGJyZWFrCiAgc2xlZXAgMgpkb25lCiMgLS0tIHRoZSBmYXVsdCAtLS0KZG9ja2VyIGV4ZWMgY2xhYi1iZ3AtcjMgdnR5c2ggLWMgJ2NvbmYgdCcgLWMgJ3JvdXRlciBiZ3AgNjUwMDMnIC1jICduZWlnaGJvciAxMC4wLjIzLjIgcGFzc3dvcmQgbGFiLXNlY3JldCcgPi9kZXYvbnVsbApkb2NrZXIgZXhlYyBjbGFiLWJncC1yMyB2dHlzaCAtYyAnY2xlYXIgYmdwIDEwLjAuMjMuMicgPi9kZXYvbnVsbApjYXQgPDwnVCcKClRJQ0tFVCAgaDEgKDE3Mi4xNi4xLjEwKSBsb3N0IGgyICgxNzIuMTYuMy4xMCkgcmlnaHQgYWZ0ZXIgInRoZSBzZWN1cml0eQogICAgICAgIGhhcmRlbmluZyBvZiByMyIuIE9uIHIyOgogICAgICAgICAgZG9ja2VyIGV4ZWMgY2xhYi1iZ3AtcjIgdnR5c2ggLWMgJ3Nob3cgYmdwIHN1bW1hcnknICAg4oaSIDEwLjAuMjMuMyBpbiBzdGF0ZSBBY3RpdmUKICAgICAgICByMiBhbmQgcjMgcGluZyBlYWNoIG90aGVyIGZpbmUuIHIyJ3MgY29uZmlnIHdhc24ndCB0b3VjaGVkLgpUCg=='
base64 -d <<<"$P" | bash -s -- "$@"
