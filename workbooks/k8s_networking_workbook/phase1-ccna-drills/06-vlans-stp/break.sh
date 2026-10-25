#!/usr/bin/env bash
# Lab 1.06 — break/fix injector.
# Run: netlab-c, root, in your local copy (~/wb/phase1-ccna-drills/06-vlans-stp):  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKY2QgIiRQSEFTRV9ESVIvdG9wbyIKY29udGFpbmVybGFiIGRlcGxveSAtdCBsYW4uY2xhYi55bWwgLS1yZWNvbmZpZ3VyZSA+L2Rldi9udWxsICYmIGJhc2ggbGFuLXNldHVwLnNoID4vZGV2L251bGwKYmFzaCAiJExBQl9ESVIvdmxhbnMuc2giID4vZGV2L251bGwKIyAtLS0gdGhlIGZhdWx0IC0tLQpkb2NrZXIgZXhlYyBjbGFiLXAxbC1zdzIgYnJpZGdlIHZsYW4gZGVsIGRldiBldGgzIHZpZCAyMApjYXQgPDwnVCcKClRJQ0tFVCAgQWZ0ZXIgbWFpbnRlbmFuY2Ugb24gc3cyLCBoMiAoMTAuMC4yMC4yKSBjYW4ndCByZWFjaCBoNCAoMTAuMC4yMC40KS4KICAgICAgICBCb3RoIGFyZSBpbiBWTEFOIDIwLiBWTEFOIDEwIChoMSDihpQgaDMpIHdvcmtzIGFjcm9zcyB0aGUgc2FtZQogICAgICAgIHN3aXRjaGVzLiBoMiBjYW4gcGluZyBpdHMgZ2F0ZXdheSAxMC4wLjIwLjI1NC4KVAo='
base64 -d <<<"$P" | bash -s -- "$@"
