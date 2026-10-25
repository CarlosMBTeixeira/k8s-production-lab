#!/usr/bin/env bash
# Lab 1.07 — break/fix injector.
# Run: netlab-a, as root:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKYmFzaCAiJFdCX0RJUi9waGFzZTItbGludXgtbmV0d29ya2luZy9saWIvdG9wby1jcnMuc2giIHVwID4vZGV2L251bGwKbWtkaXIgLXAgL3Zhci90bXAvd3d3OyBlY2hvICJoZWxsbyBmcm9tIHNlcnZlciIgPiAvdmFyL3RtcC93d3cvaW5kZXguaHRtbAojIC0tLSB0aGUgZmF1bHQgLS0tCnNldHNpZCBpcCBuZXRucyBleGVjIHNlcnZlciBweXRob24zIC1tIGh0dHAuc2VydmVyIDgwODAgLS1iaW5kIDEyNy4wLjAuMSAtLWRpcmVjdG9yeSAvdmFyL3RtcC93d3cgPi9kZXYvbnVsbCAyPiYxIDwgL2Rldi9udWxsICYKc2xlZXAgMQpjYXQgPDwnVCcKClRJQ0tFVCAgVGhlIGFwcCBvbiB0aGUgc2VydmVyIG5hbWVzcGFjZSAiaXMgdXAiOgogICAgICAgICAgaXAgbmV0bnMgZXhlYyBzZXJ2ZXIgY3VybCAtcyBsb2NhbGhvc3Q6ODA4MCAgICAgIOKGkiBoZWxsbyBmcm9tIHNlcnZlcgogICAgICAgIGJ1dCBmcm9tIHRoZSBjbGllbnQ6CiAgICAgICAgICBpcCBuZXRucyBleGVjIGNsaWVudCBjdXJsIC1tMyAxMC4yLjIuMjo4MDgwICAgICAg4oaSICJDb25uZWN0aW9uIHJlZnVzZWQiCiAgICAgICAgTm8gZmlyZXdhbGwgcnVsZXMgYW55d2hlcmUgKGNoZWNrOiBpcCBuZXRucyBleGVjIHNlcnZlciBuZnQgbGlzdCBydWxlc2V0KS4KVAo='
base64 -d <<<"$P" | bash -s -- "$@"
