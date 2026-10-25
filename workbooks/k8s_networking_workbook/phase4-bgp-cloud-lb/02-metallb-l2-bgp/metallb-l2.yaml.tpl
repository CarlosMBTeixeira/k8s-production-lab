# L2 mode: addresses ON the kind network; one speaker answers ARP for each.
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: l2-pool, namespace: metallb-system}
spec:
  addresses: ["${L2_START}-${L2_STOP}"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: l2, namespace: metallb-system}
spec:
  ipAddressPools: [l2-pool]
