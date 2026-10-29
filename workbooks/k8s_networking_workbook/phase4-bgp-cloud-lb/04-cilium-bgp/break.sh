#!/usr/bin/env bash
# Lab 4.04 — break/fix injector.
# Run: WSL host, kind lab-cilium with Cilium BGP set up as in §2.1 (unset KUBECONFIG first)
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. The plaintext and the fix are in solution.md — open it last.
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/.." && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='c2V0IC1ldW8gcGlwZWZhaWwKZXhwb3J0IEtVQkVDT05GSUc9IiRIT01FLy5rdWJlL2NvbmZpZyIKSz0ia3ViZWN0bCAtLWNvbnRleHQga2luZC1sYWItY2lsaXVtIgokSyBnZXQgY2lsaXVtYmdwY2x1c3RlcmNvbmZpZyBsYWIgPi9kZXYvbnVsbCAyPiYxIHx8IHsgZWNobyAiQ2lsaXVtQkdQQ2x1c3RlckNvbmZpZyAnbGFiJyBub3QgZm91bmQg4oCUIGRvIMKnMi4xIGZpcnN0IjsgZXhpdCAxOyB9CiRLIGFwcGx5IC1mICIkTEFCX0RJUi93ZWIueWFtbCIgPi9kZXYvbnVsbAokSyAtbiBsYWItY2JncCByb2xsb3V0IHN0YXR1cyBkZXBsb3kvd2ViIC0tdGltZW91dD0xMjBzID4vZGV2L251bGwKIyAtLS0gdGhlIGZhdWx0IC0tLQpmb3IgbiBpbiAkKCRLIGdldCBub2RlcyAtbyBuYW1lKTsgZG8gJEsgbGFiZWwgIiRuIiBiZ3AtID4vZGV2L251bGwgMj4mMSB8fCB0cnVlOyBkb25lCnNsZWVwIDEyCkxCPSQoJEsgLW4gbGFiLWNiZ3AgZ2V0IHN2YyB3ZWIgLW8ganNvbnBhdGg9J3suc3RhdHVzLmxvYWRCYWxhbmNlci5pbmdyZXNzWzBdLmlwfScpCmNhdCA8PFQKClRJQ0tFVCAgVGhlIG5vZGVzIG9mIGxhYi1jaWxpdW0gd2VyZSAicmVjeWNsZWQiIChzYW1lIG5hbWVzLCBmcmVzaCBjb25maWcpLgogICAgICAgIFNpbmNlIHRoZW4gdGhlIExvYWRCYWxhbmNlciBvZiBsYWItY2JncC93ZWIgKCR7TEJ9KSBpcyB1bnJlYWNoYWJsZQogICAgICAgIGZyb20gb3V0c2lkZToKICAgICAgICAgIGRvY2tlciBleGVjIGxhYi1jbGllbnQgY3VybCAtc1MgLW0zIGh0dHA6Ly8ke0xCfS8gICDihpIgY3VybDogKDI4KSBDb25uZWN0aW9uIHRpbWVkIG91dAogICAgICAgIGxhYi1mcnI6ICJzaG93IGJncCBzdW1tYXJ5IiBsaXN0cyBubyBjbHVzdGVyIG5laWdoYm9ycy4gQ2lsaXVtIGlzIGhlYWx0aHkuClQK'
base64 -d <<<"$P" | bash -s -- "$@"
