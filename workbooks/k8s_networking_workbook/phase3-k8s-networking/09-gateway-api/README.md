# Lab 3.09 — Gateway API in depth

| | |
|---|---|
| **Objective** | Run a platform-owned Gateway with team-owned routes — host/path/header matching, weighted canary, timeouts, TLS and redirects, cross-namespace backends — and debug routing from resource status down to Envoy's config. |
| **Time** | 5 h (week 15) |
| **Where** | k8slab, 2 workers, option 0 (Envoy Gateway + MetalLB + cert-manager already installed) · WSL host |
| **Risk** | Safe — a new Gateway in `lab-gw`; the existing `eg` Gateway in `gateway-api` is not touched |

## 1. Prerequisites

- Labs 3.02 (Services), 2.05 (NAT). Read ADR-023 for why this lab uses Gateway API and not Ingress.

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
kubectl get gatewayclass eg                         # ACCEPTED True
kubectl apply -f base.yaml
kubectl -n lab-gw wait --for=condition=Programmed gateway/lab-gw --timeout=120s
GW=$(kubectl -n lab-gw get gateway lab-gw -o jsonpath='{.status.addresses[0].value}'); echo $GW   # a MetalLB IP
st() { kubectl -n "$1" get httproute "$2" -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'; }
```

## 2. Hands-on

### 2.1 The resource model and who owns what

```bash
kubectl get gatewayclass eg -o yaml | grep controllerName    # Envoy Gateway's controller
kubectl -n lab-gw get gateway lab-gw -o yaml | sed -n '/^status:/,$p'
kubectl -n envoy-gateway-system get deploy,svc -l gateway.envoyproxy.io/owning-gateway-name=lab-gw
```

One Gateway → one Envoy Deployment + one `LoadBalancer` Service (MetalLB
gave it `$GW`). GatewayClass = infra provider, Gateway = platform team,
HTTPRoute = app team. The listener's `allowedRoutes` is the contract between
the last two.

### 2.2 First route, and reading status

```bash
kubectl apply -f routes/01-basic.yaml; st lab-gw-apps web
curl -s -H 'Host: web.lab.local' http://$GW/ | grep -E 'Name|Hostname'
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: other.lab.local' http://$GW/    # 404: no route for this host
```

Expect `Accepted=True (Accepted)` and `ResolvedRefs=True (ResolvedRefs)`.
Those two conditions answer 80 % of "my route doesn't work".

### 2.3 Canary, header pinning, timeouts

```bash
kubectl apply -f routes/02-canary.yaml; st lab-gw-apps web
for i in $(seq 50); do curl -s -H 'Host: web.lab.local' http://$GW/ | grep '^Name'; done | sort | uniq -c   # ~45/5
curl -s -H 'Host: web.lab.local' -H 'x-canary: true' http://$GW/ | grep '^Name'                         # web-v2
curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -H 'Host: web.lab.local' "http://$GW/slow?wait=3s"  # 504 after ~2 s
curl -s -o /dev/null -w '%{http_code}\n'               -H 'Host: web.lab.local' "http://$GW/slow?wait=1s"  # 200
```

(`?wait=` makes whoami delay its answer.) Weighted splitting is per
request at L7 — unlike lab 3.03's per-connection balancing.

### 2.4 Cross-namespace backends

```bash
kubectl apply -f routes/03-cross-namespace.yaml; st lab-gw-apps shared   # ResolvedRefs=False (RefNotPermitted)
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: web.lab.local' http://$GW/shared   # 500
kubectl apply -f routes/04-referencegrant.yaml; sleep 3; st lab-gw-apps shared
curl -s -H 'Host: web.lab.local' http://$GW/shared | grep '^Name'                     # shared
```

The **target** namespace grants access, not the route's. A route can't
reach into a namespace that didn't agree.

### 2.5 TLS termination and redirect

```bash
kubectl -n lab-gw get certificate lab-gw-tls                 # READY True
kubectl apply -f routes/05-https-redirect.yaml
curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' -H 'Host: secure.lab.local' http://$GW/
curl -sk --resolve secure.lab.local:443:$GW https://secure.lab.local/ | grep '^Name'
openssl s_client -connect $GW:443 -servername secure.lab.local </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName
openssl s_client -connect $GW:443 -servername nope.example </dev/null 2>&1 | grep -iE 'alert|error' | head -2   # no listener for that SNI
```

The HTTPS listener selects by **SNI** before any route is consulted. A
client that doesn't send SNI, or sends the wrong one, never reaches a route.

### 2.6 Down to Envoy

```bash
EP=$(kubectl -n envoy-gateway-system get pod -l gateway.envoyproxy.io/owning-gateway-name=lab-gw -o jsonpath='{.items[0].metadata.name}')
kubectl -n envoy-gateway-system port-forward pod/$EP 19000:19000 >/dev/null & sleep 2
curl -s localhost:19000/listeners                               # one per Gateway listener/port
curl -s localhost:19000/clusters | grep -E '::(cx_active|health_flags|[0-9.]+:80::hostname)' | head
curl -s localhost:19000/config_dump | python3 -c 'import json,sys; d=json.load(sys.stdin); print([c["@type"].split(".")[-1] for c in d["configs"]])'
kill %1
kubectl -n envoy-gateway-system logs deploy/envoy-gateway --tail=20 | grep -i lab-gw   # translation errors land here
```

Route status is the controller's opinion; Envoy's clusters and listeners
are what's actually serving. When they disagree, the controller logs say why.

## 3. Verification

| Check | Expected |
|---|---|
| §2.2 | `Accepted=True`, `ResolvedRefs=True`; `Name: web-v1`; 404 for other hosts |
| §2.3 | ≈ 45/5 split; header → web-v2; `/slow?wait=3s` → 504 at ~2 s |
| §2.4 | 500 + `RefNotPermitted` before the grant, `Name: shared` after |
| §2.5 | 301 to https; cert SAN `*.lab.local`; handshake fails for an unknown SNI |
| §2.6 | Envoy lists an HTTP and an HTTPS listener and clusters for web-v1, web-v2, shared |

## 4. Break/fix

```bash
bash break.sh          # rebuilds the lab and adds a second team's app
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `curl -s -H 'Host: team2.lab.local' http://$GW/ | grep '^Name'`
prints `team2`, and `web.lab.local` still works. Don't touch the Gateway.

<details><summary>Hint (only after 20 minutes)</summary>

`kubectl apply` succeeding means the API server accepted the object, not
that the Gateway did. Read the route's status.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
kubectl delete ns lab-gw lab-gw-apps lab-gw-other lab-gw-team2 --ignore-not-found
```

## 6. What I should be able to explain after this

- Gateway API splits ownership: GatewayClass (provider), Gateway + listeners + `allowedRoutes` (platform), HTTPRoute (app), ReferenceGrant (target namespace consenting to cross-namespace refs).
- Route status conditions — `Accepted` (attached to the listener?), `ResolvedRefs` (backends exist and are permitted?) — and the Gateway's `Programmed` are the first debugging step; Envoy's admin API is the second.
- HTTPS listeners match on SNI before routes; weights, header matches and timeouts are per-request L7 decisions, unlike Service-level per-connection balancing.
