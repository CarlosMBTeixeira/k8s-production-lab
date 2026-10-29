# Lab 4.06 — solution

## What was injected

<!--FAULT-->
```bash
PKI="$LAB_DIR/.pki"
[ -f "$PKI/leaf.pem" ] || bash "$LAB_DIR/pki.sh" "$PKI" >/dev/null
docker network create lab-tls >/dev/null 2>&1 || true
docker rm -f lab-tls-srv >/dev/null 2>&1 || true
# --- the fault ---
docker run -d --name lab-tls-srv --network lab-tls --network-alias api.lab.local \
  -v "$PKI":/pki:ro nicolaka/netshoot:v0.13 \
  openssl s_server -accept 443 -cert /pki/leaf.pem -key /pki/leaf.key -www >/dev/null
sleep 1
cat <<T

TICKET  The API vendor rotated the certificate on https://api.lab.local last
        night. Our clients now fail:
          docker run --rm --network lab-tls -v $PKI:/pki:ro nicolaka/netshoot:v0.13 \\
            curl -sS --cacert /pki/root.pem https://api.lab.local/
          → curl: (60) SSL certificate problem: unable to get local issuer certificate
        The vendor says: "The certificate is valid, signed by your CA, and our
        browser shows a padlock." Our trust store (root.pem) hasn't changed.
T
```
<!--/FAULT-->

The server presents only the leaf certificate, without the intermediate.
Clients trust the root, not the intermediate, so they can't build a chain:
`unable to get local issuer certificate`. Browsers often "work" anyway
because they cache intermediates or fetch them via the AIA extension —
which is why the vendor's test looks green. curl, Go, Java and most
service-to-service clients don't do that.

## Diagnosis path

| Beat | Answer |
|---|---|
| Hypothesis | "Valid cert, trusted root, still unable to get local issuer" = the chain is incomplete as served. |
| Tool | `cli openssl s_client -connect api.lab.local:443 -servername api.lab.local -showcerts </dev/null \| grep -E '^ [0-9] s:\|i:'` |
| Expected if right | only depth `0 s:CN=api.lab.local i:CN=Lab Intermediate CA` — no depth 1. |
| Tool 2 | `openssl verify -CAfile $PKI/root.pem $PKI/leaf.pem` vs `openssl verify -CAfile $PKI/root.pem -untrusted $PKI/int.pem $PKI/leaf.pem` |
| Expected if right | the first fails exactly like the clients; the second passes. |
| What would have told me sooner | A synthetic TLS check from a non-browser client (curl/openssl, or blackbox_exporter's `probe_ssl_last_chain_info`), and checking `-showcerts` depth on every certificate rotation. |

## Fix

Serve the chain (leaf + intermediate):

```bash
srv -cert /pki/leaf.pem -cert_chain /pki/int.pem
cli openssl s_client -connect api.lab.local:443 -servername api.lab.local -showcerts </dev/null 2>/dev/null | grep -E '^ [0-9] s:'   # depth 0 and 1 now
cli curl -s --cacert /pki/root.pem https://api.lab.local/ | head -1
```

`srv -cert /pki/fullchain.pem` is **not** equivalent: `openssl s_server`
reads only the first certificate from `-cert` and still serves the leaf
alone. Check `-showcerts`, don't assume. nginx (`ssl_certificate`), Envoy,
HAProxy and a Kubernetes `tls.crt` do take leaf + intermediates in one PEM,
leaf first.

In Kubernetes terms: the Secret's `tls.crt` must hold the full chain
(cert-manager writes it that way; hand-made secrets often don't).

## Why it matters later

Same symptom behind an Ingress/Gateway/Route on OpenShift whose secret was
created from the leaf only, and behind an Istio `DestinationRule` with
`SIMPLE` TLS to an external API. Always `-showcerts` first.
