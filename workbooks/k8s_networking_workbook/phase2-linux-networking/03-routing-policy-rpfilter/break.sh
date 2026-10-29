#!/usr/bin/env bash
# Lab 2.03 — break/fix injector.
# Run: netlab-a, as root:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKYmFzaCAiJFBIQVNFX0RJUi9saWIvdG9wby1jcnMuc2giIHVwCmJhc2ggIiRQSEFTRV9ESVIvbGliL3RvcG8tY3JzLnNoIiBzZXJ2ZQojIC0tLSB0aGUgZmF1bHQgLS0tCmlwIC1uIHJvdXRlciBydWxlIGFkZCBmcm9tIDEwLjEuMS4wLzI0IGxvb2t1cCAyMDAgcHJpb3JpdHkgMTAwMAppcCAtbiByb3V0ZXIgcm91dGUgYWRkIGJsYWNraG9sZSAxMC4yLjIuMC8yNCB0YWJsZSAyMDAKY2F0IDw8J1QnCgpUSUNLRVQgIFRoZSBjbGllbnQgKDEwLjEuMS4yKSBjYW4ndCByZWFjaCB0aGUgd2ViIHNlcnZpY2Ugb24gMTAuMi4yLjI6ODA4MCDigJQKICAgICAgICBjdXJsIGhhbmdzLiBGcm9tIHRoZSByb3V0ZXIgaXRzZWxmLCBgY3VybCAxMC4yLjIuMjo4MDgwYCB3b3Jrcy4KICAgICAgICBgaXAgcm91dGVgIG9uIHRoZSByb3V0ZXIgc2hvd3MgMTAuMi4yLjAvMjQgZGV2IHItczEsIGFzIGFsd2F5cy4KICAgICAgICAxMC4zLjMuMiBpcyByZWFjaGFibGUgZnJvbSB0aGUgY2xpZW50LgpUCg=='
base64 -d <<<"$P" | bash -s -- "$@"
