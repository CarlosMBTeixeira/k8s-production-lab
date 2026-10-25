# Lab 3.04 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="$WB_DIR/../../kubernetes/admin.conf"
ORIG="$LAB_DIR/.Corefile.orig"
CUR=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')
if [ ! -f "$ORIG" ]; then
  printf '%s\n' "$CUR" > "$ORIG"
  echo "original Corefile saved to $ORIG"
fi
grep -q 'forward \. /etc/resolv.conf' "$ORIG" || { echo "unexpected Corefile (no 'forward . /etc/resolv.conf'); not touching it"; exit 1; }
kubectl apply -f "$LAB_DIR/apps.yaml" >/dev/null
kubectl -n lab-dns wait --for=condition=Ready pod/client --timeout=120s >/dev/null
# --- the fault ---
sed 's#forward \. /etc/resolv.conf#forward . 192.0.2.53#' "$ORIG" > "$LAB_DIR/.Corefile.broken"
kubectl -n kube-system create cm coredns --from-file=Corefile="$LAB_DIR/.Corefile.broken" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
rm -f "$LAB_DIR/.Corefile.broken"
kubectl -n kube-system rollout restart deploy/coredns >/dev/null
kubectl -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null
cat <<'T'

TICKET  Since this morning, pods across the cluster can't reach anything on
        the internet by name: "Could not resolve host: example.com" after a
        long pause. Calling other Services by name works. The nodes
        themselves resolve example.com fine.
          kubectl -n lab-dns exec client -- curl -sI -m10 http://example.com
T
```
<!--/FAULT-->

CoreDNS forwards non-cluster names to `192.0.2.53` (TEST-NET-1, nothing
answers). Cluster names are answered by the `kubernetes` plugin before
`forward` is reached, so they keep working — which is what makes it look
like "the internet is down" rather than "DNS is down".

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Cluster names resolve, external names don't → the pod reaches CoreDNS fine; CoreDNS can't reach (or is misconfigured for) its upstream. |
| Tool | `$C dig example.com` then `$C dig web.lab-dns.svc.cluster.local` |
| Expected if right | external: `SERVFAIL` after a delay; cluster: instant `NOERROR`. |
| Tool 2 | `kubectl -n kube-system logs -l k8s-app=kube-dns --tail=20` |
| Expected if right | `[ERROR] plugin/errors: 2 example.com. A: read udp <pod>:…->192.0.2.53:53: i/o timeout` — names the upstream. |
| Tool 3 | `kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' \| grep forward` and `ssh w-1 dig +short @$(ssh w-1 "grep -m1 nameserver /run/systemd/resolve/resolv.conf \| cut -d' ' -f2") example.com` |
| Expected if right | `forward . 192.0.2.53`; the node's real upstream answers fine. |
| What would have told me sooner | `coredns_dns_responses_total{rcode="SERVFAIL"}` and `coredns_forward_healthcheck_broken_total` rising, alongside `NOERROR` dropping for non-cluster zones. And GitOps on the Corefile: a diff would have shown a hand-edited `forward`. |

## Fix

```bash
kubectl -n kube-system create cm coredns --from-file=Corefile=.Corefile.orig --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system rollout restart deploy/coredns && kubectl -n kube-system rollout status deploy/coredns
kubectl -n lab-dns exec client -- dig +short example.com
rm .Corefile.orig
```

## Why it matters later

On OpenShift the DNS operator owns CoreDNS (`dns.operator/default`), and
upstreams are set in its `spec.upstreamResolvers` / `spec.servers` (per-zone
forwarding). Same symptom, same split, different knob.
