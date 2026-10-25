# Lab 4.05 — solution

## What was injected

<!--FAULT-->
```bash
cd "$LAB_DIR"
containerlab destroy -t topo.clab.yml --cleanup >/dev/null 2>&1 || true
# --- the fault: the "migrated" on-prem resolver config ---
cat > dnso/Corefile <<'COREFILE'
# On-prem resolver (172.20.2.53) — migrated to the new DNS platform.
corp.lab:53 {
    hosts {
        172.20.1.10 app.corp.lab
    }
    log
}
.:53 {
    hosts {
        203.0.113.10 storage.privatelink.lab
        fallthrough
    }
    log
}
COREFILE
containerlab deploy -t topo.clab.yml >/dev/null
bash post-deploy.sh >/dev/null
sleep 5
cat <<'T'

TICKET  After last night's DNS server migration on-prem, the on-prem app
        (o1) can't reach the storage account through its private endpoint:
          docker exec clab-cloud-o1 curl -m5 http://storage.privatelink.lab   → timeout
        From VPC-A (a1) the same URL works. Routing between on-prem and
        VPC-A is fine (o1 pings 10.10.3.10).
T
```
<!--/FAULT-->

The "migrated" on-prem resolver lost its conditional forwarder for
`privatelink.lab`. The name now falls through to the `.` zone — "the
internet" — which answers the **public** address 203.0.113.10. On-prem has
no path to it. VPC-A's resolver is untouched, so a1 still gets 10.10.3.10.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | Same name, different answer per client → the resolver chain differs; on-prem's is wrong. |
| Tool | `x o1 'dig +short storage.privatelink.lab'` vs `x a1 'dig +short storage.privatelink.lab'` |
| Expected if right | o1: 203.0.113.10; a1: 10.10.3.10. |
| Tool 2 | `x o1 'dig +short @10.10.2.53 storage.privatelink.lab'` (ask the inbound endpoint directly) and `x o1 'dig +short @172.20.2.53 storage.privatelink.lab'` |
| Expected if right | inbound endpoint: 10.10.3.10 (the cloud side is fine, and reachable); on-prem resolver: 203.0.113.10. |
| Tool 3 | `docker logs clab-cloud-dnsc` during the lookup; `cat dnso/Corefile` |
| Expected if right | no query from 172.20.2.53 reaches dnsc; no `privatelink.lab` stanza in dnso's Corefile. |
| What would have told me sooner | A synthetic check from on-prem that asserts the **private** answer (`dig storage.privatelink.lab` ∈ 10.10.0.0/16), not just "resolves". DNS server migrations are where conditional forwarders get lost. |

## Fix

```bash
cat >> dnso/Corefile <<'EOF'
privatelink.lab:53 {
    forward . 10.10.2.53
    log
}
EOF
docker restart clab-cloud-dnso
x o1 'dig +short storage.privatelink.lab; curl -s -m3 http://storage.privatelink.lab'
```

(Appending with `>>` keeps the file's inode, so the bind mount sees it.)

## Why it matters later

In AKS/OpenShift on Azure the same chain includes CoreDNS (cluster) →
node/VNet DNS → Private DNS Resolver → on-prem. A pod getting a public IP
for a `privatelink` name is this incident one layer further in: check
CoreDNS's `forward` target and the VNet's DNS servers (lab 3.04).
