# Lab 3.11 — solution

## What was injected

<!--FAULT-->
```bash
export KUBECONFIG="${OVN_KUBECONFIG:-$HOME/ovn.conf}"
kubectl get crd egressips.k8s.ovn.org >/dev/null || { echo "OVN-K cluster not reachable with $KUBECONFIG"; exit 1; }
KIND_NET=$(docker network inspect kind | jq -r '.[0].IPAM.Config[] | select(.Subnet | test("\\.")) | .Subnet')
EIP=$(echo "$KIND_NET" | awk -F. '{print $1"."$2".0.250"}')
kubectl apply -f "$PHASE_DIR/10-ovn-k-anatomy/apps.yaml" >/dev/null
kubectl -n lab-ovn wait --for=condition=Ready pod/client --timeout=180s >/dev/null
kubectl -n lab-ovn delete egressfirewall default --ignore-not-found >/dev/null
kubectl label ns lab-ovn egress=on --overwrite >/dev/null
EIP="$EIP" envsubst < "$LAB_DIR/egressip.yaml.tpl" | kubectl apply -f - >/dev/null 2>&1
docker rm -f lab-partner >/dev/null 2>&1 || true
docker run -d --name lab-partner --network kind --cap-add NET_ADMIN nicolaka/netshoot:v0.13 \
  sh -c "iptables -A INPUT -p tcp --dport 80 ! -s $EIP -j REJECT --reject-with tcp-reset && cd /etc && python3 -m http.server 80" >/dev/null
PARTNER=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' lab-partner)
# --- the fault ---
for n in $(kubectl get nodes -o name); do kubectl label "$n" k8s.ovn.org/egress-assignable- >/dev/null 2>&1 || true; done
cat <<T

TICKET  The partner API at http://$PARTNER/ (container lab-partner on the
        kind network) only accepts connections from our agreed source IP
        $EIP. The EgressIP "lab-egress" for lab-ovn was set up months ago.
        Since last night's node replacement:
          kubectl -n lab-ovn exec client -- curl -m3 http://$PARTNER/   → "curl: (7) … Couldn't connect to server"
T
```
<!--/FAULT-->

The EgressIP exists and selects lab-ovn, but **no node carries
`k8s.ovn.org/egress-assignable`**, so it's assigned to nobody. OVN-K falls
back to normal egress: SNAT to the node IP. The partner only accepts the
EgressIP and rejects everything else.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | The partner rejects us → our source IP isn't the allowlisted one → the EgressIP isn't in effect. |
| Tool | `kubectl get egressip lab-egress -o yaml` |
| Expected if right | `spec.egressIPs: [<EIP>]` (OVN-K defaults `egressNodeSelector` to the `egress-assignable` label) but `status.items: []`. |
| Tool 2 | `kubectl get nodes -l k8s.ovn.org/egress-assignable` |
| Expected if right | `No resources found`. |
| Tool 3 (proof on the wire) | netshoot in `lab-partner`'s netns: `docker run --rm --net container:lab-partner --privileged nicolaka/netshoot:v0.13 tcpdump -nni eth0 -c2 tcp port 80` |
| Expected if right | SYNs from a node IP, answered with RST (`REJECT --reject-with tcp-reset`); a RST to a SYN is what curl reports as "Couldn't connect". |
| What would have told me sooner | EgressIP status is the contract: alert when an EgressIP has no assigned node (a check on `.status.items`; OVN-K also exports EgressIP metrics — find their names in your version's `/metrics`). Node replacements that drop the `egress-assignable` label are the usual real-world cause — make the label part of the machine pool definition (on OpenShift: the MachineSet/MachineConfigPool labels). |

## Fix

```bash
kubectl label node ovn-worker k8s.ovn.org/egress-assignable=""
kubectl get egressip lab-egress -o jsonpath='{.status.items}'; echo
kubectl -n lab-ovn exec client -- curl -s -m3 http://<partner IP>/ | head -3
```

## Why it matters later

On OpenShift on a cloud, an EgressIP must also be assignable to the node's
cloud NIC (`cloud.network.openshift.io/egress-ipconfig` annotation shows the
capacity). "EgressIP not assigned" there can also mean "cloud quota for
secondary IPs reached".
