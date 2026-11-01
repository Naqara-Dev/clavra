// A stand-in for site/worker.js's relay, for tests on this Mac: node Tests/relay-mock.js <port>
// Same rooms, same 5-byte Mac framing, same secret check; plain ws:// and no static pages.
const http = require("http");
const crypto = require("crypto");
const port = Number(process.argv[2] || 8790);
const rooms = new Map(); // room -> { mac, phones: Map<number, socket> }

function frame(payload, opcode = 2) {
  const length = payload.length;
  const head = length < 126 ? Buffer.from([0x80 | opcode, length])
    : length < 65536 ? Buffer.from([0x80 | opcode, 126, length >> 8, length & 255])
    : (() => { const b = Buffer.alloc(10); b[0] = 0x80 | opcode; b[1] = 127; b.writeBigUInt64BE(BigInt(length), 2); return b; })();
  return Buffer.concat([head, payload]);
}

function socketFor(sock, onMessage, onClose) {
  let buffer = Buffer.alloc(0), closed = false;
  const api = {
    send: (bytes) => { if (!closed) sock.write(frame(Buffer.from(bytes))); },
    close: (code = 1000) => { if (closed) return; closed = true; const b = Buffer.alloc(2); b.writeUInt16BE(code); sock.end(frame(b, 8)); onClose(); },
  };
  sock.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 2) {
      const opcode = buffer[0] & 15, masked = buffer[1] & 128;
      let length = buffer[1] & 127, offset = 2;
      if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
      else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
      const maskAt = offset; if (masked) offset += 4;
      if (buffer.length < offset + length) return;
      let payload = buffer.subarray(offset, offset + length);
      if (masked) { const mask = buffer.subarray(maskAt, maskAt + 4); payload = Buffer.from(payload.map((b, i) => b ^ mask[i % 4])); }
      buffer = buffer.subarray(offset + length);
      if (opcode === 8) { api.close(); return; }
      if (opcode === 9) { sock.write(frame(payload, 10)); continue; }
      if (opcode === 2) onMessage(payload);
    }
  });
  sock.on("close", () => { if (!closed) { closed = true; onClose(); } });
  sock.on("error", () => {});
  return api;
}

const header = (kind, phone) => { const b = Buffer.alloc(5); b[0] = kind; b.writeUInt32BE(phone, 1); return b; };
const b64url = (buf) => buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

http.createServer((req, res) => { res.writeHead(404); res.end(); }).on("upgrade", (req, sock) => {
  const url = new URL(req.url, "http://x");
  const match = url.pathname.match(/^\/relay\/([A-Za-z0-9_-]{43})$/);
  const role = url.searchParams.get("role");
  const reject = (status) => { sock.end(`HTTP/1.1 ${status} No\r\n\r\n`); };
  if (!match) return reject(404);
  const name = match[1];
  if (role === "mac") {
    const secret = url.searchParams.get("s") || "";
    if (secret.length < 32 || b64url(crypto.createHash("sha256").update(secret).digest()) !== name) return reject(403);
  } else if (role !== "phone") return reject(400);
  const accept = crypto.createHash("sha1").update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  sock.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  const room = rooms.get(name) || { mac: null, phones: new Map() };
  rooms.set(name, room);
  if (role === "mac") {
    const old = room.mac;
    const me = socketFor(sock, (bytes) => {
      if (bytes.length < 5) return;
      const target = room.phones.get(bytes.readUInt32BE(1));
      if (!target) return;
      if (bytes[0] === 0) target.send(bytes.subarray(5)); else if (bytes[0] === 2) target.close(4001);
    }, () => { if (room.mac === me) { room.mac = null; for (const p of room.phones.values()) p.close(4002); } });
    room.mac = me;
    if (old) old.close(4000);
    for (const n of room.phones.keys()) me.send(header(1, n));
  } else {
    const number = crypto.randomBytes(4).readUInt32BE() || 1;
    const me = socketFor(sock, (bytes) => {
      if (!room.mac) return me.close(4002);
      room.mac.send(Buffer.concat([header(0, number), bytes]));
    }, () => { room.phones.delete(number); room.mac?.send(header(2, number)); });
    room.phones.set(number, me);
    room.mac?.send(header(1, number));
  }
}).listen(port, "127.0.0.1", () => console.log(`relay mock on ws://127.0.0.1:${port}`));
