# Lab 3.11 — OVN-Kubernetes operations: the OpenShift view

| | |
|---|---|
| **Objective** | Operate the OVN-K features OpenShift platforms use every day — EgressIP, EgressFirewall, AdminNetworkPolicy — and map every command in this phase to its OpenShift equivalent. |
| **Time** | 5 h (week 16) |
| **Where** | kind cluster `ovn` from lab 3.10 · optional: CRC from `~/openshift-local-lab` for §2.5 (k8slab and kind down) |
| **Risk** | Safe — disposable cluster; one helper container (`lab-ext`/`lab-partner`) on the kind Docker network |

## 1. Prerequisites

- Lab 3.10, with the cluster still up.

```bash
export KUBECONFIG=$HOME/ovn.conf
cd <workbook>/phase3-k8s-networking/11-ovn-k-operations
kubectl apply -f ../10-ovn-k-anatomy/apps.yaml && kubectl -n lab-ovn wait --for=condition=Ready pod/client
KIND_NET=$(docker network inspect kind | jq -r '.[0].IPAM.Config[] | select(.Subnet | test("\\.")) | .Subnet'); echo $KIND_NET
EIP=$(echo $KIND_NET | awk -F. '{print $1"."$2".0.250"}'); echo $EIP     # an unused address on the node network
docker run -d --name lab-ext --network kind traefik/whoami:v1.10.3
EXT=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lab-ext)
```

`lab-ext` is "a server outside the cluster": it reports the source
address it sees.

## 2. Hands-on

### 2.1 Default egress: SNAT to the node

```bash
kubectl -n lab-ovn exec client -- curl -s http://$EXT/ | grep RemoteAddr
kubectl -n lab-ovn get pod client -o wide       # which node? its IP is what lab-ext saw
```

North-south traffic leaves through the node's gateway router (`GR_<node>`)
and is SNATed to the node IP — the equivalent of Calico's natOutgoing.

### 2.2 EgressIP: a stable source address per namespace

```bash
kubectl label node ovn-worker k8s.ovn.org/egress-assignable=""
kubectl label ns lab-ovn egress=on
export EIP; envsubst < egressip.yaml.tpl | kubectl apply -f -
kubectl get egressip lab-egress -o yaml | sed -n '/^status:/,$p'      # assigned to ovn-worker
kubectl -n lab-ovn exec client -- curl -s http://$EXT/ | grep RemoteAddr   # $EIP, from any node the pod runs on
docker exec ovn-worker ip -br addr | grep -F "$EIP"                     # the node now owns it (answers ARP)
```

Failover:

```bash
kubectl label node ovn-worker2 k8s.ovn.org/egress-assignable=""
kubectl label node ovn-worker k8s.ovn.org/egress-assignable-
kubectl get egressip lab-egress -o jsonpath='{.status.items}'; echo   # moves to ovn-worker2
kubectl -n lab-ovn exec client -- curl -s http://$EXT/ | grep RemoteAddr
```

This is how OpenShift tenants get a fixed source IP for an external
firewall allowlist. The IP must be in the node's subnet (or, on clouds,
assignable to the node's NIC).

### 2.3 EgressFirewall: what a namespace may reach outside

```bash
export KIND_NET; envsubst < egressfirewall.yaml.tpl | kubectl apply -f -
kubectl -n lab-ovn get egressfirewall default -o jsonpath='{.status}'; echo   # "EgressFirewall Rules applied"
kubectl -n lab-ovn exec client -- curl -s -m5 -o /dev/null -w '%{http_code}\n' http://example.com   # 200
kubectl -n lab-ovn exec client -- curl -s -m5 -o /dev/null -w '%{http_code}\n' http://example.org   # 000
kubectl -n lab-ovn exec client -- curl -s -m5 -o /dev/null -w '%{http_code}\n' web                  # 200: pod-to-pod isn't affected
kubectl -n lab-ovn delete egressfirewall default
```

