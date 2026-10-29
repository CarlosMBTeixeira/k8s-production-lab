# Lab 3.12 — The service mesh datapath

| | |
|---|---|
| **Objective** | See what a sidecar mesh does to a pod's network namespace — the redirect rules istio-cni installs, the Envoy listeners they feed, and mTLS on the wire — at the packet level, not the CRD level. |
| **Time** | 3 h (week 17) |
| **Where** | k8slab, 1 worker, **option 5** (Observability + Istio + Kiali) — or option 3 now and option 8 later; option 8 alone exits without the observability stack · WSL host |
| **Risk** | Safe — `lab-mesh` only; the mesh install itself is the pipeline's |

The Istio workbook (`../../../istio_svc_mesh_workbook/`) covers operating the
mesh — routing, resilience, security policy. This lab is only the plumbing
underneath, so the two don't overlap; its session 0 follows a request
through Envoy's config and is the natural next read.

## 1. Prerequisites

- Labs 2.04, 2.05, 3.01. `istioctl` on the host (`../../../../scripts/install-istioctl.sh`).

```bash
export KUBECONFIG=~/k8slab/kubernetes/admin.conf
istioctl version
kubectl apply -f apps.yaml
kubectl -n lab-mesh rollout status deploy/web; kubectl -n lab-mesh rollout status deploy/client
kubectl -n lab-mesh wait --for=condition=Ready pod/noside
CL=$(kubectl -n lab-mesh get pod -l app=client -o jsonpath='{.items[0].metadata.name}')
```

## 2. Hands-on

### 2.1 What injection changed

```bash
kubectl -n lab-mesh get pods                                       # client and web 2/2; noside 1/1
kubectl -n lab-mesh get pod $CL -o jsonpath='{.spec.initContainers[*].name}{"  |  "}{.spec.containers[*].name}{"\n"}'
# istio-validation istio-proxy  |  netshoot
```

Two things to notice. With istio-cni there is no privileged `istio-init`
container rewriting iptables; `istio-validation` only checks that the CNI
plugin did its job. And `istio-proxy` is listed under **initContainers**:
Istio 1.30 injects it as a Kubernetes native sidecar (an init container with
`restartPolicy: Always`), so it starts before the app and stops after it.
`READY 2/2` still counts it.

### 2.2 The rules inside the pod's netns

```bash
kubectl -n lab-mesh debug -it $CL --image=nicolaka/netshoot:v0.13 --profile=netadmin --target=netshoot -- sh
# inside (shares the pod's netns):
iptables-save -t nat | grep ISTIO       # iptables-nft backend; `nft list table ip nat` shows the same rules with counters
ss -ltn                                 # 15001 (outbound), 15006 (inbound), 15090, 15021, 15020, 15000 (admin, localhost only)
```

Ignore the "iptables-legacy tables present" warning, it comes from the node.
Every Envoy port is listed twice: one socket per Envoy worker thread
(`SO_REUSEPORT`). `ss -p` shows no process names here, because Envoy runs
in the `istio-proxy` container as uid 1337 and the netadmin profile can't
see its processes.

Read the chains:

| Chain / rule | Meaning |
|---|---|
| `PREROUTING -j ISTIO_INBOUND` → `ISTIO_IN_REDIRECT` → `REDIRECT --to-ports 15006` | every inbound TCP to the app goes to Envoy's inbound listener first |
| `OUTPUT -j ISTIO_OUTPUT` → `ISTIO_REDIRECT` → `REDIRECT --to-ports 15001` | every outbound TCP from the app goes to Envoy's outbound listener |
| `-m owner --uid-owner 1337 -j RETURN` (and the same for `--gid-owner 1337`) | Envoy's own traffic is not redirected — or it would loop |
| `-s 127.0.0.6/32 -o lo -j RETURN` | Envoy's inbound passthrough: it forwards to the app from source 127.0.0.6 |
| `ISTIO_INBOUND` RETURNs for 15008, 15020, 15021, 15090 | HBONE, merged metrics, health, Envoy stats — not sent through 15006 |

It's lab 2.05's REDIRECT/DNAT, applied inside one pod, so the app never
knows the proxy exists.

### 2.3 Who installed them: istio-cni chained onto Calico

```bash
NODE=$(kubectl -n lab-mesh get pod $CL -o jsonpath='{.spec.nodeName}')
ssh ${NODE/worker-/w-} "sudo ls /etc/cni/net.d/; sudo cat /etc/cni/net.d/10-calico.conflist | jq -r '.plugins[].type'"
```

`calico`, `portmap`, **`istio-cni`**: containerd runs the chain
in order for every pod. Calico wires the network; istio-cni writes the
redirect rules into the new netns. That's ADR-038's design, and why
ADR-040 had to raise inotify limits (istio-cni watches that directory).

### 2.4 mTLS on the wire

Envoy keeps its upstream mTLS connection to web open (idle timeout 1 h), so
only the first request through a fresh connection pool shows a handshake.
Restart the client so the capture sees one:

