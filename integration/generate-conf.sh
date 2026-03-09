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
CERT=$(sed 's/^/      /' "$CERTS_DIR/server.crt")
KEY=$(sed 's/^/      /' "$CERTS_DIR/server.key")

sed -e "/__CERT__/{
    r /dev/stdin
    d
}" <<< "$CERT" < "$CONF_DIR/apisix.yaml.tpl" | sed -e "/__KEY__/{
    r /dev/stdin
    d
}" <<< "$KEY" > "$CONF_DIR/apisix.yaml"

echo "Generated: $CONF_DIR/apisix.yaml"
