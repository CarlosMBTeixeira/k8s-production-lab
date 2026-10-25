#!/usr/bin/env bash
# ============================================================================
# ct-exhaust.sh start|stop — RISKY: fill worker-2's conntrack table on purpose.
#   start: nf_conntrack_max on worker-2 := current count + 400, with an
#          AUTOMATIC rollback after 180 s; then a "holder" pod on worker-2
#          opens 800 idle connections to the sink on worker-1.
#   stop:  delete the holder, restore the saved limit now.
# Blast radius: NEW connections from/through worker-2 (pods, kubelet probes,
# calico-node health checks) fail until the limit is restored.
# ============================================================================
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/k8slab/kubernetes/admin.conf}
case "${1:-}" in
start)
  ORIG=$(ssh w-2 cat /proc/sys/net/netfilter/nf_conntrack_max)
  COUNT=$(ssh w-2 cat /proc/sys/net/netfilter/nf_conntrack_count)
  ssh w-2 "echo $ORIG | sudo tee /var/tmp/ct_max.orig >/dev/null"
  NEW=$((COUNT + 400))
  echo "worker-2: count=$COUNT max=$ORIG → setting max=$NEW for 180 s"
  ssh w-2 "sudo sysctl -qw net.netfilter.nf_conntrack_max=$NEW; \
           sudo nohup bash -c 'sleep 180; sysctl -qw net.netfilter.nf_conntrack_max=$ORIG' >/dev/null 2>&1 &"
  SINK=$(kubectl -n lab-mtu get pod sink -o jsonpath='{.status.podIP}')
  kubectl -n lab-mtu run holder --image=nicolaka/netshoot:v0.13 --restart=Never \
    --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-2"}}}' -- \
    python3 -c "
import socket, time
held = []
for _ in range(800):
    try: held.append(socket.create_connection(('$SINK', 9000), timeout=0.5))
    except OSError: pass
print('held', len(held), flush=True)
time.sleep(3600)"
  echo "holder started. Watch: ssh w-2 'cat /proc/sys/net/netfilter/nf_conntrack_count'; ssh w-2 'sudo dmesg | grep -i conntrack | tail -3'"
  ;;
stop)
  kubectl -n lab-mtu delete pod holder --ignore-not-found --wait=false
  ssh w-2 'if [ -f /var/tmp/ct_max.orig ]; then sudo sysctl -w net.netfilter.nf_conntrack_max=$(cat /var/tmp/ct_max.orig); fi'
  ;;
*) sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
