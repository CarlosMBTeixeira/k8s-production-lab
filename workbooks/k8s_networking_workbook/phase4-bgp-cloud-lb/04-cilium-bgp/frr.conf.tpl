frr defaults datacenter
hostname lab-frr
log stdout informational
service integrated-vtysh-config
!
! Upstream router: AS 65000. Any kind node may open a session (dynamic
! neighbors from the kind subnet), as AS 64512.
router bgp 65000
 bgp router-id ${FRR_IP}
 no bgp ebgp-requires-policy
 neighbor CLUSTER peer-group
 neighbor CLUSTER remote-as 64512
 bgp listen range ${KIND_NET} peer-group CLUSTER
 !
 address-family ipv4 unicast
  maximum-paths 8
 exit-address-family
!
