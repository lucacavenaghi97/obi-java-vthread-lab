#!/usr/bin/env bash
# Generates the self-signed test certificates used by the TLS arms:
#   downstream.crt/.key  nginx HTTPS downstream (SAN: downstream)
#   app.p12              Tomcat HTTPS keystore for the tlss arm (password changeit)
# The app's HTTPS client is trust-all, so no CA chain is needed.
set -eu
cd "$(dirname "$0")"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout downstream.key -out downstream.crt \
  -subj "/CN=downstream" -addext "subjectAltName=DNS:downstream,DNS:localhost"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout app.key -out app.crt \
  -subj "/CN=app" -addext "subjectAltName=DNS:app,DNS:localhost"
openssl pkcs12 -export -in app.crt -inkey app.key \
  -out app.p12 -name app -passout pass:changeit

echo "generated: downstream.crt downstream.key app.crt app.key app.p12"
