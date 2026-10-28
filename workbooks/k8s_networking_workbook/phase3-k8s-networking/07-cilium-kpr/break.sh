#!/usr/bin/env bash
# Lab 3.07 — break/fix injector.
# Run: WSL host, kind cluster lab-cilium up with Cilium installed (unset KUBECONFIG first)
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKZXhwb3J0IEtVQkVDT05GSUc9IiRIT01FLy5rdWJlL2NvbmZpZyIKSz0ia3ViZWN0bCAtLWNvbnRleHQga2luZC1sYWItY2lsaXVtIjsgQ0k9ImNpbGl1bSAtLWNvbnRleHQga2luZC1sYWItY2lsaXVtIgokQ0kgc3RhdHVzID4vZGV2L251bGwgMj4mMSB8fCB7IGVjaG8gIkNpbGl1bSBub3QgaGVhbHRoeSBvbiBsYWItY2lsaXVtIOKAlCBmaW5pc2ggwqcyLjEgZmlyc3QiOyBleGl0IDE7IH0KJEsgYXBwbHkgLWYgIiRMQUJfRElSL3dlYi55YW1sIiA+L2Rldi9udWxsCiRLIC1uIGxhYi1jaWwgcm9sbG91dCBzdGF0dXMgZGVwbG95L3dlYiAtLXRpbWVvdXQ9MTIwcyA+L2Rldi9udWxsCiRLIC1uIGxhYi1jaWwgd2FpdCAtLWZvcj1jb25kaXRpb249UmVhZHkgcG9kL2NsaWVudCAtLXRpbWVvdXQ9MTIwcyA+L2Rldi9udWxsCiMgLS0tIHRoZSBmYXVsdCAtLS0KJENJIGNvbmZpZyBzZXQga3ViZS1wcm94eS1yZXBsYWNlbWVudCBmYWxzZSA+L2Rldi9udWxsCiRDSSBzdGF0dXMgLS13YWl0ID4vZGV2L251bGwgMj4mMSB8fCB0cnVlCnNsZWVwIDEwCmNhdCA8PCdUJwoKVElDS0VUICBBZnRlciAiYSBjb25maWcgY2xlYW51cCIgb24gbGFiLWNpbGl1bToKICAgICAgICAgIGN1cmwgLW0zIGh0dHA6Ly88YW55IG5vZGUgSVA+OjMwMDgwICAgICAgICDihpIgZmFpbHMgKGZyb20gdGhlIFdTTCBob3N0KSwgZXZlcnkgbm9kZQogICAgICAgIEluc2lkZSB0aGUgY2x1c3RlciBldmVyeXRoaW5nIGxvb2tzIGZpbmU6IHRoZSBjbGllbnQgcG9kIHJlYWNoZXMKICAgICAgICB3ZWIgYnkgbmFtZSwgd2ViIHBvZHMgYW5zd2VyIG9uIHRoZWlyIElQcywgYWxsIENpbGl1bSBwb2RzIGFyZQogICAgICAgIFJ1bm5pbmcuICJXZSBvbmx5IHJlbW92ZWQgc2V0dGluZ3Mgd2UgZGlkbid0IHJlY29nbmlzZS4iClQK'
base64 -d <<<"$P" | bash -s -- "$@"
