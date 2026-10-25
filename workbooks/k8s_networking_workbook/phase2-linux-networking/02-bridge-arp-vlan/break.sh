#!/usr/bin/env bash
# Lab 2.02 — break/fix injector.
# Run: netlab-a, as root:  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKZm9yIGkgaW4gMSAyIDM7IGRvIGlwIG5ldG5zIGRlbCBucyRpIDI+L2Rldi9udWxsIHx8IHRydWU7IGRvbmUKaXAgbGluayBkZWwgYnIwIDI+L2Rldi9udWxsIHx8IHRydWUKaXAgbGluayBhZGQgYnIwIHR5cGUgYnJpZGdlCmlwIGxpbmsgc2V0IGJyMCB1cApmb3IgaSBpbiAxIDIgMzsgZG8KICBpcCBuZXRucyBhZGQgbnMkaQogIGlwIGxpbmsgYWRkIHYkaSB0eXBlIHZldGggcGVlciBuYW1lIGV0aDAgbmV0bnMgbnMkaQogIGlwIGxpbmsgc2V0IHYkaSBtYXN0ZXIgYnIwIHVwCiAgaXAgLW4gbnMkaSBhZGRyIGFkZCAxMC4wLjEwLiRpLzI0IGRldiBldGgwCiAgaXAgLW4gbnMkaSBsaW5rIHNldCBldGgwIHVwCiAgaXAgLW4gbnMkaSBsaW5rIHNldCBsbyB1cApkb25lCiMgLS0tIHRoZSBmYXVsdCAtLS0KYnJpZGdlIGxpbmsgc2V0IGRldiB2MiBsZWFybmluZyBvZmYgZmxvb2Qgb2ZmCmlwIGxpbmsgc2V0IHYyIHR5cGUgYnJpZGdlX3NsYXZlIGZkYl9mbHVzaCAgICMgZHJvcCB3aGF0IHYyIGxlYXJuZWQgZnJvbSBuczIncyBJUHY2IERBRC9NTEQgYXQgbGluay11cApjYXQgPDwnVCcKClRJQ0tFVCAgbnMxIGFuZCBuczMgdGFsayBmaW5lLiBOb2JvZHkgY2FuIHJlYWNoIG5zMiAoMTAuMC4xMC4yKS4KICAgICAgICAiSXQncyBub3QgQVJQIOKAlCBgaXAgbmVpZ2hgIG9uIG5zMSBzaG93cyBuczIncyBNQUMgYXMgUkVBQ0hBQkxFLiIKICAgICAgICBuczIncyBpbnRlcmZhY2UgaXMgVVAgd2l0aCB0aGUgcmlnaHQgYWRkcmVzcy4KVAo='
base64 -d <<<"$P" | bash -s -- "$@"
