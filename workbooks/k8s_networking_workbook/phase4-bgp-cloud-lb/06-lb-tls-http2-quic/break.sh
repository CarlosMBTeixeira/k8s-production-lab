#!/usr/bin/env bash
# Lab 4.06 — break/fix injector.
# Run: WSL host (Docker), from the lab folder:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKUEtJPSIkTEFCX0RJUi8ucGtpIgpbIC1mICIkUEtJL2xlYWYucGVtIiBdIHx8IGJhc2ggIiRMQUJfRElSL3BraS5zaCIgIiRQS0kiID4vZGV2L251bGwKZG9ja2VyIG5ldHdvcmsgY3JlYXRlIGxhYi10bHMgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKZG9ja2VyIHJtIC1mIGxhYi10bHMtc3J2ID4vZGV2L251bGwgMj4mMSB8fCB0cnVlCiMgLS0tIHRoZSBmYXVsdCAtLS0KZG9ja2VyIHJ1biAtZCAtLW5hbWUgbGFiLXRscy1zcnYgLS1uZXR3b3JrIGxhYi10bHMgLS1uZXR3b3JrLWFsaWFzIGFwaS5sYWIubG9jYWwgXAogIC12ICIkUEtJIjovcGtpOnJvIG5pY29sYWthL25ldHNob290OnYwLjEzIFwKICBvcGVuc3NsIHNfc2VydmVyIC1hY2NlcHQgNDQzIC1jZXJ0IC9wa2kvbGVhZi5wZW0gLWtleSAvcGtpL2xlYWYua2V5IC13d3cgPi9kZXYvbnVsbApzbGVlcCAxCmNhdCA8PFQKClRJQ0tFVCAgVGhlIEFQSSB2ZW5kb3Igcm90YXRlZCB0aGUgY2VydGlmaWNhdGUgb24gaHR0cHM6Ly9hcGkubGFiLmxvY2FsIGxhc3QKICAgICAgICBuaWdodC4gT3VyIGNsaWVudHMgbm93IGZhaWw6CiAgICAgICAgICBkb2NrZXIgcnVuIC0tcm0gLS1uZXR3b3JrIGxhYi10bHMgLXYgJFBLSTovcGtpOnJvIG5pY29sYWthL25ldHNob290OnYwLjEzIFxcCiAgICAgICAgICAgIGN1cmwgLXMgLS1jYWNlcnQgL3BraS9yb290LnBlbSBodHRwczovL2FwaS5sYWIubG9jYWwvCiAgICAgICAgICDihpIgIlNTTCBjZXJ0aWZpY2F0ZSBwcm9ibGVtOiB1bmFibGUgdG8gZ2V0IGxvY2FsIGlzc3VlciBjZXJ0aWZpY2F0ZSIKICAgICAgICBUaGUgdmVuZG9yIHNheXM6ICJUaGUgY2VydGlmaWNhdGUgaXMgdmFsaWQsIHNpZ25lZCBieSB5b3VyIENBLCBhbmQgb3VyCiAgICAgICAgYnJvd3NlciBzaG93cyBhIHBhZGxvY2suIiBPdXIgdHJ1c3Qgc3RvcmUgKHJvb3QucGVtKSBoYXNuJ3QgY2hhbmdlZC4KVAo='
base64 -d <<<"$P" | bash -s -- "$@"
