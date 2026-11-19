#!/usr/bin/env bash
# Regenerate the scratch TLS material the SSL_CERT_FILE / SSL_CERT_DIR tests need.
#
# Committed, not generated at test time: a test that shells out to openssl tests openssl, and one
# that cannot run on a machine without it is a test that gets skipped. These files are public test
# material, private keys included - they are not a secret and must never be reused outside a test.
#
#   bash rust/wa-tls/fixtures/scratch-tls/generate.sh
#
# Valid until 2126 (-days 36500): an expired fixture fails every test that trusts it, on a date that
# has nothing to do with the change that added it.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$here"
rm -f ca.key ca.pem otherca.key otherca.pem server.key server.csr server.pem \
      other-server.key other-server.csr other-server.pem server.ext server.srl
umask 022
# The scratch CA the test server's certificate chains to.
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 36500 \
  -subj "/CN=wa scratch test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
# A second, unrelated CA: proves every certificate in a source is loaded and that SSL_CERT_FILE and
# SSL_CERT_DIR are a union rather than one replacing the other.
openssl req -x509 -newkey rsa:2048 -nodes -keyout otherca.key -out otherca.pem -days 36500 \
  -subj "/CN=wa scratch unrelated CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
# One server leaf per CA: localhost and 127.0.0.1, which is where the scratch server binds.
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' > server.ext
for pair in "server:ca" "other-server:otherca"; do
  leaf="${pair%%:*}"; ca="${pair##*:}"
  openssl req -new -newkey rsa:2048 -nodes -keyout "$leaf.key" -out "$leaf.csr" -subj "/CN=localhost"
  openssl x509 -req -in "$leaf.csr" -CA "$ca.pem" -CAkey "$ca.key" -CAcreateserial \
    -out "$leaf.pem" -days 36500 -sha256 -extfile server.ext
  rm -f "$leaf.csr"
done
rm -f server.ext ca.srl
chmod 644 *.pem *.key
openssl x509 -in server.pem -noout -enddate
