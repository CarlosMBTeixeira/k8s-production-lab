# Session 3 — Security: mTLS, authorization, identity

**Objective:** move a namespace from PERMISSIVE to STRICT mTLS without an
outage, lock it down to explicit service-to-service permissions, and be
able to tell a policy denial from a TLS failure from a connection reset
in one look.

**Prerequisites**
- Session 0. Lab with choice **5** or **6**.
- `S=https://raw.githubusercontent.com/istio/istio/1.30.7`
- A pod **outside** the mesh, to play a legacy client:
  ```bash
  kubectl create ns mesh-outsider
  kubectl apply -n mesh-outsider -f $S/samples/curl/curl.yaml
  O=$(kubectl -n mesh-outsider get pod -l app=curl -o jsonpath='{.items[0].metadata.name}')
  ```

**Read first:**
- istio.io → *Concepts* → "Security" (identity, mutual TLS, authorization
  architecture).
- istio.io → *Tasks* → *Security* → "Mutual TLS Migration",
  "Authorization" → "HTTP Traffic", "Authentication" → "JWT".
- Red Hat → OpenShift Service Mesh 3 → *Security* (to see which of these
  objects you will meet unchanged on the platform — all of them).

Course equivalents: *Security* — Authentication, Authorization,
Certificate Management. **CKS overlap** (noted, not taught here): mTLS
and identity-based policy complement NetworkPolicies; they do not replace
them.

---

## 3.0 — Identity: what a workload *is* to the mesh

```bash
P=$(kubectl -n bookinfo get pod -l app=productpage -o jsonpath='{.items[0].metadata.name}')
istioctl pc secret "$P" -n bookinfo
istioctl pc secret "$P" -n bookinfo -o json \
  | jq -r '.dynamicActiveSecrets[0].secret.tlsCertificate.certificateChain.inlineBytes' \
  | base64 -d | openssl x509 -noout -subject -ext subjectAltName -dates
```

> **Hypothesis.** The workload certificate identifies the pod, and lives
> about as long as a typical TLS certificate.
>
> **Tool.** The commands above.
>
> **Expected if right.** Wrong on both. The SAN is a **SPIFFE ID**,
> `spiffe://cluster.local/ns/bookinfo/sa/bookinfo-productpage` — the
> identity is the **ServiceAccount**, not the pod, so every replica
> shares it. And it lives **24 hours** (`NOT AFTER` one day after `NOT
> BEFORE`), rotated automatically by the sidecar agent; the root CA
> (`ROOTCA`) lives 10 years. Every AuthorizationPolicy in this session is
> written against that SA-based identity.
>
> **What would have caught this sooner.** `kubectl -n bookinfo get sa` —
> one ServiceAccount per Bookinfo service, created for exactly this.
> A deployment running as `default` SA shares an identity with everything
> else that does.

---

## 3.1 — PERMISSIVE is a migration state, not a security mode

```bash
kubectl -n mesh-outsider exec "$O" -- curl -s -o /dev/null -w '%{http_code}\n' http://productpage.bookinfo:9080/productpage
```

> **Hypothesis.** The mesh is "mTLS everywhere" because Istio's default
> is mTLS.
>
> **Tool.** The curl above from the non-meshed pod.
>
> **Expected if right.** `200`. Meshed-to-meshed traffic *is* mTLS
> (auto mTLS), but **PERMISSIVE accepts plaintext too** — that is its job
> during a migration. A namespace left in PERMISSIVE is open to any pod in
> the cluster.
>
> **What would have caught this sooner.** `istioctl x describe pod "$P" -n bookinfo`
> → `Workload mTLS mode: PERMISSIVE`, which you noted in session 0.

---

## 3.2 — Find the plaintext callers *before* going STRICT

Switching to STRICT breaks every plaintext caller. Find them first. The
obvious query:

```promql
sum by (source_workload, source_workload_namespace, destination_workload) (
  increase(istio_requests_total{destination_workload_namespace="bookinfo",
    reporter="destination", connection_security_policy!="mutual_tls"}[10m])) > 0
```

