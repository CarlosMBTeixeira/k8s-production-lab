#!/usr/bin/env bash
# Lab 3.01 — break/fix injector.
# Run: WSL host, k8slab up (2 workers). RISKY: adds an nftables table on worker-2.
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKZXhwb3J0IEtVQkVDT05GSUc9IiRXQl9ESVIvLi4vLi4va3ViZXJuZXRlcy9hZG1pbi5jb25mIgprdWJlY3RsIGFwcGx5IC1mICIkTEFCX0RJUi9wb2RzLnlhbWwiID4vZGV2L251bGwKa3ViZWN0bCAtbiBsYWItYW5hdG9teSB3YWl0IC0tZm9yPWNvbmRpdGlvbj1SZWFkeSBwb2QgLS1hbGwgLS10aW1lb3V0PTEyMHMgPi9kZXYvbnVsbAojIC0tLSB0aGUgZmF1bHQgLS0tCnNzaCB3LTIgInN1ZG8gbmZ0IGRlbGV0ZSB0YWJsZSBpbmV0IGxhYi1mdyAyPi9kZXYvbnVsbDsgXAogIHN1ZG8gbmZ0IGFkZCB0YWJsZSBpbmV0IGxhYi1mdyAmJiBcCiAgc3VkbyBuZnQgYWRkIGNoYWluIGluZXQgbGFiLWZ3IHByZSAneyB0eXBlIGZpbHRlciBob29rIHByZXJvdXRpbmcgcHJpb3JpdHkgLTMwMDsgcG9saWN5IGFjY2VwdDsgfScgJiYgXAogIHN1ZG8gbmZ0IGFkZCBydWxlIGluZXQgbGFiLWZ3IHByZSBpcCBwcm90b2NvbCA0IGRyb3AiCmNhdCA8PCdUJwoKVElDS0VUICBQb2RzIG9uIHdvcmtlci0yIHN0b3BwZWQgYW5zd2VyaW5nIGFueXRoaW5nIGZyb20gb3RoZXIgbm9kZXMgYWZ0ZXIKICAgICAgICAidGhlIHNlY3VyaXR5IHRlYW0gcm9sbGVkIG91dCB0aGUgbm9kZSBmaXJld2FsbCBiYXNlbGluZSIuCiAgICAgICAgICBrdWJlY3RsIC1uIGxhYi1hbmF0b215IGV4ZWMgY2xpZW50IC0tIGN1cmwgLW0zIDxzZXJ2ZXItcmVtb3RlIElQPiAgIOKGkiB0aW1lb3V0CiAgICAgICAgU2FtZS1ub2RlIHRyYWZmaWMgaXMgZmluZTsgd29ya2VyLTEgYW5kIHdvcmtlci0yIHBpbmcgZWFjaCBvdGhlcjsKICAgICAgICBldmVyeSBjYWxpY28tbm9kZSBwb2QgaXMgUnVubmluZyBhbmQgUmVhZHkuClQK'
base64 -d <<<"$P" | bash -s -- "$@"
