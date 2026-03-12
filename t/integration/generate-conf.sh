#!/usr/bin/env bash
set -euo pipefail

CERTS_DIR="$(dirname "$0")/certs"
CONF_DIR="$(dirname "$0")/conf"

# Generate self-signed cert if not present
if [ ! -f "$CERTS_DIR/server.crt" ]; then
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$CERTS_DIR/server.key" \
        -out "$CERTS_DIR/server.crt" \
        -days 365 -nodes \
        -subj "/CN=test.example.com" \
        -addext "subjectAltName=DNS:test.example.com,DNS:*.test.example.com"
fi

# Render apisix.yaml from template with indented cert/key
awk -v cert_file="$CERTS_DIR/server.crt" -v key_file="$CERTS_DIR/server.key" '
/__CERT__/ {
    while ((getline line < cert_file) > 0) print "      " line
    close(cert_file)
    next
}
/__KEY__/ {
    while ((getline line < key_file) > 0) print "      " line
    close(key_file)
    next
}
{ print }
' "$CONF_DIR/apisix.yaml.tpl" > "$CONF_DIR/apisix.yaml"

echo "Generated: $CONF_DIR/apisix.yaml"
