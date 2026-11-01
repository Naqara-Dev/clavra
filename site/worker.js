// clavra.naqara.dev. Static pages come from ./public; /relay/<room> pairs a Mac running Clavra with
// the phones that scanned its QR code.
//
// The relay only ever sees ciphertext: phone and Mac seal every message with ChaCha20-Poly1305
// under a key that is in the QR code and nowhere else. A room's name is the SHA-256 of a secret
// only the Mac holds, so nobody else can sit in a room as its Mac.
//
// Frames between relay and Mac carry a 5-byte header: kind (0 data, 1 phone joined, 2 phone left)
// and the phone's number, big-endian. Phones see bare payloads.

const MAX_FRAME = 1 << 20;
const MAX_PHONES = 8;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const match = url.pathname.match(/^\/relay\/([A-Za-z0-9_-]{43})$/);
    if (match) {
      if (request.headers.get("Upgrade") !== "websocket") return new Response("Expected a WebSocket.", { status: 426 });
      return env.RELAY.get(env.RELAY.idFromName(match[1])).fetch(request);
    }
    if (url.pathname.startsWith("/relay")) return new Response("Not a room.", { status: 404 });
    return env.ASSETS.fetch(request);
  },
};

function base64url(bytes) {
  return btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function header(kind, phone) {
  const bytes = new Uint8Array(5);
  bytes[0] = kind;
  new DataView(bytes.buffer).setUint32(1, phone);
  return bytes;
}

export class Relay {
  constructor(state) {
    this.state = state;
  }

  async fetch(request) {
    const url = new URL(request.url);
    const room = url.pathname.split("/")[2];
    const role = url.searchParams.get("role");
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    if (role === "mac") {
      // Only the holder of the secret behind the room's name may be its Mac.
      const secret = url.searchParams.get("s") || "";
      const digest = base64url(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret)));
      if (secret.length < 32 || digest !== room) return new Response("Not this room's Mac.", { status: 403 });
      for (const old of this.state.getWebSockets("mac")) old.close(4000, "Replaced by a newer connection.");
      this.state.acceptWebSocket(server, ["mac"]);
      // Phones already waiting are announced to the Mac that just arrived.
      for (const phone of this.phones()) server.send(header(1, this.number(phone)));
    } else if (role === "phone") {
      if (this.phones().length >= MAX_PHONES) return new Response("Too many phones in this room.", { status: 429 });
      const number = (crypto.getRandomValues(new Uint32Array(1))[0] >>> 0) || 1;
      this.state.acceptWebSocket(server, ["phone", `phone:${number}`]);
      this.mac()?.send(header(1, number));
    } else {
      return new Response("Say who you are.", { status: 400 });
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  mac() {
    return this.state.getWebSockets("mac")[0];
  }

  phones() {
    return this.state.getWebSockets("phone");
  }

  number(socket) {
    const tag = this.state.getTags(socket).find((t) => t.startsWith("phone:"));
    return tag ? Number(tag.slice(6)) : 0;
  }

  async webSocketMessage(socket, message) {
    if (typeof message === "string" || message.byteLength > MAX_FRAME) return socket.close(1009, "Frames are binary and under 1 MB.");
    const bytes = new Uint8Array(message);
    if (this.state.getTags(socket).includes("mac")) {
      if (bytes.length < 5) return;
      const phone = new DataView(bytes.buffer, bytes.byteOffset).getUint32(1);
      const target = this.state.getWebSockets(`phone:${phone}`)[0];
      if (!target) return;
      if (bytes[0] === 0) target.send(bytes.subarray(5));
      else if (bytes[0] === 2) target.close(4001, "The Mac ended this connection.");
    } else {
      const mac = this.mac();
      if (!mac) return socket.close(4002, "The Mac isn't connected.");
      const frame = new Uint8Array(5 + bytes.length);
      frame.set(header(0, this.number(socket)));
      frame.set(bytes, 5);
      mac.send(frame);
    }
  }

  async webSocketClose(socket) {
    this.left(socket);
  }

  async webSocketError(socket) {
    this.left(socket);
  }

  left(socket) {
    const tags = this.state.getTags(socket);
    if (tags.includes("mac")) {
      // A Mac replaced by its own newer connection keeps the phones; one that's simply gone doesn't.
      const others = this.state.getWebSockets("mac").filter((s) => s !== socket);
      if (others.length === 0) for (const phone of this.phones()) phone.close(4002, "The Mac went away.");
    } else {
      this.mac()?.send(header(2, this.number(socket)));
    }
  }
}
