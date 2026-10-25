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
P='c2V0IC1ldW8gcGlwZWZhaWwKY2QgIiRMQUJfRElSIgpjb250YWluZXJsYWIgZGVzdHJveSAtdCB0b3BvLmNsYWIueW1sIC0tY2xlYW51cCA+L2Rldi9udWxsIDI+JjEgfHwgdHJ1ZQojIC0tLSB0aGUgZmF1bHQ6IHRoZSAibWlncmF0ZWQiIG9uLXByZW0gcmVzb2x2ZXIgY29uZmlnIC0tLQpjYXQgPiBkbnNvL0NvcmVmaWxlIDw8J0NPUkVGSUxFJwojIE9uLXByZW0gcmVzb2x2ZXIgKDE3Mi4yMC4yLjUzKSDigJQgbWlncmF0ZWQgdG8gdGhlIG5ldyBETlMgcGxhdGZvcm0uCmNvcnAubGFiOjUzIHsKICAgIGhvc3RzIHsKICAgICAgICAxNzIuMjAuMS4xMCBhcHAuY29ycC5sYWIKICAgIH0KICAgIGxvZwp9Ci46NTMgewogICAgaG9zdHMgewogICAgICAgIDIwMy4wLjExMy4xMCBzdG9yYWdlLnByaXZhdGVsaW5rLmxhYgogICAgICAgIGZhbGx0aHJvdWdoCiAgICB9CiAgICBsb2cKfQpDT1JFRklMRQpjb250YWluZXJsYWIgZGVwbG95IC10IHRvcG8uY2xhYi55bWwgPi9kZXYvbnVsbApiYXNoIHBvc3QtZGVwbG95LnNoID4vZGV2L251bGwKc2xlZXAgNQpjYXQgPDwnVCcKClRJQ0tFVCAgQWZ0ZXIgbGFzdCBuaWdodCdzIEROUyBzZXJ2ZXIgbWlncmF0aW9uIG9uLXByZW0sIHRoZSBvbi1wcmVtIGFwcAogICAgICAgIChvMSkgY2FuJ3QgcmVhY2ggdGhlIHN0b3JhZ2UgYWNjb3VudCB0aHJvdWdoIGl0cyBwcml2YXRlIGVuZHBvaW50OgogICAgICAgICAgZG9ja2VyIGV4ZWMgY2xhYi1jbG91ZC1vMSBjdXJsIC1tNSBodHRwOi8vc3RvcmFnZS5wcml2YXRlbGluay5sYWIgICDihpIgdGltZW91dAogICAgICAgIEZyb20gVlBDLUEgKGExKSB0aGUgc2FtZSBVUkwgd29ya3MuIFJvdXRpbmcgYmV0d2VlbiBvbi1wcmVtIGFuZAogICAgICAgIFZQQy1BIGlzIGZpbmUgKG8xIHBpbmdzIDEwLjEwLjMuMTApLgpUCg=='
base64 -d <<<"$P" | bash -s -- "$@"
