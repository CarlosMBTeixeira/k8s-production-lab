#!/usr/bin/env bash
# Lab 1.04 — break/fix injector.
# Run: netlab-c, root, in your local copy (~/wb/phase1-ccna-drills/04-ipv4-header):  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKY2QgIiRQSEFTRV9ESVIvdG9wbyIKY29udGFpbmVybGFiIGRlcGxveSAtdCByb3V0ZWQuY2xhYi55bWwgLS1yZWNvbmZpZ3VyZSA+L2Rldi9udWxsICYmIGJhc2ggcm91dGVkLXNldHVwLnNoID4vZGV2L251bGwKZG9ja2VyIGV4ZWMgY2xhYi1wMXItcjEgdnR5c2ggLWMgJ2NvbmYgdCcgLWMgJ2lwIHJvdXRlIDE3Mi4xNi4yLjAvMjQgMTAuMC4xMi4yJyA+L2Rldi9udWxsCmRvY2tlciBleGVjIGNsYWItcDFyLXIyIHZ0eXNoIC1jICdjb25mIHQnIC1jICdpcCByb3V0ZSAxNzIuMTYuMS4wLzI0IDEwLjAuMTIuMScgPi9kZXYvbnVsbAojIC0tLSB0aGUgZmF1bHQgLS0tCmRvY2tlciBleGVjIGNsYWItcDFyLXIxIHZ0eXNoIC1jICdjb25mIHQnIC1jICdpcCByb3V0ZSAwLjAuMC4wLzAgMTAuMC4xMi4yJyA+L2Rldi9udWxsCmRvY2tlciBleGVjIGNsYWItcDFyLXIyIHZ0eXNoIC1jICdjb25mIHQnIC1jICdpcCByb3V0ZSAwLjAuMC4wLzAgMTAuMC4xMi4xJyA+L2Rldi9udWxsCmNhdCA8PCdUJwoKVElDS0VUICAiV2UgYWRkZWQgZGVmYXVsdCByb3V0ZXMgb24gYm90aCByb3V0ZXJzIHNvICdldmVyeXRoaW5nIGlzIHJlYWNoYWJsZScuIgogICAgICAgIE5vdyBoMSDihpIgMTcyLjE2Ljk5LjEwIChhIG5ldHdvcmsgdGhhdCBkb2Vzbid0IGV4aXN0IHlldCkgZ2l2ZXM6CiAgICAgICAgICBkb2NrZXIgZXhlYyBjbGFiLXAxci1oMSBwaW5nIC1jMSAxNzIuMTYuOTkuMTAKICAgICAgICAgIOKGkiAiVGltZSB0byBsaXZlIGV4Y2VlZGVkIgogICAgICAgIGFuZCB0aGUgcm91dGVycycgQ1BVIGdyYXBocyBzcGlrZSB3aGVuZXZlciBzb21lb25lIHR5cG9zIGFuIGFkZHJlc3MuClQK'
base64 -d <<<"$P" | bash -s -- "$@"
