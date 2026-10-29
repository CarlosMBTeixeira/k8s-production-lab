#!/usr/bin/env bash
# Lab 2.01 — break/fix injector.
# Run: netlab-a, as root:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKZm9yIG4gaW4gcmVkIGJsdWU7IGRvCiAgICBpcCBuZXRucyBwaWRzICIkbiIgMj4vZGV2L251bGwgfCB4YXJncyAtciBraWxsIDI+L2Rldi9udWxsIHx8IHRydWUKICAgIGlwIG5ldG5zIGRlbCAiJG4iIDI+L2Rldi9udWxsIHx8IHRydWUKZG9uZQppcCBuZXRucyBhZGQgcmVkOyBpcCBuZXRucyBhZGQgYmx1ZQppcCBsaW5rIGFkZCB2ZXRoLXJlZCBuZXRucyByZWQgdHlwZSB2ZXRoIHBlZXIgbmFtZSB2ZXRoLWJsdWUgbmV0bnMgYmx1ZQppcCAtbiByZWQgIGFkZHIgYWRkIDEwLjAuMC4xLzI0IGRldiB2ZXRoLXJlZAppcCAtbiBibHVlIGFkZHIgYWRkIDEwLjAuMC4yLzI0IGRldiB2ZXRoLWJsdWUKZm9yIG4gaW4gcmVkIGJsdWU7IGRvIGlwIC1uICIkbiIgbGluayBzZXQgbG8gdXA7IGRvbmUKaXAgLW4gcmVkICBsaW5rIHNldCB2ZXRoLXJlZCB1cAppcCAtbiBibHVlIGxpbmsgc2V0IHZldGgtYmx1ZSB1cAojIC0tLSB0aGUgZmF1bHQgLS0tCmlwIC1uIGJsdWUgbGluayBzZXQgdmV0aC1ibHVlIGFycCBvZmYKY2F0IDw8J1QnCgpUSUNLRVQgIEZyb20gbmFtZXNwYWNlIHJlZCwgYHBpbmcgMTAuMC4wLjJgIGZhaWxzOgogICAgICAgICJGcm9tIDEwLjAuMC4xIGljbXBfc2VxPTEgRGVzdGluYXRpb24gSG9zdCBVbnJlYWNoYWJsZSIuCiAgICAgICAgQWRkcmVzc2VzIGFyZSAxMC4wLjAuMS8yNCAocmVkKSBhbmQgMTAuMC4wLjIvMjQgKGJsdWUpLCBib3RoIGxpbmtzIFVQLgogICAgICAgIFRoZSBvd25lciBvZiBibHVlIHNheXMgIkkgb25seSByYW4gYSBoYXJkZW5pbmcgc2NyaXB0Ii4KVAo='
base64 -d <<<"$P" | bash -s -- "$@"
