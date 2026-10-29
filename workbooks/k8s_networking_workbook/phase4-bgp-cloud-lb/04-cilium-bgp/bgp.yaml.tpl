# Cilium BGP control plane, "BGPv2" API, cilium.io/v2 (stable since 1.18).
# Cilium 1.20.1 still serves v2alpha1 as well; 1.16-1.17 serve only v2alpha1.
# Check with:  kubectl api-resources | grep -i ciliumbgp
# Nodes labelled bgp=on peer with lab-frr as AS 64512 and advertise their
# PodCIDR plus LoadBalancer IPs of Services labelled bgp-advertise=true.
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata: {name: lab}
spec:
  nodeSelector: {matchLabels: {bgp: "on"}}
  bgpInstances:
    - name: "as64512"
      localASN: 64512
      peers:
        - name: lab-frr
          peerASN: 65000
          peerAddress: ${FRR_IP}
          peerConfigRef: {name: lab-frr}
---
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata: {name: lab-frr}
spec:
  timers: {holdTimeSeconds: 9, keepAliveTimeSeconds: 3}
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels: {advertise: bgp}
---
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: lab
  labels: {advertise: bgp}
spec:
  advertisements:
    - advertisementType: PodCIDR
    - advertisementType: Service
      service: {addresses: [LoadBalancerIP]}
      selector: {matchLabels: {bgp-advertise: "true"}}
---
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: bgp-pool}
spec:
  blocks: [{cidr: 10.203.0.0/28}]
