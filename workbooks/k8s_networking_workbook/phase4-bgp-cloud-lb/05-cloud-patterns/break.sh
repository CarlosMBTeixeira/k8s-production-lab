#!/usr/bin/env bash
# Lab 4.05 — break/fix injector.
# Run: netlab-c, as root, from your local copy (~/p4/05-cloud-patterns):  bash break.sh
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKY2QgIiRMQUJfRElSIgpjb250YWluZXJsYWIgZGVzdHJveSAtdCB0b3BvLmNsYWIueW1sIC0tY2xlYW51cCA+L2Rldi9udWxsIDI+JjEgfHwgdHJ1ZQojIC0tLSB0aGUgZmF1bHQ6IHRoZSAibWlncmF0ZWQiIG9uLXByZW0gcmVzb2x2ZXIgY29uZmlnIC0tLQpjYXQgPiBkbnNvL0NvcmVmaWxlIDw8J0NPUkVGSUxFJwojIE9uLXByZW0gcmVzb2x2ZXIgKDE3Mi4yMC4yLjUzKSDigJQgbWlncmF0ZWQgdG8gdGhlIG5ldyBETlMgcGxhdGZvcm0uCmNvcnAubGFiOjUzIHsKICAgIGhvc3RzIHsKICAgICAgICAxNzIuMjAuMS4xMCBhcHAuY29ycC5sYWIKICAgIH0KICAgIGxvZwp9Ci46NTMgewogICAgaG9zdHMgewogICAgICAgIDIwMy4wLjExMy4xMCBzdG9yYWdlLnByaXZhdGVsaW5rLmxhYgogICAgICAgIGZhbGx0aHJvdWdoCiAgICB9CiAgICBsb2cKfQpDT1JFRklMRQpjb250YWluZXJsYWIgZGVwbG95IC10IHRvcG8uY2xhYi55bWwgPi9kZXYvbnVsbCAyPiYxCmJhc2ggcG9zdC1kZXBsb3kuc2ggPi9kZXYvbnVsbApzbGVlcCA1CmNhdCA8PCdUJwoKVElDS0VUICBBZnRlciBsYXN0IG5pZ2h0J3MgRE5TIHNlcnZlciBtaWdyYXRpb24gb24tcHJlbSwgdGhlIG9uLXByZW0gYXBwCiAgICAgICAgKG8xKSBjYW4ndCByZWFjaCB0aGUgc3RvcmFnZSBhY2NvdW50IHRocm91Z2ggaXRzIHByaXZhdGUgZW5kcG9pbnQ6CiAgICAgICAgICBkb2NrZXIgZXhlYyBjbGFiLWNsb3VkLW8xIGN1cmwgLXNTIC1tNSBodHRwOi8vc3RvcmFnZS5wcml2YXRlbGluay5sYWIKICAgICAgICAgICAg4oaSIGN1cmw6ICg3KSBGYWlsZWQgdG8gY29ubmVjdCB0byBzdG9yYWdlLnByaXZhdGVsaW5rLmxhYiBwb3J0IDgwIOKApiBDb3VsZG4ndCBjb25uZWN0IHRvIHNlcnZlcgogICAgICAgIEZyb20gVlBDLUEgKGExKSB0aGUgc2FtZSBVUkwgd29ya3MuIFJvdXRpbmcgYmV0d2VlbiBvbi1wcmVtIGFuZAogICAgICAgIFZQQy1BIGlzIGZpbmUgKG8xIHBpbmdzIDEwLjEwLjMuMTApLgpUCg=='
base64 -d <<<"$P" | bash -s -- "$@"
