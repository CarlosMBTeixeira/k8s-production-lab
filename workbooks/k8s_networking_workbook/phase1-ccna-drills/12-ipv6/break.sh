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
P='c2V0IC1ldW8gcGlwZWZhaWwKYmFzaCAiJExBQl9ESVIvdG9wby5zaCIgdXAgPi9kZXYvbnVsbApzZXRzaWQgaXAgbmV0bnMgZXhlYyBoNmIgcHl0aG9uMyAtbSBodHRwLnNlcnZlciA4MDgwID4vZGV2L251bGwgMj4mMSA8IC9kZXYvbnVsbCAmCiMgLS0tIHRoZSBmYXVsdCAtLS0KaXAgbmV0bnMgZXhlYyBoNmIgaXA2dGFibGVzIC1BIElOUFVUIC1wIGlwdjYtaWNtcCAtaiBEUk9QCmlwIC1uIHI2IC02IG5laWdoIGZsdXNoIGFsbApjYXQgPDwnVCcKClRJQ0tFVCAgQWZ0ZXIgdGhlIHNlY3VyaXR5IHRlYW0gImhhcmRlbmVkIiBoNmIgKCJubyBwaW5nLCBJUHY0IGFuZCBJUHY2IiksCiAgICAgICAgbm90aGluZyByZWFjaGVzIGl0IG92ZXIgSVB2NiBhbnkgbW9yZSDigJQgbm90IGV2ZW4gaXRzIHdlYiBzZXJ2ZXI6CiAgICAgICAgICBpcCBuZXRucyBleGVjIGg2YSBjdXJsIC1tMyAnaHR0cDovL1tmZDAwOjI6OjEwXTo4MDgwLycgICDihpIgdGltZW91dAogICAgICAgICAgaXAgbmV0bnMgZXhlYyBoNmEgY3VybCAtbTMgIGh0dHA6Ly8xMC42LjIuMTA6ODA4MC8gICAgICAgIOKGkiB3b3JrcwogICAgICAgIGg2YidzIElQdjYgYWRkcmVzcyBhbmQgcm91dGVzIGxvb2sgY29ycmVjdC4KVAo='
base64 -d <<<"$P" | bash -s -- "$@"
