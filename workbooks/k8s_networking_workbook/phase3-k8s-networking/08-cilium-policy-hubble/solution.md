# Lab 3.08 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$HOME/.kube/config"
K="kubectl --context kind-lab-cilium"
$K -n kube-system get ds cilium >/dev/null || { echo "Cilium not found on lab-cilium"; exit 1; }
$K delete ns lab-cil --ignore-not-found --wait=true >/dev/null
$K apply -f "$PHASE_DIR/07-cilium-kpr/web.yaml" >/dev/null
$K apply -f "$LAB_DIR/policies/01-default-deny.yaml" >/dev/null
$K apply -f "$LAB_DIR/policies/03-client-to-web-l7.yaml" >/dev/null
$K apply -f "$LAB_DIR/policies/04-client-fqdn.yaml" >/dev/null
# --- the fault ---
$K apply -f - >/dev/null <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: allow-dns, namespace: lab-cil}
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s:k8s-app: kube-dns
      toPorts:
        - ports: [{port: "53", protocol: ANY}]
YAML
$K -n lab-cil rollout status deploy/web --timeout=120s >/dev/null
$K -n lab-cil wait --for=condition=Ready pod/client --timeout=120s >/dev/null
# Cilium keeps name→IP mappings learned in §2.4 for about a minute after the
# old client is gone; wait until they've expired so the symptom is real.
echo "settling (up to 3 min)…"
for i in $(seq 36); do
  $K -n lab-cil exec client -- curl -s -m3 -o /dev/null http://example.com 2>/dev/null || break
  sleep 5
done
cat <<'T'

TICKET  The client in lab-cil must reach example.com (policy "client-fqdn"
        allows exactly that) and nothing else on the internet.
          kubectl -n lab-cil exec client -- dig +short example.com          → resolves fine
          kubectl -n lab-cil exec client -- curl -m5 http://example.com     → times out
        "The policy literally says example.com. Cilium is broken."
T
```
<!--/FAULT-->

DNS is allowed at **L4 only** (no `rules.dns`), so lookups bypass Cilium's
DNS proxy. They succeed, but Cilium never sees the answers, the FQDN cache
stays empty, and the `toFQDNs: example.com` rule allows zero IPs.

The mappings a `toFQDNs` selector uses are the agent's, not the pod's: IPs
learned by an earlier pod stay allowed until garbage collection (about a
minute after nobody uses them). That's why break.sh waits before printing
the ticket, and why a broken DNS rule can look fine for a while after a
change and then fail with nothing changed.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | DNS works and the policy names the host, so the name→IP mapping the policy depends on is missing. |
| Tool | `hubble observe --pod lab-cil/client --verdict DROPPED --since 1m` right after the curl |
| Expected if right | `client → <example.com IP>:80 … world … Policy denied DROPPED` — the IP isn't recognised as example.com. |
| Tool 2 | `hubble observe --pod lab-cil/client --protocol dns --since 1m` right after a `dig` |
| Expected if right | **nothing** — DNS flows are L4-forwarded, not proxied, so no DNS-level records. Use `--since`, not `--last`: Hubble's buffer still holds proxied DNS flows from §2.2 for a client with the same name. |
| Tool 3 | `kubectl -n kube-system exec $CIL -c cilium-agent -- cilium-dbg fqdn cache list` and `kubectl -n lab-cil get cnp allow-dns -o yaml` |
| Expected if right | no example.com entry; the IPs `dig` returns are absent from `cilium-dbg bpf ipcache list` (after the fix they appear with a 167772xx identity); the DNS policy's `toPorts` has no `rules: dns:`. `policy selectors` is no help here: with `tofqdns-preallocate-identities` the `example.com` selector always lists one identity. |
| What would have told me sooner | The Cilium docs' rule for `toFQDNs`: it requires a DNS rule that sends lookups to the proxy. A policy review checklist item: "every toFQDNs needs a matching `rules.dns`". In Hubble, the absence of DNS L7 flows is the tell. |

## Fix

```bash
kubectl apply -f policies/02-allow-dns-visible.yaml       # replaces allow-dns with the proxied version
kubectl -n lab-cil exec client -- dig +short example.com >/dev/null   # repopulate the cache
kubectl -n lab-cil exec client -- curl -s -m5 -o /dev/null -w '%{http_code}\n' http://example.com
```

If the client resolved example.com earlier and its resolver cached the
answer, the FQDN cache only learns on the next lookup — hence the `dig`.

## Why it matters later

OpenShift's EgressFirewall with `dnsName` (lab 3.11) and Calico's
domain-based policies work on the same idea with different plumbing; all of
them fail in some form when the platform can't see the DNS answers.
