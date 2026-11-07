# Stage 3 — Floating API address (kube-vip)

With two control planes, nodes and clients need **one** API address
that keeps working when either control plane goes down. kube-vip
provides it: one instance runs on each control plane, they elect a
leader, and the leader answers ARP for a virtual IP (the VIP).

kube-vip runs as a **static pod**: kubelet starts it straight from a
file in `/etc/kubernetes/manifests/`, with no API server involved. That
matters because the VIP has to exist *before* `kubeadm init` runs —
`init` uses it as the cluster's API address.

Run this stage on **controlplane-1 and controlplane-2 only**.

## 3.1 — Pick the VIP

It must be:

- in the same subnet as the VMs (see `multipass list`),
- not used by any VM,
- unlikely to be handed out by Multipass's DHCP. The lab uses `.200`.

```bash
# WSL host — confirm nothing answers on the address you picked
ping -c 2 10.215.138.200      # expect 100% packet loss
```

## 3.2 — Write the static pod manifest

```bash
# On controlplane-1 AND controlplane-2
VIP=10.215.138.200                                              # your VIP from 3.1
IFACE=$(ip -4 route show default | awk '{print $5; exit}')      # usually ens3
echo "VIP=${VIP} IFACE=${IFACE}"

sudo mkdir -p /etc/kubernetes/manifests
cat <<EOF | sudo tee /etc/kubernetes/manifests/kube-vip.yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
    - name: kube-vip
      image: ghcr.io/kube-vip/kube-vip:v1.3.1
      imagePullPolicy: IfNotPresent
      args:
        - manager
      env:
        - name: vip_arp
          value: "true"
        - name: port
          value: "6443"
        - name: vip_interface
          value: "${IFACE}"
        - name: vip_subnet
          value: "32"
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: "kube-system"
        - name: vip_ddns
          value: "false"
        - name: svc_enable
          value: "false"
        - name: vip_leaderelection
          value: "true"
        - name: vip_leaseduration
          value: "5"
        - name: vip_renewdeadline
          value: "3"
        - name: vip_retryperiod
          value: "1"
        - name: address
          value: "${VIP}"
      securityContext:
        capabilities:
          add:
            - NET_ADMIN
            - NET_RAW
      volumeMounts:
        - mountPath: /etc/kubernetes/admin.conf
          name: kubeconfig
  hostAliases:
    - ip: 127.0.0.1
      hostnames:
        - kubernetes
  volumes:
    - name: kubeconfig
      hostPath:
        path: /etc/kubernetes/super-admin.conf
        type: FileOrCreate
EOF
```

Two details that break the cluster if changed:

- **`super-admin.conf`, not `admin.conf`** (ADR-022). Since kubeadm 1.29,
  `admin.conf` only gets cluster-admin rights near the end of `kubeadm
  init`. kube-vip needs API access earlier than that for its leader
  election, so it would fail with `403 Forbidden`. `super-admin.conf`
  has those rights from the start.
- **`vip_subnet`, not `vip_cidr`.** kube-vip 1.x silently ignores the
  old `vip_cidr` name (ADR-039).

## Check

```bash
# On controlplane-1 AND controlplane-2
sudo cat /etc/kubernetes/manifests/kube-vip.yaml | grep -A1 -E 'vip_interface|address'
```

Expected: your interface name and your VIP, not empty values.

Nothing is running yet — kubelet isn't started, so the manifest just
sits there. On controlplane-1 it comes alive during stage 4. On
controlplane-2 it stays inactive until stage 6.

Next: [Stage 4 — Start the cluster on controlplane-1](04-init-controlplane-1.md)
