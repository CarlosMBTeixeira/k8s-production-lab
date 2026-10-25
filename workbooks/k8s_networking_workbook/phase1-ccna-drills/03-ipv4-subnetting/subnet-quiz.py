#!/usr/bin/env python3
"""subnet-quiz.py [N] — N random IPv4 prefixes; answer network, broadcast,
first host, last host, mask and usable hosts. Timed. No calculator.
Exit criterion (Phase 1): 10 correct in under 5 minutes."""
import ipaddress, random, sys, time

def ask(prompt):
    try:
        return input(prompt).strip()
    except EOFError:
        sys.exit(0)

n = int(sys.argv[1]) if len(sys.argv) > 1 else 10
score, t0 = 0, time.time()
for i in range(1, n + 1):
    plen = random.choice([random.randint(8, 30), random.randint(20, 30), random.randint(24, 30)])
    addr = ipaddress.IPv4Address(random.choice([10 << 24, (172 << 24) | (16 << 16), (192 << 24) | (168 << 16)]) + random.randint(0, 2**16 - 1))
    net = ipaddress.IPv4Network(f"{addr}/{plen}", strict=False)
    hosts = net.num_addresses - 2
    want = {
        "network": str(net.network_address),
        "broadcast": str(net.broadcast_address),
        "first": str(net.network_address + 1),
        "last": str(net.broadcast_address - 1),
        "mask": str(net.netmask),
        "hosts": str(hosts),
    }
    print(f"\n[{i}/{n}]  {addr}/{plen}")
    ok = True
    for k in ["network", "broadcast", "first", "last", "mask", "hosts"]:
        a = ask(f"  {k:9}: ")
        if a != want[k]:
            ok = False
            print(f"            ✗ {want[k]}")
    score += ok
    print("  ✓" if ok else "  — one or more wrong")
dt = time.time() - t0
print(f"\n{score}/{n} fully correct in {dt/60:.1f} min" + ("  — exit criterion met" if score >= 10 and dt < 300 else ""))
