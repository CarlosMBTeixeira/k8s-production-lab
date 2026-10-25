#!/usr/bin/env bash
# pki.sh <dir> — a root CA, an intermediate, a server leaf for api.lab.local
# (signed by the intermediate) and a client cert. OpenSSL 3. 30-day validity.
set -euo pipefail
D=${1:?usage: pki.sh <dir>}; mkdir -p "$D"; cd "$D"
q() { "$@" >/dev/null 2>&1; }
q openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.pem -days 30 -subj "/CN=Lab Root CA" \
  -addext "basicConstraints=critical,CA:true" -addext "keyUsage=critical,keyCertSign,cRLSign"
q openssl req -newkey rsa:2048 -nodes -keyout int.key -out int.csr -subj "/CN=Lab Intermediate CA"
printf 'basicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n' > int.ext
q openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial -out int.pem -days 30 -extfile int.ext
q openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=api.lab.local"
printf 'subjectAltName=DNS:api.lab.local\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:false\n' > leaf.ext
q openssl x509 -req -in leaf.csr -CA int.pem -CAkey int.key -CAcreateserial -out leaf.pem -days 30 -extfile leaf.ext
q openssl req -newkey rsa:2048 -nodes -keyout client.key -out client.csr -subj "/CN=lab-client"
printf 'extendedKeyUsage=clientAuth\nbasicConstraints=CA:false\n' > client.ext
q openssl x509 -req -in client.csr -CA int.pem -CAkey int.key -CAcreateserial -out client.pem -days 30 -extfile client.ext
cat leaf.pem int.pem > fullchain.pem
cat root.pem int.pem > ca-bundle.pem          # trust store for verifying client certs
chmod 644 ./*.key ./*.pem      # readable inside containers; lab-only keys
openssl verify -CAfile root.pem -untrusted int.pem leaf.pem
echo "pki: $(pwd)"
