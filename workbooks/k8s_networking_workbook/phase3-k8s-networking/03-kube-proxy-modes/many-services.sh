#!/usr/bin/env bash
# many-services.sh <N> [delete] — N extra ClusterIP Services on the same
# web pods, to see how each kube-proxy mode scales. Uses the current context.
set -euo pipefail
N=${1:?usage: many-services.sh <N> [delete]}
if [ "${2:-}" = delete ]; then
  kubectl -n lab-modes delete svc -l lab=many --wait=false; exit 0
fi
for i in $(seq 1 "$N"); do
cat <<YAML
---
apiVersion: v1
kind: Service
metadata: {name: web-$i, namespace: lab-modes, labels: {lab: many}}
spec:
  selector: {app: web}
  ports: [{name: http, port: 80, targetPort: http}]
YAML
done | kubectl apply -f - >/dev/null
echo "created $N Services"
