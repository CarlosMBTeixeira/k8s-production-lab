# BGP mode: addresses on NO network; every speaker advertises a /32 to lab-frr.
apiVersion: metallb.io/v1beta2
kind: BGPPeer
metadata: {name: lab-frr, namespace: metallb-system}
spec:
  myASN: 64512
  peerASN: 65000
  peerAddress: ${FRR_IP}
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: bgp-pool, namespace: metallb-system}
spec:
  addresses: ["10.200.0.0/28"]
---
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata: {name: bgp, namespace: metallb-system}
spec:
  ipAddressPools: [bgp-pool]
