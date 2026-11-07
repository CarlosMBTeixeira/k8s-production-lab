# Stage 1 — Create the VMs

Four Ubuntu 24.04 VMs: 2 vCPU, 4 GB RAM and 20 GB disk each. Multipass
creates the `ubuntu` user and sets the hostname from `--name`.

```bash
# WSL host
for vm in controlplane-1 controlplane-2 worker-1 worker-2; do
    multipass launch 24.04 --name "$vm" --cpus 2 --memory 4G --disk 20G
done
```

Each launch takes a minute or two.

## Check

```bash
# WSL host
multipass list
```

Expected: 4 VMs in state `Running`, each with an IPv4 address in the
same subnet (e.g. `10.215.138.x`). Note the subnet — you'll need it to
pick the VIP in stage 3.

Confirm you can get a shell on each one:

```bash
# WSL host
for vm in controlplane-1 controlplane-2 worker-1 worker-2; do
    multipass exec "$vm" -- hostname
done
```

Expected: the four VM names, one per line.

Next: [Stage 2 — Prepare every node](02-prepare-nodes.md)
