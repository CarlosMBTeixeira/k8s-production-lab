# projectcalico.org/v3 — apply with calicoctl.
# AS 64512 for the cluster; advertise the Service CIDR and an externalIPs range
# to every BGP peer; peer every node with lab-frr (AS 65000).
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata: {name: default}
spec:
  asNumber: 64512
  nodeToNodeMeshEnabled: true
  serviceClusterIPs: [{cidr: 10.96.0.0/16}]
  serviceExternalIPs: [{cidr: 10.202.0.0/24}]
---
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata: {name: lab-frr}
spec:
  peerIP: ${FRR_IP}
  asNumber: 65000
