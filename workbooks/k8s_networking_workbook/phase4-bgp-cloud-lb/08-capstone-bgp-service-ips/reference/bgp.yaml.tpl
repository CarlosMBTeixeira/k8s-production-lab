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
# Each node tells the fabric only about routes it originates. Without this,
# every node re-exports the /32s the RR reflected to it (next-hop-self):
# nodes without endpoints join the ECMP set and drop their share under Local.
# keepOriginalNextHop (4.03) hides that from verify.sh, but the reflected
# copies of a DEAD node's /32 then live on until the iBGP hold timer
# (BIRD default 240 s, not tunable in Calico OSS) — FRR's 9 s is bypassed.
apiVersion: projectcalico.org/v3
kind: BGPFilter
metadata: {name: own-routes-only}
spec:
  exportV4:
    - {source: RemotePeers, action: Reject}
---
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata: {name: lab-frr}
spec:
  peerIP: ${FRR_IP}
  asNumber: 65000
  filters: [own-routes-only]
