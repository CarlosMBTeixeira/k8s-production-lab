# Drill 08 — solution

## What was injected

<!--FAULT-->
```bash
cd "$PHASE_DIR/topo"
containerlab destroy -t dns.clab.yml --cleanup >/dev/null 2>&1 || true
# --- the fault (part 1): a forgotten test record in the zone ---
cat > dns/lab.local.zone <<'ZONE'
$ORIGIN lab.local.
$TTL 300
@       IN SOA  ns1.lab.local. admin.lab.local. ( 2026102602 3600 600 86400 60 )
@       IN NS   ns1
ns1     IN A    10.53.0.53
web     IN A    10.53.0.80
www     IN CNAME web
db      IN A    10.53.0.81
        IN AAAA fd00:53::81
@       IN MX   10 mail
mail    IN A    10.53.0.25
_http._tcp.web IN SRV 0 50 80 web
@       IN TXT  "v=lab1"
www.example.com IN A 10.53.0.99   ; test record, "temporary"
ZONE
containerlab deploy -t dns.clab.yml >/dev/null && bash dns-setup.sh >/dev/null
# --- the fault (part 2): resolver aligned "with Kubernetes defaults" ---
docker exec clab-p1d-client sh -c 'printf "nameserver 10.53.0.53\nsearch lab.local\noptions ndots:5\n" > /etc/resolv.conf'
cat <<'T'

TICKET  On the client, apps calling www.example.com hit the wrong server:
          docker exec clab-p1d-client getent hosts www.example.com   → 10.53.0.99
        but whoever checks with dig sees the right address:
          docker exec clab-p1d-client dig +short www.example.com     → (a public IP)
        "DNS is fine, it's the app." The resolver settings were recently
        aligned with the Kubernetes defaults — keep ndots at 5.
T
```
<!--/FAULT-->

Two things that are harmless alone: the client now uses `ndots:5` (as
Kubernetes pods do), and the `lab.local` zone contains a forgotten test
record `www.example.com.lab.local`. `www.example.com` has 2 dots (< 5), so
the C library tries the search domain **first** — and that name exists. The
application connects to 10.53.0.99; `dig` (no search list) shows the real
public address, which is why it looks fine to whoever checks with dig.

| Beat | Answer |
|---|---|
| Hypothesis | dig and the application disagree → the client library is asking a different name (search/ndots). |
| Tool | `c 'tcpdump -nni eth1 -c4 udp port 53' &` then `c 'getent hosts www.example.com'` |
| Expected if right | the first query is `www.example.com.lab.local`, answered with 10.53.0.99. |
| Tool 2 | `c 'cat /etc/resolv.conf'`; `c 'dig +short www.example.com.lab.local'` |
| Expected if right | `ndots:5`; the stale record. |
| What would have told me sooner | Compare `getent hosts` (what apps see) with `dig` (what the server says), always. In Kubernetes the same trap exists with `ndots:5` and the cluster's search domains — a Service or a wildcard record in a search domain can shadow an external name. |

## Fix

Remove the stale record (the real bug); a trailing dot in the app's config
(`www.example.com.`) is the defensive fix.

```bash
cd ~/wb/phase1-ccna-drills/topo
grep -v 'www.example.com' dns/lab.local.zone | sed 's/2026102602/2026102603/' > /tmp/zone && cat /tmp/zone > dns/lab.local.zone
docker restart clab-p1d-dns >/dev/null; sleep 2
c 'getent hosts www.example.com; dig +short www.example.com'
```
