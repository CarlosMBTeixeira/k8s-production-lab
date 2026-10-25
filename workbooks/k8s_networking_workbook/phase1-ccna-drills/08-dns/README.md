# Drill 08 — DNS resolution

| | |
|---|---|
| **Objective** | Query an authoritative zone and a recursive resolver, read every part of a DNS answer, and know exactly how the client's resolver config (search, ndots) changes which name is actually asked. |
| **Time** | 1.5 h (week 5) · course: DNS |
| **Where** | netlab-c, `topo/dns`, root |
| **Risk** | Safe |

## 1. Prerequisites

```bash
cd ~/wb/phase1-ccna-drills/topo; containerlab deploy -t dns.clab.yml && bash dns-setup.sh
c() { docker exec clab-p1d-client sh -c "$1"; }
cat dns/Corefile dns/lab.local.zone          # what the server knows
```

## 2. Hands-on

### 2.1 Authoritative answers

```bash
c 'dig web.lab.local'                        # read: header flags (qr aa rd ra), QUESTION, ANSWER (TTL!), SERVER
c 'dig +short www.lab.local'                 # CNAME → web → A: the resolver follows the chain
c 'dig +short MX lab.local; dig +short TXT lab.local; dig +short AAAA db.lab.local'
c 'dig +short SRV _http._tcp.web.lab.local'  # priority weight port target — what Kubernetes serves for named ports
```

### 2.2 Recursive answers and caching

```bash
c 'dig example.com | grep -E "flags|IN\s+A"'      # no "aa": the answer came from elsewhere, cached here
sleep 5; c 'dig +noall +answer example.com'      # TTL is lower: you're reading the cache
c 'dig +trace example.com | grep -E "^\S+\s+[0-9]+\s+IN\s+(NS|A)" | head -12'   # root → com → example.com, iteratively
```

### 2.3 The three "no" answers

```bash
c 'dig nope.lab.local | grep -E "status|SOA"'    # NXDOMAIN: the name doesn't exist (SOA's last field = negative-cache TTL)
c 'dig AAAA web.lab.local | grep -E "status|ANSWER"'   # NOERROR with 0 answers: name exists, no record of that type ("NODATA")
c 'dig @10.53.0.99 +time=1 +tries=1 web.lab.local | tail -2'   # no server: timeout, not an answer at all
```

SERVFAIL (the server tried and failed, usually upstream) is the fourth;
lab 3.04 makes one.

### 2.4 The client's resolver: search and ndots

```bash
c 'cat /etc/resolv.conf'                          # nameserver 10.53.0.53, search lab.local, ndots:1
c 'getent hosts web'                              # works: the C library appends the search domain
c 'dig +short web'                                # nothing: dig doesn't use the search list…
c 'dig +short +search web'                        # …unless asked
c 'tcpdump -nni eth1 -c6 udp port 53' & sleep 1; c 'getent hosts web >/dev/null'; wait   # see the name actually asked
```

`ndots:N` = "a name with fewer than N dots is tried with the search
domains **first**". Kubernetes pods default to `ndots:5` with three search
domains — lab 3.04 measures what that costs. The break/fix is what it can do
to correctness.

## 3. Verification

| Check | Expected |
|---|---|
| §2.1 | `aa` set; www → web → 10.53.0.80; SRV `0 50 80 web.lab.local.` |
| §2.2 | no `aa` for example.com; TTL decreasing; +trace walks `.`, `com.`, `example.com.` |
| §2.3 | NXDOMAIN with SOA; NOERROR with ANSWER: 0; timeout |
| §2.4 | getent resolves `web`, plain dig doesn't, `+search` does; capture shows `web.lab.local` asked |

## 4. Break/fix

```bash
cd ~/wb/phase1-ccna-drills/08-dns && bash break.sh
```

| Beat | Your answer |
|---|---|
| Hypothesis | |
| Tool | |
| Expected if right | |
| What would have told me sooner | |

**Done when** `c 'getent hosts www.example.com'` returns the same address as
`c 'dig +short www.example.com'`, with the client's `ndots` left at 5.

Solution: [`solution.md`](solution.md).

## 5. Cleanup

```bash
containerlab destroy -t ~/wb/phase1-ccna-drills/topo/dns.clab.yml --cleanup
rm -rf ~/wb/phase1-ccna-drills/topo/dns && cp -r /workbook/phase1-ccna-drills/topo/dns ~/wb/phase1-ccna-drills/topo/   # break.sh edits the zone
```

## 6. What I should be able to explain after this

- Authoritative (`aa`) vs recursive/cached answers, TTLs and negative caching (the SOA minimum), and NXDOMAIN vs NODATA vs SERVFAIL vs timeout.
- Record types you'll meet in clusters: A/AAAA, CNAME chains, SRV (ports), TXT, MX, NS/SOA.
- The client library, not the server, applies `search` and `ndots`; `dig` doesn't by default — so `dig` and the application can disagree.
