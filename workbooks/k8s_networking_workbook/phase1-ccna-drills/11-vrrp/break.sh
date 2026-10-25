#!/usr/bin/env bash
# Lab 1.11 — break/fix injector.
# Run: netlab-a, as root:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKIyAtLS0gdGhlIGZhdWx0OiB2QiBqb2luZWQgd2l0aCBhIGRpZmZlcmVudCBWUlJQIGdyb3VwIGlkLCBhbmQgd2FzIG5ldmVyIGZpbmlzaGVkIC0tLQpiYXNoICIkTEFCX0RJUi90b3BvLnNoIiB1cCA1MiA+L2Rldi9udWxsCmlwIC1uIHZCIHJvdXRlIGRlbCAxMC45MS4wLjEwLzMyIDI+L2Rldi9udWxsIHx8IHRydWUKY2F0IDw8J1QnCgpUSUNLRVQgIEhvc3RzIG9uIDEwLjkwLjAuMC8yNCByZXBvcnQgYSBmbGFreSBnYXRld2F5OiBjb25uZWN0aW9ucyB0byB0aGUKICAgICAgICBzZXJ2ZXIgKDEwLjkxLjAuMTApIHN0YWxsIGZvciBzZXZlcmFsIHNlY29uZHMsIHRoZW4gcmVjb3ZlciwgdGhlbgogICAgICAgIHN0YWxsIGFnYWluLgogICAgICAgICAgaXAgbmV0bnMgZXhlYyB2aCBwaW5nIC1jNDAgLWkwLjI1IDEwLjkxLjAuMTAKICAgICAgICAiV2UgYWRkZWQgYSBzZWNvbmQgcm91dGVyICh2QikgZm9yIHJlZHVuZGFuY3kgbGFzdCB3ZWVrLiIKVAo='
base64 -d <<<"$P" | bash -s -- "$@"
