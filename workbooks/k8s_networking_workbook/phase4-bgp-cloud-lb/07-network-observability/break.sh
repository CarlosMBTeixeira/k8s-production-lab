#!/usr/bin/env bash
# Lab 4.07 — break/fix injector.
# Run: WSL host, k8slab up with option 3 (observability)
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKZXhwb3J0IEtVQkVDT05GSUc9IiRXQl9ESVIvLi4vLi4va3ViZXJuZXRlcy9hZG1pbi5jb25mIgprdWJlY3RsIGdldCBjcmQgcHJvbWV0aGV1c3J1bGVzLm1vbml0b3JpbmcuY29yZW9zLmNvbSA+L2Rldi9udWxsIHx8IHsgZWNobyAia3ViZS1wcm9tZXRoZXVzLXN0YWNrIG5vdCBpbnN0YWxsZWQgKHBpcGVsaW5lIG9wdGlvbiAzKSI7IGV4aXQgMTsgfQprdWJlY3RsIGRlbGV0ZSBucyBsYWItbmV0b2JzIC0taWdub3JlLW5vdC1mb3VuZCAtLXdhaXQ9dHJ1ZSA+L2Rldi9udWxsCiMgLS0tIHRoZSBmYXVsdDogdGhlIHJ1bGUgImZyb20gdGhlIHRlYW0ncyByZXBvIiwgd2l0aG91dCB0aGUgc2VsZWN0b3IgbGFiZWwgLS0tCnNlZCAnL2xhYmVsczoge3JlbGVhc2U6IGt1YmUtcHJvbWV0aGV1cy1zdGFja30vZCcgIiRMQUJfRElSL3J1bGVzLnlhbWwiIHwga3ViZWN0bCBhcHBseSAtZiAtID4vZGV2L251bGwKY2F0IDw8J1QnCgpUSUNLRVQgIFBvc3QtaW5jaWRlbnQgcmV2aWV3OiB3b3JrZXItMidzIGNvbm50cmFjayB0YWJsZSB3YXMgZnVsbCBmb3IgMwogICAgICAgIG1pbnV0ZXMgdGhpcyBtb3JuaW5nIChzaW11bGF0ZSBpdDogbGFiIDMuMDYncyBjdC1leGhhdXN0LnNoIHN0YXJ0KS4KICAgICAgICBXZSBoYXZlIGFuIGFsZXJ0IGZvciBleGFjdGx5IHRoYXQg4oCUIE5vZGVDb25udHJhY2tIaWdoIGluCiAgICAgICAgbGFiLW5ldG9icy9sYWItbmV0d29yayDigJQgYW5kIGl0IG5ldmVyIGZpcmVkLiBOb2JvZHkgZ290IHBhZ2VkLgogICAgICAgICJrdWJlY3RsIGdldCBwcm9tZXRoZXVzcnVsZSAtbiBsYWItbmV0b2JzIiBzaG93cyBpdCdzIHRoZXJlLgpUCg=='
base64 -d <<<"$P" | bash -s -- "$@"
