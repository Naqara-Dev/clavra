// Pretends to be a phone against Clavra's Phone Access: node Tests/phone.js <aead.js> <link> [production]
// Loads the page, joins, types, reconnects with the token the Mac gave it, replays a frame, and tries
// a wrong key. Prints one line per check; exits 1 on any failure.
const aead = require(require("path").resolve(process.argv[2]));
const link = new URL(process.argv[3]);
const production = process.argv[4] === "production";
const [port, secret] = link.hash.slice(1).split(".");
const key = Uint8Array.from(Buffer.from(secret.replace(/-/g, "+").replace(/_/g, "/"), "base64"));
let failures = 0;
const check = (ok, name) => { console.log((ok ? "✓ " : "✗ ") + name); if (!ok) failures++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function connect(useKey, hello) {
  const ws = new WebSocket(`ws://${link.hostname}:${port}`);
  ws.binaryType = "arraybuffer";
  const state = { ws, messages: [], screen: "", closed: false, sent: 0, challenge: null, last: null };
  state.send = (o) => {
    o.n = ++state.sent;
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const box = aead.seal(useKey, nonce, new TextEncoder().encode(JSON.stringify(o)), state.challenge);
    const frame = new Uint8Array(12 + box.length); frame.set(nonce); frame.set(box, 12);
    state.last = frame; ws.send(frame);
  };
  ws.onmessage = (e) => {
    const d = new Uint8Array(e.data);
    if (!state.challenge) { state.challenge = d.slice(4, 20); state.send(Object.assign({ t: "hello" }, hello)); return; }
    const opened = aead.open(key, d.subarray(0, 12), d.subarray(12), state.challenge);
    if (!opened) return;
    const m = JSON.parse(new TextDecoder().decode(opened));
    state.messages.push(m);
    if (m.t === "sessions") state.session = m.selected;
    if (m.t === "screen" && m.rows) for (const [, row] of m.rows) state.screen += JSON.parse(row).map((r) => r[0]).join("") + "\n";
  };
  ws.onclose = () => (state.closed = true);
  return state;
}

(async () => {
  for (const [path, want] of [["/", 200], ["/aead.js", 200], ["/remote.js", 200], ["/../etc/passwd", 404]]) {
    const r = await fetch(new URL(path, link.origin));
    check(r.status === want, `page ${path} → ${r.status}`);
  }
  const hello = { device: "e2e-phone", name: "E2E Phone" };
  const phone = connect(key, hello);
  await sleep(3500);
  check(phone.messages.some((m) => m.t === "wait"), "a new phone waits to be allowed");
  const token = phone.messages.find((m) => m.t === "token");
  check(!!token, "the Mac hands an allowed phone a token");
  check(!!phone.session, "the phone gets the tab list");
  phone.send({ t: "input", data: "echo typed-on-the-phone\r", session: phone.session });
  await sleep(2500);
  if (production) {
    check(phone.messages.some((m) => m.t === "readonly"), "production tabs are view only");
    check(!phone.screen.includes("typed-on-the-phone"), "nothing typed reached production");
  } else {
    check(phone.screen.includes("typed-on-the-phone"), "typing reaches the shell and the screen comes back");
    phone.send({ t: "input", data: "x", session: "00000000-0000-0000-0000-000000000000" });
    await sleep(800);
    check(phone.messages.some((m) => m.t === "readonly"), "typing aimed at another tab is refused");
  }
  phone.ws.send(phone.last);
  await sleep(1000);
  check(phone.closed, "a replayed frame ends the connection");

  const back = connect(key, Object.assign({ token: token && token.token }, hello));
  await sleep(1500);
  check(!back.messages.some((m) => m.t === "wait") && back.messages.some((m) => m.t === "sessions"), "the token lets the phone back in without asking");
  back.ws.close();

  const stranger = connect(crypto.getRandomValues(new Uint8Array(32)), { device: "stranger" });
  await sleep(1500);
  check(stranger.closed && stranger.messages.length === 0, "a wrong key is turned away");
  process.exit(failures ? 1 : 0);
})();
