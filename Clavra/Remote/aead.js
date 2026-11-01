// ChaCha20-Poly1305 (RFC 8439) for the phone page. The page is served over plain HTTP on the local
// network, where browsers don't offer WebCrypto, so the AEAD the Mac uses (CryptoKit's ChaChaPoly)
// is written out here. Checked against the RFC's test vectors and against CryptoKit.
(function (root) {
  "use strict";

  function rotl(a, b) { return (a << b) | (a >>> (32 - b)); }

  function quarter(s, a, b, c, d) {
    s[a] = (s[a] + s[b]) | 0; s[d] = rotl(s[d] ^ s[a], 16);
    s[c] = (s[c] + s[d]) | 0; s[b] = rotl(s[b] ^ s[c], 12);
    s[a] = (s[a] + s[b]) | 0; s[d] = rotl(s[d] ^ s[a], 8);
    s[c] = (s[c] + s[d]) | 0; s[b] = rotl(s[b] ^ s[c], 7);
  }

  function words(bytes) {
    const out = new Uint32Array(bytes.length / 4);
    for (let i = 0; i < out.length; i++) {
      out[i] = bytes[4 * i] | (bytes[4 * i + 1] << 8) | (bytes[4 * i + 2] << 16) | (bytes[4 * i + 3] << 24);
    }
    return out;
  }

  function block(key, counter, nonce) {
    const state = new Uint32Array(16);
    state.set([0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]);
    state.set(key, 4);
    state[12] = counter;
    state.set(nonce, 13);
    const s = new Int32Array(state);
    for (let i = 0; i < 10; i++) {
      quarter(s, 0, 4, 8, 12); quarter(s, 1, 5, 9, 13); quarter(s, 2, 6, 10, 14); quarter(s, 3, 7, 11, 15);
      quarter(s, 0, 5, 10, 15); quarter(s, 1, 6, 11, 12); quarter(s, 2, 7, 8, 13); quarter(s, 3, 4, 9, 14);
    }
    const out = new Uint8Array(64);
    for (let i = 0; i < 16; i++) {
      const v = (s[i] + state[i]) >>> 0;
      out[4 * i] = v & 255; out[4 * i + 1] = (v >>> 8) & 255; out[4 * i + 2] = (v >>> 16) & 255; out[4 * i + 3] = v >>> 24;
    }
    return out;
  }

  function chacha20(keyBytes, counter, nonceBytes, data) {
    const key = words(keyBytes), nonce = words(nonceBytes);
    const out = new Uint8Array(data.length);
    for (let offset = 0; offset < data.length; offset += 64) {
      const stream = block(key, (counter + offset / 64) >>> 0, nonce);
      const n = Math.min(64, data.length - offset);
      for (let i = 0; i < n; i++) out[offset + i] = data[offset + i] ^ stream[i];
    }
    return out;
  }

  function littleEndian(bytes) {
    let n = 0n;
    for (let i = bytes.length - 1; i >= 0; i--) n = (n << 8n) | BigInt(bytes[i]);
    return n;
  }

  function poly1305(key, message) {
    const r = littleEndian(key.subarray(0, 16)) & 0x0ffffffc0ffffffc0ffffffc0fffffffn;
    const s = littleEndian(key.subarray(16, 32));
    const p = (1n << 130n) - 5n;
    let acc = 0n;
    for (let i = 0; i < message.length; i += 16) {
      const chunk = message.subarray(i, Math.min(i + 16, message.length));
      acc = ((acc + littleEndian(chunk) + (1n << BigInt(8 * chunk.length))) * r) % p;
    }
    acc = (acc + s) & ((1n << 128n) - 1n);
    const tag = new Uint8Array(16);
    for (let i = 0; i < 16; i++) { tag[i] = Number(acc & 255n); acc >>= 8n; }
    return tag;
  }

  function macData(aad, ciphertext) {
    const pad = (n) => (16 - (n % 16)) % 16;
    const out = new Uint8Array(aad.length + pad(aad.length) + ciphertext.length + pad(ciphertext.length) + 16);
    out.set(aad, 0);
    out.set(ciphertext, aad.length + pad(aad.length));
    const lengths = new DataView(out.buffer, out.length - 16);
    lengths.setUint32(0, aad.length, true);
    lengths.setUint32(8, ciphertext.length, true);
    return out;
  }

  // Returns ciphertext followed by the 16-byte tag.
  function seal(key, nonce, plaintext, aad) {
    aad = aad || new Uint8Array(0);
    const otk = block(words(key), 0, words(nonce)).subarray(0, 32);
    const ciphertext = chacha20(key, 1, nonce, plaintext);
    const tag = poly1305(otk, macData(aad, ciphertext));
    const out = new Uint8Array(ciphertext.length + 16);
    out.set(ciphertext); out.set(tag, ciphertext.length);
    return out;
  }

  // Returns the plaintext, or null when the tag doesn't match.
  function open(key, nonce, sealed, aad) {
    aad = aad || new Uint8Array(0);
    if (sealed.length < 16) return null;
    const ciphertext = sealed.subarray(0, sealed.length - 16);
    const tag = sealed.subarray(sealed.length - 16);
    const otk = block(words(key), 0, words(nonce)).subarray(0, 32);
    const expected = poly1305(otk, macData(aad, ciphertext));
    let diff = 0;
    for (let i = 0; i < 16; i++) diff |= expected[i] ^ tag[i];
    return diff === 0 ? chacha20(key, 1, nonce, ciphertext) : null;
  }

  const api = { seal, open, chacha20, poly1305 };
  if (typeof module !== "undefined" && module.exports) module.exports = api; else root.ClavraAEAD = api;
})(this);
