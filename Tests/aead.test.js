// node Tests/aead.test.js <aead.js> <aead-interop binary>
const { execFileSync } = require("child_process");
const aead = require(require("path").resolve(process.argv[2]));
const interop = process.argv[3];
let failures = 0, passes = 0;
const check = (ok, name) => { if (ok) passes++; else { failures++; console.log("✗ " + name); } };
const hex = (h) => Uint8Array.from(h.replace(/\s/g, "").match(/../g).map((x) => parseInt(x, 16)));
const toHex = (b) => Buffer.from(b).toString("hex");
const text = (b) => new TextDecoder().decode(b);

// RFC 8439 §2.8.2
const key = hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f");
const nonce = hex("070000004041424344454647");
const aad = hex("50515253c0c1c2c3c4c5c6c7");
const plain = new TextEncoder().encode("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.");
const sealed = aead.seal(key, nonce, plain, aad);
check(toHex(sealed.subarray(sealed.length - 16)) === "1ae10b594f09e26a7e902ecbd0600691", "RFC 8439 tag");
check(toHex(sealed.subarray(0, 16)) === "d31a8d34648e60db7b86afbc53ef7ec2", "RFC 8439 ciphertext");
check(text(aead.open(key, nonce, sealed, aad)) === text(plain), "round trip");
const tampered = sealed.slice(); tampered[5] ^= 1;
check(aead.open(key, nonce, tampered, aad) === null, "a changed byte is refused");
check(aead.open(key, nonce, sealed, new Uint8Array([1])) === null, "the wrong challenge is refused");
// RFC 8439 §2.5.2
check(toHex(aead.poly1305(hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b"),
  new TextEncoder().encode("Cryptographic Forum Research Group"))) === "a8061dc1305136c6c22b8baf0c0127a9", "RFC 8439 Poly1305");

// Against CryptoKit, both ways.
const [k, box] = execFileSync(interop, ["seal"]).toString().trim().split(" ");
const fromMac = aead.open(hex(k), hex(box).subarray(0, 12), hex(box).subarray(12), new TextEncoder().encode("aad"));
check(fromMac && text(fromMac).startsWith("from the Mac"), "opens what CryptoKit sealed");
const n = hex("010000000000000000000007");
const fromPhone = aead.seal(hex(k), n, new TextEncoder().encode("from the phone"), new TextEncoder().encode("aad"));
check(execFileSync(interop, ["open", k, toHex(n) + toHex(fromPhone)]).toString().trim() === "from the phone", "CryptoKit opens what the page sealed");

console.log(failures === 0 ? `✓ ${passes} crypto checks passed` : `${failures} of ${passes + failures} crypto checks failed`);
process.exit(failures === 0 ? 0 : 1);
