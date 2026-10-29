#!/usr/bin/env bash
# ============================================================================
# ct-exhaust.sh start|stop — RISKY: fill worker-2's conntrack table on purpose.
#   start: nf_conntrack_max on worker-2 := current count + CT_HEADROOM
#          (default 400, so the CT_HOLD held connections fill it), with an
#          AUTOMATIC rollback after 180 s; then a "holder" pod on worker-2
#          opens CT_HOLD (default 800) idle connections to the sink on worker-1.
#          Lab 4.07 runs CT_HOLD=4000 CT_HEADROOM=4500: ~90 % full, not full.
#   stop:  delete the holder, cancel the pending rollback, restore the
#          saved limit now.
# Blast radius: NEW connections from/through worker-2 (pods, kubelet probes,
# calico-node health checks) fail until the limit is restored.
# Safe to run start/stop/start back to back: start first undoes any earlier
# run (old holder gone, old rollback timer cancelled, saved limit restored),
# so a leftover timer can't reset the new run halfway through.
# ============================================================================
set -euo pipefail
export KUBECONFIG=${KUBECONFIG:-$HOME/k8slab/kubernetes/admin.conf}

# Undo a previous run on worker-2: cancel its rollback timer, restore its limit.
reset_w2() {
  ssh w-2 'if [ -f /var/tmp/ct_rollback.pid ]; then sudo kill $(cat /var/tmp/ct_rollback.pid) 2>/dev/null || true; sudo rm -f /var/tmp/ct_rollback.pid; fi
           if [ -f /var/tmp/ct_max.orig ]; then sudo sysctl -w net.netfilter.nf_conntrack_max=$(cat /var/tmp/ct_max.orig); sudo rm -f /var/tmp/ct_max.orig; fi' </dev/null
}

case "${1:-}" in
start)
  kubectl -n lab-mtu delete pod holder --ignore-not-found --wait=true >/dev/null
  reset_w2 >/dev/null
  ORIG=$(ssh w-2 cat /proc/sys/net/netfilter/nf_conntrack_max </dev/null)
  COUNT=$(ssh w-2 cat /proc/sys/net/netfilter/nf_conntrack_count </dev/null)
  HOLD=${CT_HOLD:-800}
  NEW=$((COUNT + ${CT_HEADROOM:-400}))
  echo "worker-2: count=$COUNT max=$ORIG → setting max=$NEW for 180 s, holding $HOLD connections"
  # The rollback runs detached on worker-2; its PID is saved so stop (or the
  # next start) can cancel it.
  ssh w-2 "echo $ORIG | sudo tee /var/tmp/ct_max.orig >/dev/null; \
           sudo sysctl -qw net.netfilter.nf_conntrack_max=$NEW; \
           sudo bash -c 'nohup bash -c \"sleep 180; sysctl -qw net.netfilter.nf_conntrack_max=$ORIG; rm -f /var/tmp/ct_max.orig /var/tmp/ct_rollback.pid\" >/dev/null 2>&1 & echo \$! > /var/tmp/ct_rollback.pid'" </dev/null
  SINK=$(kubectl -n lab-mtu get pod sink -o jsonpath='{.status.podIP}')
  kubectl -n lab-mtu run holder --image=nicolaka/netshoot:v0.13 --restart=Never \
    --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-2"}}}' -- \
    python3 -c "
import resource, socket, time
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))   # 1024 soft fds < CT_HOLD
held = []
for _ in range($HOLD):
    try: held.append(socket.create_connection(('$SINK', 9000), timeout=0.5))
    except OSError: pass
print('held', len(held), flush=True)
time.sleep(3600)"
  echo "holder started. Watch: ssh w-2 'cat /proc/sys/net/netfilter/nf_conntrack_count'; ssh w-2 'sudo dmesg | grep -i conntrack | tail -3'"
  ;;
stop)
  kubectl -n lab-mtu delete pod holder --ignore-not-found --wait=true
  reset_w2
  ;;
*) sed -n '3,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
