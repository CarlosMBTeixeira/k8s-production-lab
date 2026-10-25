# Lab 3.12 — The service mesh datapath

| | |
|---|---|
| **Objective** | See what a sidecar mesh does to a pod's network namespace — the redirect rules istio-cni installs, the Envoy listeners they feed, and mTLS on the wire — at the packet level, not the CRD level. |
| **Time** | 3 h (week 17) |
| **Where** | k8slab, 2 workers, **option 8** (Istio + Kiali) · WSL host |
| **Risk** | Safe — `lab-mesh` only; the mesh install itself is the pipeline's |

The Istio workbook (`../../istio_svc_mesh_workbook/`) covers operating the
mesh — routing, resilience, security policy. This lab is only the plumbing
underneath, so the two don't overlap; its session 0 follows a request
through Envoy's config and is the natural next read.

## 1. Prerequisites

- Labs 2.04, 2.05, 3.01. `istioctl` on the host (`../../scripts/install-istioctl.sh`).

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
```

With istio-cni there is no privileged `istio-init` container rewriting
iptables; at most a short `istio-validation` init container checks that the
CNI plugin did its job.

### 2.2 The rules inside the pod's netns

```bash
kubectl -n lab-mesh debug -it $CL --image=nicolaka/netshoot:v0.13 --profile=netadmin --target=netshoot -- sh
# inside (shares the pod's netns):
iptables-save -t nat | grep -E '^(:|-A) ISTIO'     # if empty: nft list ruleset (newer Istio can use nftables)
ss -ltnp                                          # envoy: 15001 (outbound), 15006 (inbound), 15090, 15021, 15000 (admin, localhost)
```

Read the chains:

| Chain / rule | Meaning |
|---|---|
| `PREROUTING -j ISTIO_INBOUND` → `ISTIO_IN_REDIRECT` → `REDIRECT --to-ports 15006` | every inbound TCP to the app goes to Envoy's inbound listener first |
| `OUTPUT -j ISTIO_OUTPUT` → `ISTIO_REDIRECT` → `REDIRECT --to-ports 15001` | every outbound TCP from the app goes to Envoy's outbound listener |
| `-m owner --uid-owner 1337 -j RETURN` | Envoy's own traffic (uid 1337) is not redirected — or it would loop |
| `-d 127.0.0.6/32 -j RETURN`, exclusions for 15090/15021 | inbound passthrough, metrics, health |

It's lab 2.05's REDIRECT/DNAT, applied inside one pod, so the app never
knows the proxy exists.

### 2.3 Who installed them: istio-cni chained onto Calico

```bash
NODE=$(kubectl -n lab-mesh get pod $CL -o jsonpath='{.spec.nodeName}')
ssh ${NODE/worker-/w-} "sudo ls /etc/cni/net.d/; sudo cat /etc/cni/net.d/10-calico.conflist | jq -r '.plugins[].type'"
```

`calico`, `bandwidth`, `portmap`, **`istio-cni`**: containerd runs the chain
in order for every pod. Calico wires the network; istio-cni writes the
redirect rules into the new netns. That's ADR-038's design, and why
ADR-040 had to raise inotify limits (istio-cni watches that directory).

### 2.4 mTLS on the wire

```bash
WEB=$(kubectl -n lab-mesh get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
WNODE=$(kubectl -n lab-mesh get pod -l app=web -o jsonpath='{.items[0].spec.nodeName}')
kubectl debug node/$WNODE -it --profile=sysadmin --image=nicolaka/netshoot:v0.13
# inside (node netns): find web's cali interface, then
CALI=$(ip route get <WEB IP> | grep -o 'cali[0-9a-f]*')
tshark -i $CALI -f 'tcp port 80' -Y 'tls.handshake.type == 1' -T fields -e ip.src -e tls.handshake.extensions_server_name -e tls.handshake.extensions_alpn_str
```

```bash
# WSL host, while tshark runs
kubectl -n lab-mesh exec $CL -c netshoot -- curl -s -o /dev/null -w '%{http_code}\n' web          # 200
kubectl -n lab-mesh exec noside -- curl -s -m3 -o /dev/null -w '%{http_code}\n' web                # 000: reset
```

The meshed client's request arrives at web's veth as a **TLS ClientHello**
on port 80, ALPN `istio-peer-exchange,istio,…`, SNI
`outbound_.80_._.web.lab-mesh.svc.cluster.local`. The app sent plain HTTP;
its sidecar upgraded it. `noside` sends plaintext and web's sidecar, under
STRICT, resets it. Exit the debug shell and delete the debug pod.

### 2.5 Envoy's side of the same request

```bash
istioctl proxy-config listeners $CL.lab-mesh --port 15001
istioctl proxy-config clusters  $CL.lab-mesh | grep web.lab-mesh
istioctl proxy-config endpoints $CL.lab-mesh | grep "$WEB"
istioctl x describe pod $CL -n lab-mesh
```

## 3. Verification

| Check | Expected |
|---|---|
| §2.2 | ISTIO_INBOUND/ISTIO_OUTPUT chains with REDIRECT to 15006/15001 and a uid-1337 RETURN |
| §2.3 | `istio-cni` last in the plugin chain |
| §2.4 | ClientHello with Istio ALPN from the client's IP; `noside` → `000` |
| §2.5 | outbound cluster `outbound|80||web.lab-mesh.svc.cluster.local` with web's pod IP as endpoint |

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
