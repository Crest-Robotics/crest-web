#!/bin/sh
# Generate crest-web's root CA: a private key and a self-signed certificate.
# Caddy uses it to create and renew its own intermediate. Run on caterpi:
#   services/caddy/pki/make-root.sh [dir]     # dir defaults to this directory
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
dir="${1:-$here}"
cn="${CN:-Crest Web Root CA}"
days="${DAYS:-3650}"
cnf="$here/ca.cnf"
key="$dir/root.key"
crt="$dir/root.crt"

for f in "$key" "$crt"; do
  if [ -e "$f" ]; then
    echo "refusing to overwrite existing $f" >&2
    exit 1
  fi
done

umask 077
mkdir -p "$dir"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$key"
openssl req -new -x509 -config "$cnf" -extensions v3_root -key "$key" \
  -subj "/O=Crest Robotics/CN=$cn" -days "$days" -sha256 -out "$crt"
chmod 644 "$crt"

echo "Key:  $key (keep private)"
echo "Cert: $crt (distribute to clients)"
openssl x509 -in "$crt" -noout -subject -enddate -fingerprint -sha256
