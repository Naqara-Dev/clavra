#!/bin/bash
# Runs the Debug build against a throwaway sshd on 127.0.0.1:2222, as you, and checks each feature
# end to end: key types, the risky-command guard, suggestions, jump hosts, tunnels (-L, -R, -D,
# half-close), SFTP transfers and editing, reconnecting, and Phone Access.
#
# Build first:
#   xcodebuild -project Clavra.xcodeproj -scheme Clavra -configuration Debug \
#     -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages build
#
# Touches nothing it didn't make: the server, its keys and files live in a temporary folder; the
# only things written elsewhere are Clavra's trusted-key line for [127.0.0.1]:2222 and the command
# history for that address, both removed at the end, and two uniquely named downloads in
# ~/Downloads, removed too. Only Clavra windows started from this build are closed.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/build/Build/Products/Debug/Clavra.app"
BIN="$APP/Contents/MacOS/Clavra"
[ -x "$BIN" ] || { echo "Build the Debug app first (see the top of this script)."; exit 2; }
for port in 2222 8765 18765 19876 11080 8790; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then echo "Port $port is in use; stop whatever uses it first."; exit 2; fi
done

T="$(mktemp -d)"
RUN="$(openssl rand -hex 4)"
SUPPORT="$HOME/Library/Application Support/Clavra"
HISTORY_FILE="$SUPPORT/History/$(printf '%s' "$USER@127.0.0.1:2222" | shasum -a 256 | cut -c1-24).json"
FAILED=0
pass() { echo "✓ $1"; }
fail() { echo "✗ $1"; FAILED=$((FAILED + 1)); }
expect() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

stop_app() { pkill -f "$BIN" 2>/dev/null; sleep 1; }
cleanup() {
  stop_app
  [ -f "$T/sshd.pid" ] && kill "$(cat "$T/sshd.pid")" 2>/dev/null
  [ -n "${HTTP_PID:-}" ] && kill "$HTTP_PID" 2>/dev/null
  if [ -f "$SUPPORT/known_hosts" ]; then
    grep -v '^\[127.0.0.1\]:2222 ' "$SUPPORT/known_hosts" > "$T/kh" || true
    if [ -s "$T/kh" ]; then cp "$T/kh" "$SUPPORT/known_hosts"; else rm -f "$SUPPORT/known_hosts"; fi
  fi
  rm -f "$HISTORY_FILE"
  rmdir "$SUPPORT/History" "$SUPPORT" 2>/dev/null
  rm -rf "$HOME/Library/Caches/Clavra/Editing"
  rm -rf "$HOME/Downloads/e2e-dl-$RUN.bin" "$HOME/Downloads/e2e-dl-$RUN-folder"
  rm -rf "$T"
}
trap cleanup EXIT

# Launch the app with debug arguments; it trusts the throwaway host key itself.
launch() { stop_app; open -n --stdout "$T/out.log" "$APP" --args -ClavraAutoTrust YES "$@"; }
open_host() { launch -ClavraOpen "$USER@127.0.0.1:2222" "$@"; }

