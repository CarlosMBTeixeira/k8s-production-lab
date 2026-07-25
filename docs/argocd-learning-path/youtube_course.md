# Companion video course

**[Argo CD: Basics to Production](https://www.youtube.com/watch?v=Q5RvLl6KDqU&list=PLmPit9IIdzwSR-4FP65oP3AoZCKBvbwXg)**
— YouTube playlist by Varun Joshi (CloudWithVarJosh), started February 2026,
still being added to.

Companion hands-on repo (manifests to clone and apply, not a vendor
sandbox — meant to be run against your own cluster):
[CloudWithVarJosh/ArgoCD-Basics-To-Production](https://github.com/CloudWithVarJosh/ArgoCD-Basics-To-Production)

## How to use it alongside this path

Watch an episode, then reproduce its exercise against `k8slab`/
`k8s-gitops` on `feature/argocd` instead of a scratch repo — same
principle as every tier doc here: the video explains, your own lab is
where it actually sticks.

Confirmed episodes so far track closely with tiers already written:

| Episode topic | Related tier |
|---|---|
| Architecture + install | Tier 0 |
| Private repo auth, sync/prune/self-heal | Tier 0, Tier 4.2 |
| Helm as a source | Tier 1.3 |
| Sync phases & hooks | Tier 3.1 / 3.2 |
| ApplicationSets — generators, templates, multi-cluster patterns | Tier 1.4, Tier 6.2 |

Not yet confirmed whether the playlist covers RBAC/SSO, Sealed
Secrets, Argo Rollouts canary analysis, notifications, or disaster
recovery (Tiers 2, 4.1, 3.4, 5) — those tier docs stand on their own
either way.
