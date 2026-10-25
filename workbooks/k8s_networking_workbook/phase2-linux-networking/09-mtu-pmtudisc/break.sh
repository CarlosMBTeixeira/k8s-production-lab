#!/usr/bin/env bash
# Lab 2.09 — break/fix injector.
# Run: netlab-a, as root:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKYmFzaCAiJExBQl9ESVIvdG9wby5zaCIgdXAKYmFzaCAiJExBQl9ESVIvdG9wby5zaCIgc2VydmUKIyAtLS0gdGhlIGZhdWx0IC0tLQppcCAtbiBtcjIgbGluayBzZXQgcjItdyBtdHUgMTUwMAppcCBuZXRucyBleGVjIG1zIGV0aHRvb2wgLUsgZXRoMCB0c28gb2ZmIGdzbyBvZmYgPi9kZXYvbnVsbCAyPiYxIHx8IHRydWUKY2F0IDw8J1QnCgpUSUNLRVQgIFNpbmNlIHRoZSBXQU4gbWFpbnRlbmFuY2UgbGFzdCBuaWdodCwgZG93bmxvYWRzIG9mCiAgICAgICAgaHR0cDovLzEwLjIuMi4yOjgwODAvYmlnLmJpbiBmcm9tIHRoZSBjbGllbnQgKDEwLjEuMS4yKSBoYW5nIGFmdGVyCiAgICAgICAgdGhlIHJlc3BvbnNlIHN0YXJ0cy4gU21hbGwgcGFnZXMgd29yay4gVGhlcmUgYXJlIG5vIGZpcmV3YWxsIHJ1bGVzCiAgICAgICAgb24gZWl0aGVyIHJvdXRlciAoY2hlY2s6IG5mdCBsaXN0IHJ1bGVzZXQgaXMgZW1wdHkpLiBObyBJQ01QIGVycm9ycwogICAgICAgIGFueXdoZXJlLgpUCg=='
base64 -d <<<"$P" | bash -s -- "$@"