One per namespace, named `default`, first match wins, applies only to
traffic leaving the cluster. `dnsName` rules resolve names in ovnkube
itself and track TTLs (compare with Cilium's `toFQDNs` in lab 3.08).

### 2.4 AdminNetworkPolicy: the cluster admin's tier

```bash
kubectl get crd | grep policy.networking.k8s.io    # adminnetworkpolicies, baselineadminnetworkpolicies
```

If the CRDs are missing, re-create the cluster with `kind.sh`'s ANP option
(lab 3.10 §1) — or read this section and move on.

```bash
kubectl apply -f anp.yaml && kubectl -n lab-ovn-untrusted wait --for=condition=Ready pod/intruder
kubectl -n lab-ovn-untrusted exec intruder -- curl -s -m3 -o /dev/null -w '%{http_code}\n' web.lab-ovn   # 000
kubectl -n lab-ovn get networkpolicy allow-all-ingress                    # the namespace allows everything…
kubectl get adminnetworkpolicy lab-deny-untrusted -o yaml | sed -n '/^status:/,$p'
```

Evaluation order: **ANP** (by priority; Allow/Deny are final, Pass hands
down) → **NetworkPolicy** → **BaselineAdminNetworkPolicy**. The namespace
owner can't override an admin Deny, and on OpenShift `oc get networkpolicy`
won't show it — `oc get anp,banp` will.

### 2.5 The OpenShift map

Fill the last column on CRC if you have it up (`~/openshift-local-lab`),
otherwise from the Red Hat OpenShift docs ("OVN-Kubernetes network plugin"
and "Troubleshooting network issues").

| Task | kind (this lab) | OpenShift | Checked |
|---|---|---|---|
| OVN-K pods | `kubectl -n ovn-kubernetes get pods` | `oc -n openshift-ovn-kubernetes get pods` (ovnkube-node: `nbdb`, `sbdb`, `ovnkube-controller`, `ovn-controller` containers) | |
| NB database | `kubectl exec … -c nb-ovsdb -- ovn-nbctl show` | `oc -n openshift-ovn-kubernetes exec <ovnkube-node> -c nbdb -- ovn-nbctl show` | |
| Node shell | `docker exec -it ovn-worker bash` | `oc debug node/<node>` then `chroot /host` (tools: `toolbox`) | |
| Capture on a node | netshoot in the node netns | `oc debug node/<node>` → `toolbox` → `tcpdump`; or the docs' `oc debug` + `tcpdump -i any -w` procedure | |
| Trace a flow | `ovnkube-trace` from the repo build | `ovnkube-trace` copied out of a cluster pod (docs: "Tracing Openflow with ovnkube-trace") | |
| Cluster network config | kind.sh flags | `oc get network.config cluster -o yaml`, `oc get network.operator cluster -o yaml` (MTU, gateway mode, IPsec) | |
| EgressIP / EgressFirewall / ANP | same CRDs | same CRDs: `oc get egressip`, `oc get egressfirewall -A`, `oc get anp,banp` | |
| Ingress | Gateway API (lab 3.09) | Routes + IngressController (`oc -n openshift-ingress-operator get ingresscontroller`), router pods in `openshift-ingress`; Gateway API in newer releases | |
| Support data | — | `oc adm must-gather -- gather_network_logs` | |

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | RemoteAddr = the client's node IP |
| §2.2 | RemoteAddr = `$EIP`; status moves to ovn-worker2 on relabel |
| §2.3 | example.com 200, example.org 000, in-cluster 200 |
| §2.4 | intruder 000 despite `allow-all-ingress` |

## 4. Break/fix

```bash
bash break.sh          # sets up a "partner" that only accepts our EgressIP
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `kubectl -n lab-ovn exec client -- curl -s -m3 http://<partner IP>/`
returns the partner's directory listing.

<details><summary>Hint (only after 20 minutes)</summary>

The EgressIP object exists. Does anyone own it?
</details>

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
docker rm -f lab-ext lab-partner 2>/dev/null
kubectl delete egressip lab-egress --ignore-not-found
kubectl delete -f anp.yaml --ignore-not-found
kubectl delete ns lab-ovn --ignore-not-found
for n in ovn-worker ovn-worker2; do kubectl label node $n k8s.ovn.org/egress-assignable- 2>/dev/null; done
kind delete cluster --name ovn          # end of the OVN-K labs
```

## 6. What I should be able to explain after this

- Default pod egress is SNATed to the node IP at the gateway router; EgressIP gives a namespace a fixed source IP owned by a labelled (`egress-assignable`) node, with failover between such nodes.
- EgressFirewall is a per-namespace, first-match allow/deny list for traffic leaving the cluster (CIDRs and DNS names); it doesn't touch pod-to-pod traffic.
- AdminNetworkPolicy → NetworkPolicy → BaselineAdminNetworkPolicy is the evaluation order; an admin Deny beats any namespace policy — and the OpenShift commands for all of this.
