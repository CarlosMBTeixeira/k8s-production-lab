# EgressFirewall: per-namespace egress control for traffic LEAVING the
# cluster (not pod-to-pod). Must be named "default"; rules are first-match.
apiVersion: k8s.ovn.org/v1
kind: EgressFirewall
metadata: {name: default, namespace: lab-ovn}
spec:
  egress:
    - type: Allow
      to: {dnsName: example.com}
    - type: Allow
      to: {cidrSelector: "${KIND_NET}"}   # the kind network, so the "partner" container stays reachable
    - type: Deny
      to: {cidrSelector: 0.0.0.0/0}
