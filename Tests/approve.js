// A phone answering a held command on a host where only a phone can say yes:
// node Tests/approve.js <aead.js> <link> <expect: run|ignored>
// Checks a wrong command text is refused, then approves the real one.
const aead = require(require("path").resolve(process.argv[2]));
const link = new URL(process.argv[3]);
const expect = process.argv[4] || "run";
const [port, secret] = link.hash.slice(1).split(".");
const key = Uint8Array.from(Buffer.from(secret.replace(/-/g, "+").replace(/_/g, "/"), "base64"));
let failures = 0;
const check = (ok, name) => { console.log((ok ? "✓ " : "✗ ") + name); if (!ok) failures++; };
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const ws = new WebSocket(`ws://${link.hostname}:${port}`);
ws.binaryType = "arraybuffer";
let challenge = null, sent = 0, lists = [], screen = "";
const send = (o) => {
  o.n = ++sent;
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const box = aead.seal(key, nonce, new TextEncoder().encode(JSON.stringify(o)), challenge);
  const frame = new Uint8Array(12 + box.length); frame.set(nonce); frame.set(box, 12); ws.send(frame);
};
ws.onmessage = (e) => {
  const d = new Uint8Array(e.data);
  if (!challenge) { challenge = d.slice(4, 20); send({ t: "hello", device: "approve-phone", name: "Approve Phone" }); return; }
  const m = JSON.parse(new TextDecoder().decode(aead.open(key, d.subarray(0, 12), d.subarray(12), challenge)));
  if (m.t === "sessions") lists.push(m.list);
  if (m.t === "screen" && m.rows) for (const [, row] of m.rows) screen += JSON.parse(row).map((r) => r[0]).join("") + "\n";
};
(async () => {
  await sleep(4000);
  const held = () => (lists[lists.length - 1] || []).find((i) => i.held);
  const item = held();
  check(!!item, "the phone sees the held command" + (item ? `: ${item.held}` : ""));
  if (!item) process.exit(1);
  check(item.approve === (expect === "run"), `it's marked as needing the phone: ${item.approve}`);
  check(Array.isArray(item.impact) && item.impact.length > 0, "with what it would touch: " + JSON.stringify(item.impact));
  send({ t: "approve", session: item.id, command: item.held + " --other", run: true });
  await sleep(1500);
  check(!!held(), "an answer naming a different command is refused");
  send({ t: "approve", session: item.id, command: item.held, run: true });
  await sleep(3000);
  if (expect === "run") {
    check(!held(), "the phone's yes releases it");
    check(screen.split("\n").some((l) => l.trim() === "APPROVED-RAN"), "and it ran on the server");
  } else {
    check(!!held(), "on a host that doesn't ask the phone, the phone can't run it");
    check(!screen.split("\n").some((l) => l.trim() === "APPROVED-RAN"), "nothing ran");
  }
  ws.close();
  process.exit(failures ? 1 : 0);
})();