# --- the server -------------------------------------------------------------------------------
mkdir -p "$T/marks" "$T/files/e2e-dl-$RUN-folder/inner" "$T/www"
ssh-keygen -q -t ed25519 -N "" -f "$T/host_key"
ssh-keygen -q -t ed25519 -N "" -C e2e -f "$T/ed25519"
ssh-keygen -q -t ecdsa -b 256 -N "" -C e2e -f "$T/p256"
ssh-keygen -q -t ecdsa -b 384 -N "" -C e2e -f "$T/p384"
ssh-keygen -q -t ecdsa -b 521 -N "" -C e2e -f "$T/p521"
ssh-keygen -q -t ecdsa -b 256 -m PEM -N "" -C e2e -f "$T/pem"
# RSA signs with rsa-sha2-512: OpenSSH 8.8+ turns down the old SHA-1 ssh-rsa.
ssh-keygen -q -t rsa -b 3072 -N "" -C e2e -f "$T/rsa"
cat "$T"/*.pub > "$T/authorized_keys"
cat > "$T/sshd_config" <<EOF
ListenAddress 127.0.0.1
Port 2222
HostKey $T/host_key
AuthorizedKeysFile $T/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
AllowTcpForwarding yes
PidFile $T/sshd.pid
Subsystem sftp /usr/libexec/sftp-server
EOF
/usr/sbin/sshd -f "$T/sshd_config" -E "$T/sshd.log" || { echo "sshd didn't start"; exit 2; }
dd if=/dev/urandom of="$T/www/big.bin" bs=1m count=40 2>/dev/null
(cd "$T/www" && exec python3 -m http.server 8765 --bind 127.0.0.1 >/dev/null 2>&1) & HTTP_PID=$!
dd if=/dev/urandom of="$T/files/e2e-dl-$RUN.bin" bs=1k count=3000 2>/dev/null
echo "inside a folder" > "$T/files/e2e-dl-$RUN-folder/inner/deep.txt"
printf 'line one\n' > "$T/files/e2e-edit.txt"; chmod 640 "$T/files/e2e-edit.txt"
dd if=/dev/urandom of="$T/upload.bin" bs=1k count=700 2>/dev/null
sleep 1

echo "— sign-in"
for key in ed25519 p256 p384 p521 pem rsa; do
  open_host -ClavraKey "$T/$key" -ClavraType "touch $T/marks/$key\\r"
  sleep 8
  expect "$key key signs in and types" "[ -f '$T/marks/$key' ]"
done

echo "— guard, suggestions, jump host, startup command"
mkdir -p "$T/keep-me"
open_host -ClavraKey "$T/ed25519" -ClavraPlace production -ClavraType "rm -rf $T/keep-me\\r"
sleep 7
expect "production holds rm -rf until you say yes" "[ -d '$T/keep-me' ]"
open_host -ClavraKey "$T/ed25519" -ClavraType "echo first >> $T/marks/suggest\\r|echo fir\\e[C\\r"
sleep 10
expect "→ takes the grey suggestion" "[ \"\$(grep -c first '$T/marks/suggest' 2>/dev/null)\" = 2 ]"
open_host -ClavraKey "$T/ed25519" -ClavraJump "$USER@127.0.0.1:2222" -ClavraType "touch $T/marks/jump\\r"
sleep 9
expect "connects through a jump host" "[ -f '$T/marks/jump' ]"

echo "— tunnels and reconnecting"
open_host -ClavraKey "$T/ed25519" -ClavraForward '18765:8765,socks:11080,remote:19876:8765' -ClavraStartup "echo up >> $T/marks/startup"
sleep 9
WANT="$(shasum "$T/www/big.bin" | cut -c1-40)"
expect "-L carries 40 MB intact" "[ \"\$(curl -s -m 60 http://localhost:18765/big.bin | shasum | cut -c1-40)\" = '$WANT' ]"
expect "-R carries 40 MB intact" "[ \"\$(curl -s -m 60 http://localhost:19876/big.bin | shasum | cut -c1-40)\" = '$WANT' ]"
expect "-D (SOCKS5) carries 40 MB intact" "[ \"\$(curl -s -m 60 --socks5-hostname localhost:11080 http://127.0.0.1:8765/big.bin | shasum | cut -c1-40)\" = '$WANT' ]"
HALF="$(python3 - <<'PY'
import socket, hashlib
s = socket.create_connection(("127.0.0.1", 18765)); s.sendall(b"GET /big.bin HTTP/1.0\r\n\r\n"); s.shutdown(socket.SHUT_WR)
data = b""
while True:
    chunk = s.recv(65536)
    if not chunk: break
    data += chunk
print(hashlib.sha1(data.split(b"\r\n\r\n", 1)[1]).hexdigest())
PY
)"
expect "a client that half-closes still gets the whole reply" "[ '$HALF' = '$WANT' ]"
expect "the startup command runs" "[ \"\$(wc -l < '$T/marks/startup' | tr -d ' ')\" = 1 ]"
# Drop the connection the way a network does: every process of the test server's session goes.
for session in $(pgrep -P "$(cat "$T/sshd.pid")"); do kill -9 $(pgrep -P "$session") "$session" 2>/dev/null; done
sleep 9
expect "a dropped connection comes back (startup ran again)" "[ \"\$(wc -l < '$T/marks/startup' | tr -d ' ')\" = 2 ]"
expect "…with its tunnels" "curl -s -m 10 http://localhost:18765/ >/dev/null"

echo "— files"
open_host -ClavraKey "$T/ed25519" -ClavraFilesTest "$T/files" -ClavraFilesUpload "$T/upload.bin" -ClavraEditNoOpen YES
sleep 12
expect "downloads a file" "cmp -s '$HOME/Downloads/e2e-dl-$RUN.bin' '$T/files/e2e-dl-$RUN.bin'"
expect "downloads a folder with what's inside" "[ -f '$HOME/Downloads/e2e-dl-$RUN-folder/inner/deep.txt' ]"
expect "uploads a file" "cmp -s '$T/upload.bin' '$T/files/upload.bin'"
EDIT="$(grep CLAVRA_EDIT "$T/out.log" | tail -1 | cut -d' ' -f2-)"
if [ -n "$EDIT" ] && [ -f "$EDIT" ]; then
  echo "line two" >> "$EDIT"; sleep 4
  expect "a save on the Mac goes back to the server" "grep -q 'line two' '$T/files/e2e-edit.txt'"
  expect "…keeping the file's permissions" "[ \"\$(stat -f %Lp '$T/files/e2e-edit.txt')\" = 640 ]"
  expect "…with no temporary file left behind" "! ls -a '$T/files' | grep -q clavra-"
else
  fail "editing a file opens a local copy"
fi

echo "— phone access"
open_host -ClavraKey "$T/ed25519" -ClavraRemote YES -ClavraRemoteAllow YES -PhoneRelay NO
sleep 8
LINK="$(grep CLAVRA_REMOTE "$T/out.log" | tail -1 | cut -d' ' -f2)"
if [ -n "$LINK" ]; then node Tests/phone.js Clavra/Remote/aead.js "$LINK" || FAILED=$((FAILED + 1)); else fail "phone access starts"; fi
open_host -ClavraKey "$T/ed25519" -ClavraPlace production -ClavraRemote YES -ClavraRemoteAllow YES -PhoneRelay NO
sleep 8
LINK="$(grep CLAVRA_REMOTE "$T/out.log" | tail -1 | cut -d' ' -f2)"
if [ -n "$LINK" ]; then node Tests/phone.js Clavra/Remote/aead.js "$LINK" production || FAILED=$((FAILED + 1)); else fail "phone access starts"; fi


echo "— phone access through the relay (Tests/relay-mock.js)"
node Tests/relay-mock.js 8790 >/dev/null 2>&1 & RELAY_PID=$!
sleep 1
open_host -ClavraKey "$T/ed25519" -ClavraRemote YES -ClavraRemoteAllow YES -PhoneRelay YES -ClavraRelay ws://127.0.0.1:8790
sleep 8
LINK="$(grep CLAVRA_REMOTE "$T/out.log" | tail -1 | cut -d' ' -f2)"
if [ -n "$LINK" ]; then node Tests/phone.js Clavra/Remote/aead.js "$LINK" || FAILED=$((FAILED + 1)); else fail "phone access starts on the relay"; fi
kill "$RELAY_PID" 2>/dev/null

echo
if [ "$FAILED" = 0 ]; then echo "All end-to-end checks passed."; else echo "$FAILED end-to-end checks failed."; fi
exit $((FAILED > 0))