```bash
kubectl -n lab-mesh rollout restart deploy/client && kubectl -n lab-mesh rollout status deploy/client
kubectl -n lab-mesh wait --for=delete pod/$CL --timeout=60s
CL=$(kubectl -n lab-mesh get pod -l app=client -o jsonpath='{.items[0].metadata.name}')
WEB=$(kubectl -n lab-mesh get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
WNODE=$(kubectl -n lab-mesh get pod -l app=web -o jsonpath='{.items[0].spec.nodeName}')
kubectl debug node/$WNODE -it --profile=sysadmin --image=nicolaka/netshoot:v0.13
# inside (node netns): find web's cali interface, then
CALI=$(ip route get <WEB IP> | grep -o 'cali[0-9a-f]*')
tshark -i $CALI -f 'tcp port 80' -d tcp.port==80,tls -Y 'tls.handshake.type == 1' \
  -T fields -e ip.src -e tls.handshake.extensions_server_name -e tls.handshake.extensions_alpn_str
```

`-d tcp.port==80,tls` matters: tshark decodes port 80 as HTTP, so without it
the TLS handshake is never decoded and the filter matches nothing.

```bash
# WSL host, while tshark runs
kubectl -n lab-mesh exec $CL -c netshoot -- curl -s -o /dev/null -w '%{http_code}\n' web          # 200
kubectl -n lab-mesh exec noside -- curl -s -m3 -o /dev/null -w '%{http_code}\n' web                # 000: reset
```

The meshed client's request arrives at web's veth as a **TLS ClientHello**
on port 80, SNI `outbound_.80_._.web.lab-mesh.svc.cluster.local`, ALPN
`istio-http/1.1,istio,http/1.1`. Run the curl twice and you may see a second
ClientHello: each Envoy worker thread has its own connection pool. Run it
again later and you see nothing, because the request reuses an open
connection (`-Y tls` then shows only Application Data, content type 23). The app sent plain HTTP;
its sidecar upgraded it. `noside` sends plaintext and web's sidecar, under
STRICT, resets it. Exit the debug shell and delete the debug pod.

### 2.5 Envoy's side of the same request

```bash
istioctl proxy-config listeners $CL.lab-mesh --port 15001   # virtualOutbound: only a PassthroughCluster
istioctl proxy-config listeners $CL.lab-mesh --port 80      # where it's handed over by original destination port
istioctl proxy-config routes    $CL.lab-mesh --name 80 | grep web.lab-mesh
istioctl proxy-config clusters  $CL.lab-mesh | grep web.lab-mesh
istioctl proxy-config endpoints $CL.lab-mesh | grep "$WEB"
istioctl x describe pod $(kubectl -n lab-mesh get pod -l app=web -o jsonpath='{.items[0].metadata.name}') -n lab-mesh
```

The 15001 listener accepts the redirected connection and passes it to the
listener that matches its original destination (`0.0.0.0_80`, recovered with
`SO_ORIGINAL_DST`). That listener's HTTP route picks the `web` virtual host,
which points at the EDS cluster, which holds web's pod IP. `describe` on web
shows the Service port and the effective STRICT PeerAuthentication.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | `istio-validation istio-proxy  \|  netshoot` (sidecar as native init container) |
| §2.2 | ISTIO_INBOUND/ISTIO_OUTPUT chains with REDIRECT to 15006/15001 and a uid-1337 RETURN |
| §2.3 | `calico`, `portmap`, `istio-cni` — istio-cni last |
| §2.4 | ClientHello from the (restarted) client's IP, SNI `outbound_.80_._.web…`, ALPN `istio-http/1.1,istio,http/1.1`; `noside` → `000` (curl exit 56) |
| §2.5 | route `web.lab-mesh.svc.cluster.local:80` on listener 80; endpoint `<web IP>:80 HEALTHY` in `outbound\|80\|\|web.lab-mesh.svc.cluster.local` |

## 4. Break/fix

```bash
bash break.sh          # adds a second client, client-v2
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** client-v2 gets `200` from `web` with STRICT mTLS still on.

<details><summary>Hint (only after 20 minutes)</summary>

Both clients have a sidecar. Does client-v2's traffic actually go through it?
Compare the two pods' redirect rules.
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
kubectl delete ns lab-mesh
kubectl get pods | grep node-debugger | awk '{print $1}' | xargs -r kubectl delete pod
```

## 6. What I should be able to explain after this

- A sidecar mesh is NAT inside the pod: REDIRECT rules send inbound TCP to Envoy's 15006 and outbound to 15001, exempting Envoy's own uid 1337; with istio-cni those rules come from a chained CNI plugin, not a privileged init container.
- On the wire, a meshed call is TLS (Istio ALPN, SPIFFE-identity certs) on the original destination port; STRICT mode resets plaintext callers.
- Anything that bypasses the redirect (exclusion annotations, uid 1337, a missing sidecar) produces plaintext that a STRICT server refuses — the redirect is the security boundary.
