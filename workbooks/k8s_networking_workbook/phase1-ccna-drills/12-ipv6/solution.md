# Drill 12 — solution

## What was injected

<!--FAULT-->
```bash
bash "$LAB_DIR/topo.sh" up >/dev/null
setsid ip netns exec h6b python3 -m http.server 8080 --bind :: >/dev/null 2>&1 < /dev/null &
# --- the fault ---
ip netns exec h6b ip6tables -A INPUT -p ipv6-icmp -j DROP
ip -n r6 -6 neigh flush all
cat <<'T'

TICKET  After the security team "hardened" h6b ("no ping, IPv4 and IPv6"),
        nothing reaches it over IPv6 any more — not even its web server:
          ip netns exec h6a curl -m3 'http://[fd00:2::10]:8080/'   → timeout
          ip netns exec h6a curl -m3  http://10.6.2.10:8080/        → works
        h6b's IPv6 address and routes look correct.
T
```
<!--/FAULT-->

h6b drops **all ICMPv6** on input ("we don't allow ping"). That includes
Neighbor Solicitations, so h6b never answers r6's NS: r6 can't resolve
h6b's link-layer address and nothing reaches it over IPv6. IPv4 is
untouched (ARP isn't IP, so iptables-style ICMP rules don't affect it).

| Beat | Answer |
|---|---|
| Hypothesis | IPv6 dead, IPv4 fine on the same link → the IPv6-only control plane (NDP) is broken. |
| Tool | `ip -n r6 -6 neigh show dev r-b` |
| Expected if right | `fd00:2::10 … FAILED` / `INCOMPLETE`. |
| Tool 2 | `$B tcpdump -nni eth0 icmp6` while h6a pings |
| Expected if right | NS from r6 arriving, no NA leaving. |
| Tool 3 | `$B ip6tables -S` |
| Expected if right | `-A INPUT -p ipv6-icmp -j DROP`. |
| What would have told me sooner | RFC 4890's rule of thumb: never drop ICMPv6 types 1–4 (errors, incl. Packet Too Big) or 133–137 (NDP). "No ping" means dropping echo-request (128) only. |

## Fix

```bash
$B ip6tables -D INPUT -p ipv6-icmp -j DROP
$B ip6tables -A INPUT -p ipv6-icmp --icmpv6-type echo-request -j DROP    # the hardening they meant
sleep 3      # r6 is still finishing the failed resolution from before the fix; a curl right away still fails
$A curl -s -m3 -o /dev/null -w '%{http_code}\n' 'http://[fd00:2::10]:8080/'     # 200
ip -n r6 -6 neigh show dev r-b                                            # REACHABLE
```

With "no ping" the ping test itself now fails by design — prove reachability with TCP instead.
