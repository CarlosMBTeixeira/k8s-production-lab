#!/usr/bin/env bash
# Lab 1.05 — break/fix injector.
# Run: netlab-c, root, in your local copy (~/wb/phase1-ccna-drills/05-static-routing):  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKY2QgIiRQSEFTRV9ESVIvdG9wbyIKY29udGFpbmVybGFiIGRlcGxveSAtdCByb3V0ZWQuY2xhYi55bWwgLS1yZWNvbmZpZ3VyZSA+L2Rldi9udWxsICYmIGJhc2ggcm91dGVkLXNldHVwLnNoID4vZGV2L251bGwKYygpIHsgZG9ja2VyIGV4ZWMgY2xhYi1wMXItJDEgdnR5c2ggLWMgJ2NvbmYgdCcgLWMgIiQyIiA+L2Rldi9udWxsOyB9CmMgcjEgJ2lwIHJvdXRlIDE3Mi4xNi4yLjAvMjQgMTAuMC4xMi4yJwpjIHIyICdpcCByb3V0ZSAxNzIuMTYuMS4wLzI0IDEwLjAuMTIuMScKIyAtLS0gdGhlIGZhdWx0IC0tLQpjIHIxICdpcCByb3V0ZSAxNzIuMTYuMi4wLzI1IDEwLjAuMTMuMycKY2F0IDw8J1QnCgpUSUNLRVQgIGgxIGNhbid0IHJlYWNoIGgyICgxNzIuMTYuMi4xMCkgc2luY2UgdGhpcyBtb3JuaW5nLiByMSdzCiAgICAgICAgInNob3cgaXAgcm91dGUiIGNsZWFybHkgbGlzdHMgMTcyLjE2LjIuMC8yNCB2aWEgMTAuMC4xMi4yLCBhbmQKICAgICAgICByMiBoYXMgdGhlIHJvdXRlIGJhY2suICJXZSBvbmx5IGFkZGVkIGEgcm91dGUgZm9yIHRoZSBuZXcKICAgICAgICBzZXJ2ZXJzIGNvbWluZyBuZXh0IG1vbnRoLiIKVAo='
base64 -d <<<"$P" | bash -s -- "$@"
