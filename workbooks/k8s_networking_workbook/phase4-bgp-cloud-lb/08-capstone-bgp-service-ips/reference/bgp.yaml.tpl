# Capstone 4.08 reference — Calico side (calicoctl apply).
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata: {name: default}
spec:
  asNumber: 64512
  nodeToNodeMeshEnabled: false
  serviceExternalIPs: [{cidr: 10.202.0.0/24}]
---
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata: {name: peer-with-rr}
spec:
  nodeSelector: all()
  peerSelector: route-reflector == 'true'
---
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata: {name: lab-frr}
spec:
  peerIP: ${FRR_IP}
  asNumber: 65000
