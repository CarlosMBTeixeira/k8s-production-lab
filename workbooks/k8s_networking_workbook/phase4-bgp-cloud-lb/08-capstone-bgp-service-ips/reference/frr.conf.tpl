frr defaults datacenter
hostname lab-frr
log stdout informational
service integrated-vtysh-config
!
! Capstone 4.08 — the fabric router. Accepts ONLY the Service range from the
! cluster (no pod CIDRs leak into the fabric), ECMPs across nodes, and keeps
! hold time short so a dead node is withdrawn in ~9 s.
ip prefix-list CLUSTER-IN seq 10 permit 10.202.0.0/24 le 32
!
router bgp 65000
 bgp router-id ${FRR_IP}
 no bgp ebgp-requires-policy
 neighbor CLUSTER peer-group
 neighbor CLUSTER remote-as 64512
 neighbor CLUSTER timers 3 9
 bgp listen range ${KIND_NET} peer-group CLUSTER
 !
 address-family ipv4 unicast
  neighbor CLUSTER prefix-list CLUSTER-IN in
  maximum-paths 8
 exit-address-family
!