> **Hypothesis.** That query lists the outsider's request from 3.1 by
> name.
>
> **Tool.** Run it in Prometheus/Grafana.
>
> **Expected if right.** Wrong twice — both observed on this lab.
> 1. It returns **nothing**. The plaintext series was created by that
>    single request with value 1; `increase()` has no earlier sample to
>    compare with and reports 0. **Rate functions are blind to a caller
>    seen once.** Query the raw series instead:
>    ```promql
>    istio_requests_total{destination_workload_namespace="bookinfo", reporter="destination", connection_security_policy="none"}
>    ```
> 2. When you do find it, the caller is `source_workload="unknown"`,
>    `source_workload_namespace="unknown"`. Without mTLS there is no peer
>    identity to report. **Istio's metrics can tell you plaintext happens,
>    not who sends it.** The who is in the destination sidecar's access
>    log — the downstream address:
>    ```logql
>    {namespace="bookinfo", container="istio-proxy", pod=~"productpage.*"} |= "inbound|9080" != "outbound"
>    ```
>    then map the IP to a pod: `kubectl get pods -A -o wide | grep <ip>`.
>
> **What would have caught this sooner.** Kiali's graph with the
> *Security* display on: plaintext edges have no padlock, and the source
> shows as *unknown*. Kiali draws what the metric can't name.

`connection_security_policy` is only meaningful with
`reporter="destination"` — the source side reports `unknown` for it.

---

## 3.3 — STRICT

```bash
kubectl apply -n bookinfo -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata: {name: default}
spec: {mtls: {mode: STRICT}}
EOF
kubectl -n mesh-outsider exec "$O" -- curl -s -o /dev/null -w '%{http_code}\n' http://productpage.bookinfo:9080/productpage; echo "exit=$?"
./scripts/mesh-break.sh check
```

> **Hypothesis.** The outsider gets a `403`, and the traffic generator —
> which is also outside the mesh — breaks too.
>
> **Tool.** The two commands above.
>
> **Expected if right.** Wrong on both. The outsider gets **no HTTP
> status at all**: `000`, curl exit **56** (connection reset). STRICT is
> enforced at the TLS layer; a plaintext connection is reset before any
> HTTP exists, so there is nothing to return a 403 *with*. And the
> generator keeps working: it talks to the **ingress gateway**, whose
> listener is not a sidecar and accepts plaintext from outside; the
> gateway then calls productpage over mTLS. STRICT protects workloads,
> not entry points.
>
> **What would have caught this sooner.** The server sidecar's log for
> the rejected connection: `"- - -" 0 NR filter_chain_not_found`. The
> inbound listener's plaintext filter chain (session 0.3) is gone, so the
> connection matches nothing.

Keep STRICT on for the rest of the session.

---

## 3.4 — Authorization: default deny, then explicit allows

```bash
kubectl apply -n bookinfo -f - <<'EOF'
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: {name: allow-nothing}
spec: {}
EOF
./scripts/mesh-break.sh check
```

> **Hypothesis.** An empty `spec` matches nothing, so this policy has no
> effect.
>
> **Tool.** `mesh-break.sh check` and the productpage sidecar log.
>
> **Expected if right.** Wrong. An `ALLOW`-action policy (the default
> action) that matches nothing means **nothing is allowed**: every
> workload in the namespace now denies everything — **including the
> ingress gateway**, which runs in `bookinfo` and is a workload like any
> other. The page is `RBAC: access denied` (403) and the denial happens
> at the gateway, before productpage is reached. This is the standard
> "deny by default" baseline, and the gateway is the first thing people
> forget to re-allow.
>
> **What would have caught this sooner.** The reference page's own rule:
> if any ALLOW policy applies to a workload, requests not matching one of
> them are denied. "No match" is a deny, not a no-op.

Now write one ALLOW policy per edge, using the identities from 3.0. The
gateway's ServiceAccount is `bookinfo-gateway-istio`:

