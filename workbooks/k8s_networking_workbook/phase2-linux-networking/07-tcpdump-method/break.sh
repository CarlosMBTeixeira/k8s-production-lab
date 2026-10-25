#!/usr/bin/env bash
# Lab 2.07 — break/fix injector.
# Run: netlab-a, as root:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKYmFzaCAiJFBIQVNFX0RJUi9saWIvdG9wby1jcnMuc2giIHVwCmJhc2ggIiRQSEFTRV9ESVIvbGliL3RvcG8tY3JzLnNoIiBzZXJ2ZQptb2Rwcm9iZSBzY2hfbmV0ZW0gMj4vZGV2L251bGwgfHwgdHJ1ZQpSPSdpcCBuZXRucyBleGVjIHJvdXRlcicKIyAtLS0gdGhlIGZhdWx0IC0tLQokUiB0YyBxZGlzYyBhZGQgZGV2IHItYyByb290IGhhbmRsZSAxOiBwcmlvCiRSIHRjIHFkaXNjIGFkZCBkZXYgci1jIHBhcmVudCAxOjMgaGFuZGxlIDMwOiBuZXRlbSBkZWxheSAyMG1zIGxvc3MgMyUKJFIgdGMgZmlsdGVyIGFkZCBkZXYgci1jIHBhcmVudCAxOjAgcHJvdG9jb2wgaXAgcHJpbyAxIHUzMiBcCiAgICBtYXRjaCBpcCBwcm90b2NvbCA2IDB4ZmYgbWF0Y2ggaXAgc3BvcnQgODA4MCAweGZmZmYgZmxvd2lkIDE6MwpjYXQgPDwnVCcKClRJQ0tFVCAgRG93bmxvYWRpbmcgaHR0cDovLzEwLjIuMi4yOjgwODAvYmlnLmJpbiAoMjAgTUIpIGZyb20gdGhlIGNsaWVudCB0YWtlcwogICAgICAgIGFnZXMg4oCUIGEgZmV3IGh1bmRyZWQgS0Ivcy4gaW5kZXguaHRtbCBsb2FkcyBpbnN0YW50bHkuIFBpbmcgaXMgY2xlYW4KICAgICAgICAoc3ViLW1pbGxpc2Vjb25kLCAwJSBsb3NzKS4gVGhlIHJvdXRlciBoYXMgbm8gaXB0YWJsZXMgb3IgbmZ0IHJ1bGVzLgogICAgICAgIE1lYXN1cmU6ICBpcCBuZXRucyBleGVjIGNsaWVudCBjdXJsIC1zIC1vIC9kZXYvbnVsbCAtdyAnJXtzcGVlZF9kb3dubG9hZH1cbicgMTAuMi4yLjI6ODA4MC9iaWcuYmluClQK'
base64 -d <<<"$P" | bash -s -- "$@"
