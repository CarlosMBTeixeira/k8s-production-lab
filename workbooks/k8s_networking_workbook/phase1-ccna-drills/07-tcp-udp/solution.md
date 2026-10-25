# Drill 07 — solution

## What was injected

<!--FAULT-->
```bash
bash "$WB_DIR/phase2-linux-networking/lib/topo-crs.sh" up >/dev/null
mkdir -p /var/tmp/www; echo "hello from server" > /var/tmp/www/index.html
# --- the fault ---
setsid ip netns exec server python3 -m http.server 8080 --bind 127.0.0.1 --directory /var/tmp/www >/dev/null 2>&1 < /dev/null &
sleep 1
cat <<'T'

TICKET  The app on the server namespace "is up":
          ip netns exec server curl -s localhost:8080      → hello from server
        but from the client:
          ip netns exec client curl -m3 10.2.2.2:8080      → "Connection refused"
        No firewall rules anywhere (check: ip netns exec server nft list ruleset).
T
```
<!--/FAULT-->

The server process listens on **127.0.0.1:8080** only. From inside the
server namespace it works; from the network, nothing listens on
10.2.2.2:8080, so the kernel answers SYNs with RST: "connection refused".

| Beat | Answer |
|---|---|
| Hypothesis | Refused (fast) = the packet reached the host and nothing listens on that address:port. |
| Tool | `$S ss -ltnp` |
| Expected if right | `127.0.0.1:8080` instead of `0.0.0.0:8080` / `*:8080`. |
| What would have told me sooner | `ss -ltn` shows the bind address; "works on localhost, refused remotely" is a bind address (or a host firewall REJECT) every time. In Kubernetes, an app bound to 127.0.0.1 passes `kubectl exec curl localhost` and fails every Service call. |

## Fix

```bash
$S pkill -f 'http.server 8080'
setsid ip netns exec server python3 -m http.server 8080 --directory /var/tmp/www >/dev/null 2>&1 < /dev/null &
sleep 1; $C curl -s -m3 10.2.2.2:8080
```