| To | Allow from (principal) | Methods |
|---|---|---|
| bookinfo-gateway (selector `gateway.networking.k8s.io/gateway-name: bookinfo-gateway`) | anyone — it is the entry point (`rules: [{}]`) | GET |
| productpage | `cluster.local/ns/bookinfo/sa/bookinfo-gateway-istio` | GET |
| details | `cluster.local/ns/bookinfo/sa/bookinfo-productpage` | GET |
| reviews | `cluster.local/ns/bookinfo/sa/bookinfo-productpage` | GET |
| ratings | `cluster.local/ns/bookinfo/sa/bookinfo-reviews` | GET |

Write them yourself (one `AuthorizationPolicy` per row, `selector` on
`app:`), apply one at a time, and predict what the page shows after each.

> **Hypothesis.** A denied request and a failed TLS handshake look the
> same to the caller.
>
> **Tool.** The caller's and callee's sidecar logs after each step.
>
> **Expected if right.** They are completely different: a policy denial
> is an **HTTP 403** with `rbac_access_denied_matched_policy[...]` in the
> callee's log (the request reached it, over mTLS, and was refused). A
> TLS failure is a reset with `NR filter_chain_not_found` (3.3) or `UC` on
> the caller (session 06 scenario 3). **403 = identity known and refused;
> reset = identity never established.**
>
> **What would have caught this sooner.** `istioctl x describe pod <callee>`
> lists the AuthorizationPolicies that apply to it.

---

## 3.5 — End-user authentication (JWT) at the edge

```bash
kubectl apply -n bookinfo -f - <<EOF
apiVersion: security.istio.io/v1
kind: RequestAuthentication
metadata: {name: jwt-gateway}
spec:
  selector: {matchLabels: {gateway.networking.k8s.io/gateway-name: bookinfo-gateway}}
  jwtRules:
  - issuer: "testing@secure.istio.io"
    jwksUri: "$S/security/tools/jwt/samples/jwks.json"
EOF
TOKEN=$(curl -s $S/security/tools/jwt/samples/demo.jwt)
```

Call the product page through the Bookinfo tunnel with no token, a bad
token, and `-H "Authorization: Bearer $TOKEN"`.

> **Hypothesis.** A request with no token is rejected now.
>
> **Tool.** curl with each of the three, recording the status.
>
> **Expected if right.** Wrong — the classic trap. **No token: 200.** Bad
> token: **401**. Valid token: 200. `RequestAuthentication` only
> *validates tokens that are present*; requiring one takes an
> `AuthorizationPolicy` on the same workload with
> `from: [{source: {requestPrincipals: ["*"]}}]`. Add it and no-token
> becomes **403**.
>
> **What would have caught this sooner.** Reading the two kinds' names
> literally: authentication establishes *who*; authorization decides
> *whether*. A JWT config without an authorization rule is an identity
> nobody checks.

---

## 3.6 — Certificates: rotation, and where the root comes from

```bash
istioctl pc secret "$P" -n bookinfo
kubectl -n istio-system get secret istio-ca-secret -o jsonpath='{.data.ca-cert\.pem}' | base64 -d | openssl x509 -noout -subject -dates
```

> **Hypothesis.** The mesh's root CA is cert-manager's, since the lab
> runs cert-manager (ADR-033).
>
> **Tool.** The second command.
>
> **Expected if right.** No — istiod generated its own self-signed root
> (`istio-ca-secret`, O=cluster.local) at install. cert-manager is not
> involved. On a platform you will usually see a **plugged-in CA**
> (`cacerts` secret) or cert-manager's `istio-csr` issuing workload
> certificates from the organisation's PKI — the trust root is a platform
> decision, made at install time, and painful to change later.
>
> **What would have caught this sooner.** `kubectl -n istio-system get secret cacerts`
> — absent here, which is what "self-signed root" looks like.

---

**Done when**
- A who-can-call-whom matrix for the four Bookinfo services plus the
  outsider, every cell verified with a real call, and every denied cell
  labelled **403** or **reset** with the reason.
- The Kiali graph with *Security* on shows a padlock on every Bookinfo edge.
- You can say why the generator survived STRICT and the outsider did not.
- Clean up: `kubectl -n bookinfo delete authorizationpolicy,requestauthentication,peerauthentication --all`
  and `kubectl delete ns mesh-outsider`.

**Runbook:** `runbooks/03-security.md`.
