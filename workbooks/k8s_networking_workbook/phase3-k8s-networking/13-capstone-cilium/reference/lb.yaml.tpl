# Reference — LB IPAM pool on the kind network + L2 announcements on eth0.
# API versions move between Cilium releases. On 1.20 the pool is cilium.io/v2
# only, the L2 policy still cilium.io/v2alpha1
# (check: kubectl api-resources | grep -iE 'ippool|l2announcement').
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata: {name: lab-pool}
spec:
  blocks: [{start: "${LB_START}", stop: "${LB_STOP}"}]
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata: {name: lab-l2}
spec:
  loadBalancerIPs: true
  interfaces: ["^eth0$"]
