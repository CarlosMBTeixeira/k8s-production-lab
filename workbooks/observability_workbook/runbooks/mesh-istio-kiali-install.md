# Runbook — Istio + Kiali install (and the rebuild that preceded it)

Date: 2026-10-23 · Cluster: k8slab (1 worker, 8G) · Session: mesh (outside the 01–06 sequence)

## What this covers

Bringing up Istio (sidecar + istio-cni) and Kiali on a kubeadm cluster
that already runs kube-prometheus-stack, and the failures on the way:
a VM that never boots, a health check that blocks new branches, a CNI
agent starved of inotify instances, and a verify step that could not
work against Prometheus 3.x. ADR-038, ADR-039, ADR-040.

## Table

| Symptom | Tool | Cause | Fix | What would have told me this first |
|---|---|---|---|---|
| `multipass launch` fails: `worker-2: timed out waiting for response`; `multipass list` shows it `Unknown` with no IP | `ps -o pid,etime,time,rss -p <qemu pid>` and `grep <mac> …/multipassd/network/dnsmasq.leases` | Guest hung in early boot (nested KVM under WSL2). It never sent a DHCP request, so Multipass waited for SSH that could not come up | Kill the QEMU process, `multipass delete <vm> && multipass purge`, rebuild. Not reproducible on the next run | QEMU at ~100% CPU for minutes with **~76 MB RSS**, while booted siblings sat at ~1.4 GB. A booted guest grows its memory within seconds |
| `lab-management.sh rebuild` sits at `Deleting worker-2...` indefinitely | `journalctl -u snap.multipass.multipassd \| grep -v boot-finished \| tail` | Delete sends ACPI powerdown; a hung guest never answers it | Kill the QEMU PID. `multipass delete` then reports a crash, which aborts the script under `set -e`; finish with `multipass delete <vm>; multipass purge` | The same hung-guest signal above, before deciding to delete at all |
| `main.sh` stops after the VMs build: `❌ in sync with origin`, `1 check(s) failed` | `git rev-parse --abbrev-ref @{u}` → `no upstream configured` | `morning-check.sh` compared `HEAD` with `@{u}`; a never-pushed feature branch has no `@{u}`, and the non-zero exit of the last build step aborts `main.sh` | Check now runs only when an upstream exists, otherwise ⚠️ informational. Or `git push -u origin <branch>` | `git status -sb` on a new branch shows no `...origin/` part |
| `istio-cni-node` `CrashLoopBackOff` on worker-1 only; control-plane pods fine | `kubectl logs -n istio-system <pod> --previous` → `couldn't initialize inotify: too many open files`; then on the node `sysctl fs.inotify.max_user_instances` | Per-user inotify instance limit (Ubuntu default 128) exhausted by root: kubelet, containerd and every file-watching pod on the single worker. 128/128 in use | `sysctl -w fs.inotify.max_user_instances=8192 fs.inotify.max_user_watches=524288` on every node, persist in `/etc/sysctl.d/`, delete the pod. Permanent: `kernel_prereqs_sysctls` (ADR-040) | Counting instances before adding a stack: `sudo find /proc/*/fd -lname anon_inode:inotify \| wc -l` was already at the limit. The pod on a busier node failing while identical pods elsewhere run points at a node resource, not config |
| 09 ends with `WARNING: no istio_requests_total in Prometheus yet`, but Kiali's graph is full | `kubectl exec … prometheus-…-0 -c prometheus -- wget …` → `exec: "wget": executable file not found` | Prometheus 3.x image ships no wget/curl; the check could never succeed | Query through the API server instead: `kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query=sum(istio_requests_total)"` | Running the check by hand once before trusting it in a script; a warning that fires on a working system is a broken check |

## Verifying the mesh end to end (commands that worked)

```bash
# sidecars everywhere (native sidecars live in initContainers)
kubectl get pods -n bookinfo                     # READY 2/2

# scrape targets
kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/targets?state=active" \
  | grep -o '"scrapePool":"[^"]*istio[^"]*"' | sort | uniq -c

# who calls whom, from the metrics Kiali uses
#   sum by (source_workload,destination_workload,response_code)
#     (rate(istio_requests_total{reporter="destination"}[1m]))

# Envoy access logs (LogQL)
#   {namespace="bookinfo", container="istio-proxy"} |= "GET /productpage"
```

## Things that surprised me

- The predicted risk was Istio 1.30 against the newer Gateway API CRD
  bundle (v1.6.1 from Envoy Gateway 1.9.2). It worked first time. The
  failure came from the node instead, from a kernel default nobody had
  touched because nothing before needed one more inotify instance.
- The mesh cost less memory than estimated (~1.4Gi of requests, not
  1.5–2Gi). CPU requests (1300m of 2 vCPU) are now the tighter budget on
  the single worker.
- `istio-cni` removes its own binary and CNI config when it exits, so a
  crash-looping agent breaks *new* pods on that node while existing ones
  keep working. A healthy-looking Bookinfo can hide a broken node until
  the next rollout.

## Still open

- Rebuild once more to confirm the Ansible sysctl change applies from
  scratch (the live fix was applied by hand).
- `fix` for the hung-VM case is manual; `lab-management.sh` could detect
  a low-RSS QEMU after launch and retry.
- **kube-vip dropped the control-plane VIP once** (15:37:59, ~55 min after
  the build): cp-1 failed a lease renewal with `context deadline exceeded`
  while the control planes were at load ~3.9 on 2 vCPU, logged `lost
  leadership, restarting kube-vip`, and cp-2 took the VIP. Clients saw
  one `connection reset by peer` on :6443. The template's lease timings
  (`vip_leaseduration 5`, `vip_renewdeadline 3`, `vip_retryperiod 1`)
  leave no slack under CPU pressure; kube-vip's own defaults are 15/10/2.
  Not changed yet — candidate for an ADR after seeing whether it recurs.
