#!/usr/bin/env bash
# Lab 2.11 — break/fix injector.
# Run: netlab-a, as root:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKYmFzaCAiJFBIQVNFX0RJUi9saWIvdG9wby1jcnMuc2giIHVwCmJhc2ggIiRQSEFTRV9ESVIvbGliL3RvcG8tY3JzLnNoIiBzZXJ2ZQptb2Rwcm9iZSBjbHNfZmxvd2VyIDI+L2Rldi9udWxsIHx8IHRydWUKIyAtLS0gdGhlIGZhdWx0IC0tLQppcCBuZXRucyBleGVjIHJvdXRlciB0YyBxZGlzYyBhZGQgZGV2IHItczEgY2xzYWN0CmlwIG5ldG5zIGV4ZWMgcm91dGVyIHRjIGZpbHRlciBhZGQgZGV2IHItczEgZWdyZXNzIHByb3RvY29sIGlwIGZsb3dlciBpcF9wcm90byB0Y3AgZHN0X3BvcnQgODA4MCBhY3Rpb24gZHJvcApjYXQgPDwnVCcKClRJQ0tFVCAgY2xpZW50IOKGkiBodHRwOi8vMTAuMi4yLjI6ODA4MCBoYW5nczsgcGluZyAxMC4yLjIuMiB3b3Jrcy4KICAgICAgICBPbiB0aGUgcm91dGVyOiBgbmZ0IGxpc3QgcnVsZXNldGAgaXMgZW1wdHksIGlwdGFibGVzIGlzIGVtcHR5LgogICAgICAgIHRjcGR1bXAgb24gci1jIHNob3dzIHRoZSBjbGllbnQncyBTWU5zIGFycml2aW5nLgogICAgICAgIHRjcGR1bXAgb24gci1zMSBzaG93cyBub3RoaW5nIGxlYXZpbmcgdG93YXJkIHRoZSBzZXJ2ZXIuCiAgICAgICAgIlRoZSByb3V0ZXIgaXMgZWF0aW5nIHBhY2tldHMgYW5kIHRoZXJlJ3Mgbm8gcnVsZSBmb3IgaXQuIgpUCg=='
base64 -d <<<"$P" | bash -s -- "$@"
