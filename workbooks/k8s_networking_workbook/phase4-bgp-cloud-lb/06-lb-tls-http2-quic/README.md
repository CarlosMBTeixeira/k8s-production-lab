# Lab 4.06 — L4/L7 load balancing, TLS, HTTP/2, QUIC

| | |
|---|---|
| **Objective** | Prove that L4 balances connections and L7 balances requests (the gRPC/HTTP-2 imbalance incident), take TLS apart until every common failure has a name, and see HTTP/2 and HTTP/3 negotiated on the wire. |
| **Time** | 5 h (week 21) — the QUIC part is the first to cut |
| **Where** | kind `lab-plain` (§2.1) + Docker on the WSL host (§2.2–2.4) |
| **Risk** | Safe — disposable cluster and containers; lab-only keys in `.pki/` (gitignored) |

## 1. Prerequisites

- Labs 3.02, 3.09. kind `lab-plain` (from 4.02, or `kind create cluster --config ../../setup/kind/plain.yaml`).

```bash
unset KUBECONFIG; kubectl config use-context kind-lab-plain
cd <workbook>/phase4-bgp-cloud-lb/06-lb-tls-http2-quic
kubectl apply -f l7.yaml
kubectl -n lab-l7 rollout status deploy/web; kubectl -n lab-l7 rollout status deploy/envoy; kubectl -n lab-l7 wait --for=condition=Ready pod/client
C='kubectl -n lab-l7 exec client --'
```

## 2. Hands-on

### 2.1 L4 balances connections, L7 balances requests

```bash
$C sh -c 'for i in $(seq 9); do curl -s web | grep Hostname; done' | sort | uniq -c       # 9 connections: spread
$C sh -c 'curl -s web web web web web web web web web | grep Hostname' | sort | uniq -c    # 1 connection, 9 requests: one pod
```

Same Service, same pods. curl reused one keep-alive connection for the
second run, and kube-proxy (any mode, any CNI) picks a backend **per
connection**. gRPC and HTTP/2 clients open one connection and multiplex
everything over it, so a gRPC client talks to exactly one replica forever —
scale to 10 and nine sit idle.

```bash
$C sh -c 'curl -s envoy:10000 envoy:10000 envoy:10000 envoy:10000 envoy:10000 envoy:10000 | grep Hostname' | sort | uniq -c   # 1 connection to Envoy, spread
kubectl -n lab-l7 port-forward deploy/envoy 9901 >/dev/null & sleep 2
curl -s localhost:9901/clusters | grep -E 'web::[0-9.]+:80::(cx_active|rq_total)'; kill %1
```

Envoy terminates the client's connection and balances each request over
its own pool to every pod — found via the **headless** Service (one DNS
record per pod). The fixes for gRPC, in order: an L7 proxy (mesh, Gateway,
Envoy), client-side balancing over a headless Service (gRPC `round_robin`),
or server-side `MaxConnectionAge` so clients reconnect and re-spread.

### 2.2 TLS, one failure at a time

```bash
export PKI=$PWD/.pki; bash pki.sh $PKI
docker network create lab-tls 2>/dev/null || true
srv() { docker rm -f lab-tls-srv >/dev/null 2>&1; docker run -d --name lab-tls-srv --network lab-tls --network-alias api.lab.local \
          -v $PKI:/pki:ro nicolaka/netshoot:v0.13 openssl s_server -accept 443 -key /pki/leaf.key -www "$@" >/dev/null; sleep 1; }
cli() { docker run --rm --network lab-tls -v $PKI:/pki:ro nicolaka/netshoot:v0.13 "$@"; }

srv -cert /pki/leaf.pem -cert_chain /pki/int.pem
cli curl -s --cacert /pki/root.pem https://api.lab.local/ | head -2                        # works: chain + trust + name
cli openssl s_client -connect api.lab.local:443 -servername api.lab.local -CAfile /pki/root.pem -brief </dev/null
```

Now break it on purpose, one thing at a time, and **write the exact error
string** into the cheatsheet next to its cause:

| Try | Command | Error you'll learn to recognise |
|---|---|---|
| unknown CA | `cli curl -s https://api.lab.local/` | `unable to get local issuer certificate` |
| wrong name | `cli curl -s --cacert /pki/root.pem https://lab-tls-srv/` | `no alternative certificate subject name matches target host name` |
| no SNI / IP | `cli curl -s --cacert /pki/root.pem https://$(docker inspect -f '{{(index .NetworkSettings.Networks "lab-tls").IPAddress}}' lab-tls-srv)/` | same — and with SNI-routed servers (Gateways, lab 3.09) the wrong cert or a handshake failure |
| old protocol | `cli openssl s_client -connect api.lab.local:443 -tls1_1 </dev/null` | `no protocols available` / `unsupported protocol` |
| inspect | `cli openssl s_client -connect api.lab.local:443 -servername api.lab.local -showcerts </dev/null \| grep -E '^ [0-9] s:\|i:'` | the chain as served: depth 0 leaf, depth 1 intermediate |

mTLS — the server asks for a client certificate:

```bash
srv -cert /pki/leaf.pem -cert_chain /pki/int.pem -Verify 1 -CAfile /pki/ca-bundle.pem
cli curl -s --cacert /pki/root.pem https://api.lab.local/ ; echo "exit=$?"                 # alert: certificate required
cli curl -s --cacert /pki/root.pem --cert /pki/client.pem --key /pki/client.key https://api.lab.local/ | head -2
```

### 2.3 HTTP/2 and ALPN

```bash
docker rm -f lab-caddy 2>/dev/null; docker run -d --name lab-caddy --network lab-tls --network-alias quic.lab.local \
  -v $PWD/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2.8
sleep 3
cli curl -sk --http1.1 https://quic.lab.local/                     # hello over HTTP/1.1
cli curl -sk --http2   https://quic.lab.local/                     # hello over HTTP/2.0
cli curl -skv --http2 -o /dev/null https://quic.lab.local/ 2>&1 | grep -iE 'ALPN|alt-svc'
cli openssl s_client -connect quic.lab.local:443 -servername quic.lab.local -alpn h2,http/1.1 </dev/null 2>/dev/null | grep -i alpn
```

ALPN in the ClientHello is how a client and server agree on h2 before any
HTTP is sent. A proxy or LB that terminates TLS and only offers
`http/1.1` silently downgrades every client behind it — and breaks gRPC,
which requires h2.

### 2.4 HTTP/3 (QUIC) — optional

```bash
docker run --rm curlimages/curl:8.23.0 -V | grep -io 'http3'       # does this curl build speak HTTP/3?
```

If it prints `HTTP3`:

```bash
docker run --rm --net container:lab-caddy --privileged nicolaka/netshoot:v0.13 tshark -i eth0 -f 'udp port 443' -c 6 &
docker run --rm --network lab-tls curlimages/curl:8.23.0 -sk --http3-only https://quic.lab.local/    # hello over HTTP/3.0
wait
```

If not, stop at what you can see without a client: the `alt-svc: h3=":443"`
header from 2.3 (servers advertise HTTP/3 over HTTP/2) and Caddy listening
on UDP 443 (`docker run --rm --net container:lab-caddy nicolaka/netshoot:v0.13 ss -ulpn`).
QUIC is TLS 1.3 inside UDP: firewalls that only allow TCP/443 make clients
fall back to h2 — slower to fail than you'd think, and invisible in TCP captures.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | 9 separate curls spread; one keep-alive connection → one pod; through Envoy → spread |
| §2.2 | each error string reproduced and matched to its cause; mTLS fails without, works with the client cert |
| §2.3 | `HTTP/1.1` vs `HTTP/2.0`; `ALPN: server accepted h2`; `alt-svc` advertises h3 |

## 4. Break/fix

```bash
bash break.sh          # replaces the API server with "the vendor's new certificate"
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `cli curl -s --cacert /pki/root.pem https://api.lab.local/ | head -1` succeeds
without adding anything to the client's trust.

<details><summary>Hint (only after 20 minutes)</summary>

Read the chain the server actually sends, then verify it the way a client
without extra intermediates would.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
docker rm -f lab-tls-srv lab-caddy 2>/dev/null; docker network rm lab-tls
kubectl delete ns lab-l7
rm -rf .pki
```

## 6. What I should be able to explain after this

- Service load balancing is per connection (L4); long-lived/multiplexed protocols (HTTP/2, gRPC, DB pools) need per-request (L7) balancing, client-side balancing over headless Services, or connection age limits.
- The TLS checks a client makes, in order — chain to a trusted root (with the intermediates the **server** sends), name in SAN (via SNI), validity, protocol/cipher — and the error each failure produces; mTLS adds the reverse check.
- ALPN negotiates h2 inside the TLS handshake; HTTP/3 runs over QUIC (UDP 443) and is advertised with `alt-svc`.
