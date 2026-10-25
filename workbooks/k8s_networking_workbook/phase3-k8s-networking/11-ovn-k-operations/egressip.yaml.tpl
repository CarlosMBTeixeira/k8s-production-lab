# EgressIP: pods in namespaces labelled egress=on leave the cluster with
# source ${EIP}, from whichever node is labelled k8s.ovn.org/egress-assignable.
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata: {name: lab-egress}
spec:
  egressIPs: ["${EIP}"]
  namespaceSelector: {matchLabels: {egress: "on"}}
