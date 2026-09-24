#!/bin/sh
# Generate the private key and CSR for Caddy's intermediate CA.
# Run on caterpi so the key never leaves it:
#   sudo caddy/pki/make-csr.sh [dir]     # dir defaults to /etc/crest-pki
set -eu

dir="${1:-/etc/crest-pki}"
cn="${CN:-Crest Robotics Caddy Intermediate CA}"
cnf="$(dirname "$0")/intermediate.cnf"
key="$dir/caddy-intermediate.key"
csr="$dir/caddy-intermediate.csr"

if [ -e "$key" ]; then
  echo "refusing to overwrite existing $key" >&2
  exit 1
fi

umask 077
mkdir -p "$dir"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$key"
openssl req -new -config "$cnf" -key "$key" -subj "/O=Crest Robotics/CN=$cn" -out "$csr"
chmod 644 "$csr"

echo "Key: $key (keep private)"
echo "CSR: $csr (send to the company CA for signing)"
openssl req -in "$csr" -noout -subject
