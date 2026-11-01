#!/bin/bash
# Copies the phone page from the app (Clavra/Remote) to the site's /connect, so the page the relay
# serves and the page a Mac serves on Wi-Fi are the same files. test.sh checks they match.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p site/public/connect
cp Clavra/Remote/remote.html site/public/connect/index.html
cp Clavra/Remote/remote.js Clavra/Remote/aead.js site/public/connect/
echo "✓ site/public/connect matches Clavra/Remote"
