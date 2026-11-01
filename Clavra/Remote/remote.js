// The phone side of Clavra's remote access. The Mac does the terminal work; this page draws the
// screen it sends and types back. Everything on the socket is sealed with the key from the QR code.
(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const [portText, secret] = location.hash.slice(1).split(".");
  const key = secret ? Uint8Array.from(atob(secret.replace(/-/g, "+").replace(/_/g, "/") + "==".slice(0, (4 - secret.length % 4) % 4)), (c) => c.charCodeAt(0)) : null;
  history.replaceState(null, "", location.pathname); // the key doesn't stay in the address bar

  let socket = null, challenge = null, sent = 0, received = 0, stopped = false, token = "";
  try { token = localStorage.getItem("clavra-token-" + portText) || ""; } catch (e) {}
  let cols = 80, rows = [], cursor = [0, 0], typing = false, ctrl = false, fit = true, session = "";

  const palette = ["#2a282e", "#e2857a", "#93c7a6", "#d8b46c", "#8fb3dc", "#c7a0d8", "#8ccbc7", "#d9d6cf",
                   "#5a5660", "#ee9a8f", "#a9d9b9", "#e6c68a", "#a8c6e8", "#d6b5e4", "#a4dcd8", "#f2efe8"];
  function color(value) {
    if (typeof value === "string") return value;
    if (value < 0) return null;
    if (value < 16) return palette[value];
    if (value < 232) {
      const n = value - 16, step = (v) => (v === 0 ? 0 : 55 + v * 40);
      return `rgb(${step(Math.floor(n / 36))},${step(Math.floor(n / 6) % 6)},${step(n % 6)})`;
    }
    const g = 8 + (value - 232) * 10;
    return `rgb(${g},${g},${g})`;
  }

  function deviceId() {
    try {
      let id = localStorage.getItem("clavra-device");
      if (!id) {
        id = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join("");
        localStorage.setItem("clavra-device", id);
      }
      return id;
    } catch (e) {
      // No storage (private mode): a fresh id for this page, never a shared one.
      return deviceId.fallback || (deviceId.fallback = Array.from(crypto.getRandomValues(new Uint8Array(16)), (b) => b.toString(16).padStart(2, "0")).join(""));
    }
  }

  function deviceName() {
    const ua = navigator.userAgent;
    const kind = /iPad/.test(ua) ? "iPad" : /iPhone/.test(ua) ? "iPhone" : /Android/.test(ua) ? "Android phone" : "Browser";
    const app = /CriOS|Chrome/.test(ua) ? "Chrome" : /Firefox|FxiOS/.test(ua) ? "Firefox" : /Safari/.test(ua) ? "Safari" : "";
    return app ? `${kind}, ${app}` : kind;
  }

  function send(object) {
    if (!socket || socket.readyState !== 1 || !challenge) return;
    object.n = ++sent;
    const nonce = crypto.getRandomValues(new Uint8Array(12));
    const sealed = ClavraAEAD.seal(key, nonce, new TextEncoder().encode(JSON.stringify(object)), challenge);
    const frame = new Uint8Array(12 + sealed.length);
    frame.set(nonce); frame.set(sealed, 12);
    socket.send(frame);
  }

  function intro(title, text) {
    $("intro").hidden = false;
    $("intro").querySelector("h1").textContent = title;
    $("intro-text").textContent = text;
    for (const id of ["bar", "screen", "keys", "form"]) $(id).hidden = true;
  }

  function showTerminal() {
    $("intro").hidden = true;
    for (const id of ["bar", "screen", "keys", "form"]) $(id).hidden = false;
  }

  function note(html, warn) {
    $("note").innerHTML = html;
    $("note").className = html ? "show" + (warn ? " warn" : "") : "";
  }

  function escape(text) {
    return text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }

  function drawRow(index) {
    const runs = rows[index] || [];
    let html = "", column = 0;
    for (const [text, fg, bg, flags] of runs) {
      let foreground = color(fg), background = color(bg);
      if (flags & 8) [foreground, background] = [background || "#121114", foreground || "#e6e3dc"];
      const style = [];
      if (foreground) style.push(`color:${foreground}`);
      if (background) style.push(`background:${background}`);
      if (flags & 1) style.push("font-weight:600");
      if (flags & 2) style.push("text-decoration:underline");
      if (flags & 32) style.push("opacity:.6");
      if (flags & 64) style.push("font-style:italic");
      const chars = Array.from(text);
      if (cursor[1] === index && cursor[0] >= column && cursor[0] < column + chars.length) {
        const at = cursor[0] - column;
        html += `<span style="${style.join(";")}">${escape(chars.slice(0, at).join(""))}<span class="cursor">${escape(chars[at])}</span>${escape(chars.slice(at + 1).join(""))}</span>`;
      } else {
        html += `<span style="${style.join(";")}">${escape(text)}</span>`;
      }
      column += chars.length;
    }
    if (cursor[1] === index && cursor[0] >= column) html += " ".repeat(cursor[0] - column) + '<span class="cursor"> </span>';
    return html;
  }

  function draw() {
    const screen = $("screen");
    while (screen.children.length < rows.length) { const div = document.createElement("div"); div.className = "row"; screen.appendChild(div); }
    while (screen.children.length > rows.length) screen.lastChild.remove();
    for (let i = 0; i < rows.length; i++) screen.children[i].innerHTML = drawRow(i);
    sizeText();
  }

  // Fit the Mac's columns to the phone's width (never below a size you can read), or a comfortable
  // size that scrolls sideways. Either way the cursor's row stays in view.
  function sizeText() {
    const screen = $("screen");
    const width = screen.clientWidth - 16;
    const size = fit ? Math.max(7.5, Math.min(15, width / (cols * 0.602))) : 13;
    screen.style.fontSize = size + "px";
    const row = screen.children[cursor[1]];
    if (row) {
      const top = row.offsetTop - screen.offsetTop, bottom = top + row.offsetHeight;
      if (top < screen.scrollTop || bottom > screen.scrollTop + screen.clientHeight) screen.scrollTop = bottom - screen.clientHeight + 8;
      if (!fit) {
        const x = cursor[0] * size * 0.602;
        if (x < screen.scrollLeft || x > screen.scrollLeft + width) screen.scrollLeft = Math.max(0, x - width / 2);
      }
    }
  }

  // iOS keeps the page tall when the keyboard opens and slides it up instead; follow the visible
  // area so the key row and the field sit right above the keyboard.
  function followViewport() {
    const view = window.visualViewport;
    if (!view) return;
    document.documentElement.style.setProperty("--height", view.height + "px");
    window.scrollTo(0, 0);
    sizeText();
  }
  if (window.visualViewport) {
    window.visualViewport.addEventListener("resize", followViewport);
    window.visualViewport.addEventListener("scroll", () => window.scrollTo(0, 0));
  }

  function handle(message) {
    switch (message.t) {
      case "wait":
        intro("Waiting for your Mac", "Choose Allow on the Mac to let this phone in.");
        break;
      case "bye":
        stopped = true;
        intro("Disconnected", "Phone access was turned off on the Mac, or this phone was turned away. Scan the code again to ask once more.");
        socket.close();
        break;
      case "token":
        token = message.token;
        try { localStorage.setItem("clavra-token-" + portText, token); } catch (e) {}
        break;
      case "sessions": {
        showTerminal();
        const select = $("tabs");
        select.innerHTML = "";
        for (const item of message.list) {
          const option = document.createElement("option");
          option.value = item.id;
          option.textContent = (item.place === "production" ? "● " : "") + item.title + (item.live ? "" : " (not connected)");
          select.appendChild(option);
        }
        if (!message.list.length) note("No tabs are open on the Mac.");
        select.value = message.selected;
        session = message.selected;
        break;
      }
      case "screen":
        showTerminal();
        if (message.empty) { rows = []; draw(); note("No tabs are open on the Mac."); break; }
        if (message.full || message.session !== session) rows = new Array(message.count).fill([]);
        session = message.session;
        cols = message.cols; cursor = message.cursor; rows.length = message.count;
        for (const [index, row] of message.rows) rows[index] = JSON.parse(row);
        draw();
        typing = message.typing;
        $("input").disabled = !typing;
        $("input").placeholder = typing ? "Type here" : "View only";
        if (message.held) note(`Waiting for a yes on the Mac: <b>${escape(message.held)}</b>`, true);
        else if (!typing) note("Production tab: view only. Typing can be allowed in Clavra on the Mac.");
        else note("");
        break;
      case "readonly":
        note("This tab is view only from a phone.", true);
        break;
    }
  }

  function connect() {
    if (!key || !portText) { intro("Scan the code again", "This link is missing its key. Open Remote Access in Clavra and scan the QR code."); return; }
    socket = new WebSocket(`ws://${location.hostname}:${portText}`);
    socket.binaryType = "arraybuffer";
    socket.onmessage = (event) => {
      const data = new Uint8Array(event.data);
      if (!challenge) {
        if (new TextDecoder().decode(data.subarray(0, 4)) !== "CLV1") return socket.close();
        challenge = data.slice(4, 20);
        send({ t: "hello", device: deviceId(), name: deviceName(), token: token });
        return;
      }
      const opened = ClavraAEAD.open(key, data.subarray(0, 12), data.subarray(12), challenge);
      if (!opened) return socket.close();
      const message = JSON.parse(new TextDecoder().decode(opened));
      if (!(message.n > received)) return socket.close();
      received = message.n;
      $("dot").classList.add("on");
      handle(message);
    };
    socket.onclose = () => {
      $("dot").classList.remove("on");
      if (stopped) return;
      if ($("intro").hidden) note("Connection lost. Reconnecting…", true);
      challenge = null; sent = 0; received = 0;
      setTimeout(connect, 2000);
    };
  }

  function type(text) {
    if (!typing || !text) return;
    if (ctrl && text.length === 1) {
      const code = text.toUpperCase().charCodeAt(0);
      if (code >= 64 && code <= 95) text = String.fromCharCode(code - 64);
      ctrl = false; $("ctrl").classList.remove("on");
    }
    send({ t: "input", data: text, session: session });
  }

  const keys = { esc: "\x1b", tab: "\t", up: "\x1b[A", down: "\x1b[B", right: "\x1b[C", left: "\x1b[D",
                 cc: "\x03", cd: "\x04", pipe: "|", tilde: "~", slash: "/" };
  // Tapping a key shouldn't steal focus from the field (which would drop the keyboard).
  $("keys").addEventListener("mousedown", (event) => event.preventDefault());
  $("keys").addEventListener("touchstart", () => {}, { passive: true });
  $("keys").addEventListener("click", (event) => {
    const name = event.target.dataset && event.target.dataset.key;
    if (!name) return;
    if (name === "ctrl") { ctrl = !ctrl; $("ctrl").classList.toggle("on", ctrl); return; }
    type(keys[name]);
    // Keep the keyboard up if it was; don't open it just for an arrow key.
    if (document.activeElement === $("input")) $("input").focus();
  });

  // Each keystroke goes straight through; the field stays empty.
  $("input").addEventListener("beforeinput", (event) => {
    if (event.inputType === "insertText" || event.inputType === "insertReplacementText") type(event.data || "");
    else if (event.inputType === "deleteContentBackward") type("\x7f");
    else if (event.inputType === "insertLineBreak") type("\r");
    else return;
    event.preventDefault();
  });
  $("input").addEventListener("input", () => { if ($("input").value) { type($("input").value); $("input").value = ""; } });
  $("form").addEventListener("submit", (event) => { event.preventDefault(); type("\r"); });
  $("tabs").addEventListener("change", () => send({ t: "select", session: $("tabs").value }));
  $("fit").addEventListener("click", () => { fit = !fit; sizeText(); });
  window.addEventListener("resize", sizeText);
  $("screen").addEventListener("click", () => $("input").focus());
  connect();
})();
