# Session 0 — Toolbox, and following one request

**Objective:** be able to take any request between two meshed pods and
name every Envoy object it passes through, and say which tool shows each
one. Everything after this session is debugged with these tools.

**Prerequisites**
- Lab up with choice **5** or **6** (README). `./scripts/install-istioctl.sh` done.
- `export KUBECONFIG=~/k8slab/kubernetes/admin.conf`
- Kiali open: `./scripts/tunnels/kiali-tunnel.sh` → `https://localhost:8446/`

**Read first (and only this):**
- istio.io → *Concepts* → "Traffic Management" (the intro and "Virtual
  services" sections only, for vocabulary).
- istio.io → *Operations* → *Diagnostic Tools* → "Debugging Envoy and
  Istiod" and "Understanding your Mesh with istioctl describe".

Course equivalents: *Istio Introduction*, *Pre-requisites* (sidecars,
Envoy). The install is already done by `09_istio_kiali.sh`; this session
starts where the course's install ends.

---

## 0.0 — Three versions must agree

```bash
istioctl version
```

> **Hypothesis.** Client, control plane and data plane all report the
> same version, because the client was installed from the same pin.
>
> **Tool.** `istioctl version`.
>
> **Expected if right.** `client version: 1.30.7`, `control plane
> version: 1.30.7`, `data plane version: 1.30.7 (7 proxies)` — six
> Bookinfo pods plus the ingress gateway.
>
> **What would have caught this sooner.** Nothing needed catching here,
> but remember the shape: on the platform, a data-plane version that
> disagrees with the control plane means pods that were not restarted
> after an upgrade. That is the first thing to check after any istiod
> upgrade (session 5).

---

## 0.1 — Is this pod in the mesh, and what applies to it?

```bash
P=$(kubectl -n bookinfo get pod -l app=productpage -o jsonpath='{.items[0].metadata.name}')
istioctl x describe pod "$P" -n bookinfo
kubectl -n bookinfo get pod "$P" -o jsonpath='{.spec.initContainers[*].name}{"\n"}{.spec.containers[*].name}{"\n"}'
```

> **Hypothesis.** The sidecar is a regular container next to
> `productpage`, and an `istio-init` init container sets up iptables.
>
> **Tool.** The jsonpath above.
>
> **Expected if right.** It is wrong twice. There is **no `istio-init`**:
> traffic redirection is done by the istio-cni node agent (ADR-038), and
> what you see instead is `istio-validation`, which only *checks* that
> the CNI did its job. And `istio-proxy` may appear among the **init**
> containers rather than the regular ones: native sidecars (restartable
> init containers) let the proxy start before and stop after the app.
>
> **What would have caught this sooner.** `istioctl x describe` — it
> reports what is *effective* for the pod (Service ports, PeerAuthentication
> mode, VirtualServices that match) instead of what you assume.

**Note what `describe` says now:** `Workload mTLS mode: PERMISSIVE`.
Session 3 changes that.

---

## 0.2 — Did istiod push config to every proxy?

```bash
istioctl proxy-status
```

> **Hypothesis.** The output has a SYNCED/STALE column per xDS type, as
> most guides show.
>
> **Tool.** `istioctl proxy-status`.
>
> **Expected if right.** Not in 1.30. You get `NAME`, `CLUSTER`,
> `ISTIOD`, `VERSION` and `SUBSCRIBED TYPES` (`4 (CDS,LDS,EDS,RDS)`).
> Staleness is no longer a column; the useful reading is *which istiod
> each proxy is connected to* — that column becomes essential with two
> revisions (session 5) — and whether a proxy is missing from the list
> entirely.
>
> **What would have caught this sooner.** `istioctl proxy-status --help`.
> Guides age faster than the tool; check the help of the version you run.

---

## 0.3 — Follow one request: productpage → reviews

The request is `GET http://reviews:9080/reviews/0` from productpage. It
leaves the app, gets redirected into productpage's sidecar, and Envoy
makes four decisions. Find each one.

```bash
istioctl pc listener "$P" -n bookinfo --port 9080
istioctl pc route    "$P" -n bookinfo --name 9080
istioctl pc cluster  "$P" -n bookinfo --fqdn reviews.bookinfo.svc.cluster.local
istioctl pc endpoint "$P" -n bookinfo --cluster 'outbound|9080||reviews.bookinfo.svc.cluster.local'
```

> **Hypothesis.** There is a listener per destination Service.
>
> **Tool.** `pc listener --port 9080`.
>
> **Expected if right.** Wrong. One listener, `0.0.0.0:9080`, with two
> filter chains: one for HTTP (`App: http/1.1,h2c` → `Route: 9080`) and a
> fallback (`ALL` → `PassthroughCluster`). Every HTTP Service on port
> 9080 shares it; the **route table named `9080`** is what separates
> them, by `Host` header. (Session 06 scenario 5 shows what happens when
> a Service is *not* treated as HTTP: it gets its own listener on its
> ClusterIP, and none of this routing applies.)
>
> **What would have caught this sooner.** The route table's name. Routes
> are named after ports, not services — that alone says the listener is
> per port.

Then, for the other three:

| Step | Object | What you see | Who decides it |
|---|---|---|---|
| Listener | `0.0.0.0:9080` | HTTP filter chain → route `9080` | port + protocol detection |
| Route | vhost `reviews.bookinfo.svc.cluster.local:9080`, match `/*` | `VIRTUAL SERVICE` column empty | a VirtualService, if one existed (session 1 fills it) |
| Cluster | `outbound\|9080\|\|reviews.bookinfo.svc.cluster.local` | `SUBSET -`, `DESTINATION RULE` empty | a DestinationRule (subsets, LB, TLS, circuit breaking) |
| Endpoint | three pod IPs, `HEALTHY`, outlier `OK` | one per reviews version | Kubernetes endpoints + outlier detection (session 2) |

Read the cluster name aloud once: `direction|port|subset|fqdn`. Every
cluster in every proxy has that shape, and the empty third field is the
subset. Session 06 scenario 2 hinges on it.

**Now the other end.** The same request arrives at a reviews pod on an
*inbound* listener:

```bash
R=$(kubectl -n bookinfo get pod -l app=reviews,version=v1 -o jsonpath='{.items[0].metadata.name}')
istioctl pc listener "$R" -n bookinfo | grep -E 'ADDRESS|virtualInbound|15006'
istioctl pc cluster  "$R" -n bookinfo --direction inbound
```

> **Hypothesis.** Inbound traffic lands on port 9080 of the reviews pod.
>
> **Tool.** The two commands above.
>
> **Expected if right.** It lands on **15006** (`virtualInbound`), where
> iptables redirected it. Its filter chains split mTLS
> (`Trans: tls; App: istio-http/…`) from plaintext (`raw_buffer`), and
> the request is then handed to the `inbound` cluster for port 9080,
> type `ORIGINAL_DST` — the pod's own address. The app's port is a
> destination *behind* the sidecar, not the listener. That tls /
> raw_buffer split is exactly what STRICT mode removes in session 3.
>
> **What would have caught this sooner.** The sidecar's ports, which you
> will see in every access log line: 15001 outbound, 15006 inbound,
> 15020/15090 metrics, 15021 health. Learn the four numbers.

---

## 0.4 — The access log line is the fastest tool you have

```bash
kubectl -n bookinfo logs "$P" -c istio-proxy --tail=3
```

Envoy access logs are on (`meshConfig.accessLogFile`, ADR-038), and Alloy
ships them to Loki. Take one line and label every field:

```
[2026-10-23T15:08:15.444Z] "GET /productpage HTTP/1.1" 200 - via_upstream - "-" 0 15068 32 32 "192.168.226.104" "curl/8.23.0" "<request-id>" "bookinfo-gateway-istio.bookinfo.svc.cluster.local" "192.168.226.…" ...
```

method/path/protocol · **status** · **response flag** (`-` = none) ·
response-code details · bytes in/out · duration · upstream time ·
x-forwarded-for · user agent · request ID · authority · upstream host ·
**upstream cluster** · …

> **Hypothesis.** When a call fails, the status code is the most useful
> field.
>
> **Tool.** Grafana → Explore → Loki:
> ```logql
> {namespace="bookinfo", container="istio-proxy"} |= "\" 503 "
> ```
>
> **Expected if right.** Nothing yet — the mesh is healthy. Keep the
> query; sessions 2 and 6 fill it. You will find the **response flag**
> (the field after the status) is more useful than the status: five
> different failures all return 503 and are told apart only by `NC`,
> `UC`, `UO`, `UH`, `URX`.
>
> **What would have caught this sooner.** The request ID. It is the same
> on the caller's and the callee's line, so one grep on it gives both
> sides of a failed hop.

---

## 0.5 — Kiali: what it is reading

Kiali → Traffic Graph → namespace `bookinfo`, *Versioned app graph*,
Display: *Traffic Distribution*, *Security*.

> **Hypothesis.** Kiali learns the topology from the mesh (istiod or the
> proxies).
>
> **Tool.** Kiali's graph, then Prometheus directly:
> ```promql
> sum by (source_workload, destination_workload) (rate(istio_requests_total{reporter="destination", destination_workload_namespace="bookinfo"}[1m]))
> ```
>
> **Expected if right.** Partly wrong. The **edges** — and every number
> on them — come from that Prometheus query. Istio config and pod state
> come from the Kubernetes API. Stop the traffic generator
> (`kubectl -n bookinfo scale deploy traffic-generator --replicas=0`) and
> within a couple of minutes the edges disappear while the workloads stay.
> Scale it back to 1 afterwards.
>
> **What would have caught this sooner.** Kiali's own configuration
> (`external_services.prometheus.url` in `kubernetes/manifests/kiali/values.yaml`).
> A graph-shaped UI hides that it is a PromQL front end; session 06
> scenario 9 is the failure that follows from forgetting it.

---

**Done when** you can, for a request from reviews-v2 to ratings, write
down without looking: the outbound listener and route table name in the
reviews-v2 proxy, the full cluster name, the number of endpoints and
their health, the inbound listener port on ratings, and the one LogQL
query that shows both sides of a single call by request ID. Then check
each answer with the tools above.

**Runbook:** `runbooks/00-toolbox.md`.
