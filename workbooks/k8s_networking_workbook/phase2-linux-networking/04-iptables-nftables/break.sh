#!/usr/bin/env bash
# Lab 2.04 — break/fix injector.
# Run: netlab-a, as root:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKYmFzaCAiJFBIQVNFX0RJUi9saWIvdG9wby1jcnMuc2giIHVwCmJhc2ggIiRQSEFTRV9ESVIvbGliL3RvcG8tY3JzLnNoIiBzZXJ2ZQpSPSdpcCBuZXRucyBleGVjIHJvdXRlcicKJFIgaXB0YWJsZXMgLUEgRk9SV0FSRCAtcCB0Y3AgLS1kcG9ydCA4MDgwIC1qIEFDQ0VQVAokUiBpcHRhYmxlcyAtQSBGT1JXQVJEIC1wIGljbXAgLWogQUNDRVBUCiMgLS0tIHRoZSBmYXVsdCAtLS0KJFIgbmZ0IGFkZCB0YWJsZSBpbmV0IGVkZ2UKJFIgbmZ0IGFkZCBjaGFpbiBpbmV0IGVkZ2UgcHJlICd7IHR5cGUgZmlsdGVyIGhvb2sgcHJlcm91dGluZyBwcmlvcml0eSAtMTUwOyBwb2xpY3kgYWNjZXB0OyB9JwokUiBuZnQgYWRkIHJ1bGUgaW5ldCBlZGdlIHByZSAndGNwIGRwb3J0IDgwODAgdGNwIGZsYWdzICYgKHN5bnxhY2spID09IHN5biBkcm9wJwpjYXQgPDwnVCcKClRJQ0tFVCAgY2xpZW50IOKGkiBodHRwOi8vMTAuMi4yLjI6ODA4MCBoYW5ncy4gUGluZyAxMC4yLjIuMiB3b3Jrcy4KICAgICAgICBUaGUgbmV0d29yayB0ZWFtIGNoZWNrZWQgdGhlIHJvdXRlcjoKICAgICAgICAgIGlwIG5ldG5zIGV4ZWMgcm91dGVyIGlwdGFibGVzIC1MIC12IC1uICAgICAgICDihpIgQUNDRVBUIDgwODAsIEFDQ0VQVCBpY21wCiAgICAgICAgICBpcCBuZXRucyBleGVjIHJvdXRlciBpcHRhYmxlcyAtdCBtYW5nbGUgLUwgICAg4oaSIGVtcHR5CiAgICAgICAgIlRoZSBmaXJld2FsbCBpcyBvcGVuLiBNdXN0IGJlIHRoZSBhcHAuIgpUCg=='
base64 -d <<<"$P" | bash -s -- "$@"
