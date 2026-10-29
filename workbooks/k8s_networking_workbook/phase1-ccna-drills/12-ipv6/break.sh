#!/usr/bin/env bash
# Lab 1.12 — break/fix injector.
# Run: netlab-a, as root:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKYmFzaCAiJExBQl9ESVIvdG9wby5zaCIgdXAgPi9kZXYvbnVsbApzZXRzaWQgaXAgbmV0bnMgZXhlYyBoNmIgcHl0aG9uMyAtbSBodHRwLnNlcnZlciA4MDgwIC0tYmluZCA6OiA+L2Rldi9udWxsIDI+JjEgPCAvZGV2L251bGwgJgojIC0tLSB0aGUgZmF1bHQgLS0tCmlwIG5ldG5zIGV4ZWMgaDZiIGlwNnRhYmxlcyAtQSBJTlBVVCAtcCBpcHY2LWljbXAgLWogRFJPUAppcCAtbiByNiAtNiBuZWlnaCBmbHVzaCBhbGwKY2F0IDw8J1QnCgpUSUNLRVQgIEFmdGVyIHRoZSBzZWN1cml0eSB0ZWFtICJoYXJkZW5lZCIgaDZiICgibm8gcGluZywgSVB2NCBhbmQgSVB2NiIpLAogICAgICAgIG5vdGhpbmcgcmVhY2hlcyBpdCBvdmVyIElQdjYgYW55IG1vcmUg4oCUIG5vdCBldmVuIGl0cyB3ZWIgc2VydmVyOgogICAgICAgICAgaXAgbmV0bnMgZXhlYyBoNmEgY3VybCAtbTMgJ2h0dHA6Ly9bZmQwMDoyOjoxMF06ODA4MC8nICAg4oaSIHRpbWVvdXQKICAgICAgICAgIGlwIG5ldG5zIGV4ZWMgaDZhIGN1cmwgLW0zICBodHRwOi8vMTAuNi4yLjEwOjgwODAvICAgICAgICDihpIgd29ya3MKICAgICAgICBoNmIncyBJUHY2IGFkZHJlc3MgYW5kIHJvdXRlcyBsb29rIGNvcnJlY3QuClQK'
base64 -d <<<"$P" | bash -s -- "$@"
