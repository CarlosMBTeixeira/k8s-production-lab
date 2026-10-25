#!/usr/bin/env bash
# Lab 1.02 — break/fix injector.
# Run: netlab-c, root, in your local copy (~/wb/phase1-ccna-drills/02-ethernet-arp):  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKY2QgIiRQSEFTRV9ESVIvdG9wbyIKY29udGFpbmVybGFiIGRlcGxveSAtdCBsYW4uY2xhYi55bWwgLS1yZWNvbmZpZ3VyZSA+L2Rldi9udWxsICYmIGJhc2ggbGFuLXNldHVwLnNoID4vZGV2L251bGwKSDFNQUM9JChkb2NrZXIgZXhlYyBjbGFiLXAxbC1oMSBjYXQgL3N5cy9jbGFzcy9uZXQvZXRoMS9hZGRyZXNzKQojIC0tLSB0aGUgZmF1bHQgLS0tCmRvY2tlciBleGVjIGNsYWItcDFsLWg0IHNoIC1jICJpcCBsaW5rIHNldCBldGgxIGFkZHJlc3MgJEgxTUFDOyAobm9odXAgcGluZyAtaSAwLjMgMTAuMC4xMC4zID4vZGV2L251bGwgMj4mMSAmKSIKY2F0IDw8J1QnCgpUSUNLRVQgIE9uIHRoZSBsYW4gdG9wb2xvZ3ksIGgyIOKGkiBoMSBsb3NlcyBsb3RzIG9mIHBhY2tldHMsIG9uIGFuZCBvZmY6CiAgICAgICAgICBkb2NrZXIgZXhlYyBjbGFiLXAxbC1oMiBwaW5nIC1jMjAgLWkwLjIgMTAuMC4xMC4xCiAgICAgICAgaDIg4oaSIGgzIGlzIHBlcmZlY3QuIE5vIGludGVyZmFjZSBlcnJvcnMgYW55d2hlcmUuICJTb21lb25lCiAgICAgICAgcmUtaW1hZ2VkIGg0IHRoaXMgbW9ybmluZy4iClQK'
base64 -d <<<"$P" | bash -s -- "$@"
