#!/bin/bash
# Compiles Clavra's logic that doesn't need a connection with Tests/CoreTests.swift and runs the
# checks, then checks the phone page's ChaCha20-Poly1305 against RFC 8439 and against CryptoKit.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
SOURCES=(Clavra/Features/CommandGuard.swift Clavra/Features/SafeNames.swift Clavra/Features/Autosuggest.swift
         Clavra/Features/ServerStats.swift Clavra/Features/Panes.swift Clavra/Model/Server.swift
         Clavra/Model/HostStore.swift Clavra/Model/Labels.swift Clavra/Model/KnownHosts.swift Clavra/Model/Keychain.swift)
swiftc -swift-version 6 -parse-as-library -O -o "$OUT/core-tests" "${SOURCES[@]}" Tests/CoreTests.swift
"$OUT/core-tests"

if command -v node >/dev/null; then
  swiftc -swift-version 6 -O -o "$OUT/aead-interop" Tests/AEADInterop.swift
  node Tests/aead.test.js Clavra/Remote/aead.js "$OUT/aead-interop"
else
  echo "- node not found; skipped the phone page's crypto checks"
fi

# The relay serves the same phone page the Mac does.
for pair in "Clavra/Remote/remote.html site/public/connect/index.html" "Clavra/Remote/remote.js site/public/connect/remote.js" \
            "Clavra/Remote/aead.js site/public/connect/aead.js"; do
  set -- $pair
  cmp -s "$1" "$2" || { echo "✗ $2 differs from $1; run scripts/sync-site.sh"; exit 1; }
done
echo "✓ the site's phone page matches the app's"

