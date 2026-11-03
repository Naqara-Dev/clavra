// The phone side of Clavra's remote access. The Mac does the terminal work; this page draws the
// screen it sends and types back. Everything on the socket is sealed with the key from the QR code.
(function () {
  "use strict";

  const $ = (id) => document.getElementById(id);
  // Two ways in. Through the relay (this page on clavra.naqara.dev): #r=<room>&k=<key>.
  // Straight to the Mac (this page served by the Mac on the same Wi-Fi): #<port>.<key>.
  const fragment = location.hash.slice(1);
  const relayed = fragment.startsWith("r=");
  const params = new URLSearchParams(relayed ? fragment : "");
  const [portText, lanSecret] = relayed ? ["", ""] : fragment.split(".");
  const room = params.get("r") || "";
  const secret = relayed ? params.get("k") || "" : lanSecret;
  const key = secret ? Uint8Array.from(atob(secret.replace(/-/g, "+").replace(/_/g, "/") + "==".slice(0, (4 - secret.length % 4) % 4)), (c) => c.charCodeAt(0)) : null;
  const place = relayed ? room : portText; // what this phone's token is filed under
  history.replaceState(null, "", location.pathname); // the key doesn't stay in the address bar

  let socket = null, challenge = null, sent = 0, received = 0, stopped = false, token = "";
  try { token = localStorage.getItem("clavra-token-" + place) || ""; } catch (e) {}
  // rows[i] is line number first + i: the scrollback the Mac keeps, then the screen.
  let cols = 80, rows = [], first = 0, cursor = [0, 0], typing = false, ctrl = false, fit = true, session = "", hosts = [];
  // Held commands on hosts where only a phone can say yes, and the ones already answered here.
  let pending = [], answered = new Set(), asking = null;
  const title = document.title;

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
    $("how").hidden = true;
    $("intro").hidden = false;
    $("intro").querySelector("h1").textContent = title;
    $("intro-text").textContent = text;
    for (const id of ["bar", "wrap", "keys", "form"]) $(id).hidden = true;
  }

  function showTerminal() {
    $("intro").hidden = true;
    for (const id of ["bar", "wrap", "keys", "form"]) $(id).hidden = false;
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
    const line = first + index;
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
      if (cursor[1] === line && cursor[0] >= column && cursor[0] < column + chars.length) {
        const at = cursor[0] - column;
        html += `<span style="${style.join(";")}">${escape(chars.slice(0, at).join(""))}<span class="cursor">${escape(chars[at])}</span>${escape(chars.slice(at + 1).join(""))}</span>`;
      } else {
        html += `<span style="${style.join(";")}">${escape(text)}</span>`;
      }
      column += chars.length;
    }
    if (cursor[1] === line && cursor[0] >= column) html += " ".repeat(cursor[0] - column) + '<span class="cursor"> </span>';
    return html;
  }

  // Only the rows that changed are drawn again; scrolled-off lines arrive once and stay.
  function draw(dirty, follow) {
    const screen = $("screen");
    while (screen.children.length < rows.length) { const div = document.createElement("div"); div.className = "row"; screen.appendChild(div); }
    while (screen.children.length > rows.length) screen.lastChild.remove();
    for (const i of dirty) if (i >= 0 && i < rows.length) screen.children[i].innerHTML = drawRow(i);
    sizeText(follow);
  }

  function atBottom() {
    const screen = $("screen");
    return screen.scrollTop + screen.clientHeight >= screen.scrollHeight - 24;
  }

  // The width of one character for each pixel of font size, measured in the font the phone has.
  let ratio = 0;
  function charRatio() {
    if (ratio) return ratio;
    const probe = document.createElement("span");
    probe.style.cssText = "position:absolute;visibility:hidden;white-space:pre;font-size:100px;font-family:inherit";
    probe.textContent = "M".repeat(50);
    $("screen").appendChild(probe);
    ratio = probe.getBoundingClientRect().width / 5000 || 0.602;
    probe.remove();
    return ratio;
  }

  // Fit the Mac's columns to the phone's width (never below a size you can read), or a comfortable
  // size that scrolls sideways. While you're at the bottom, the cursor's row stays in view; scrolled
  // up into earlier output, the page stays where you are.
  function sizeText(follow) {
    const screen = $("screen");
    const width = screen.clientWidth - 16;
    const size = fit ? Math.max(7.5, Math.min(15, Math.floor(width / (cols * charRatio()) * 10) / 10)) : 13;
    screen.style.fontSize = size + "px";
    screen.classList.toggle("fit", fit && cols * charRatio() * size <= width + 1);
    if (fit && screen.classList.contains("fit")) screen.scrollLeft = 0;
    if (follow !== false) {
      const row = screen.children[cursor[1] - first];
      if (row) {
        const top = row.offsetTop - screen.offsetTop, bottom = top + row.offsetHeight;
        if (top < screen.scrollTop || bottom > screen.scrollTop + screen.clientHeight) screen.scrollTop = bottom - screen.clientHeight + 8;
        if (!fit) {
          const x = cursor[0] * size * charRatio();
          if (x < screen.scrollLeft || x > screen.scrollLeft + width) screen.scrollLeft = Math.max(0, x - width / 2);
        }
      } else {
        screen.scrollTop = screen.scrollHeight;
      }
    }
    $("latest").hidden = atBottom();
  }

  // iOS keeps the page tall when the keyboard opens and slides it up instead; follow the visible
  // area so the key row and the field sit right above the keyboard.
  function followViewport() {
    const view = window.visualViewport;
    if (!view) return;
    document.documentElement.style.setProperty("--height", view.height + "px");
    window.scrollTo(0, 0);
    sizeText(atBottom());
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
        try { localStorage.setItem("clavra-token-" + place, token); } catch (e) {}
        break;
      case "sessions": {
        showTerminal();
        const select = $("tabs");
        select.innerHTML = "";
        for (const item of message.list) {
          const option = document.createElement("option");
          option.value = item.id;
          option.textContent = (item.place === "production" ? "\u25CF\uFE0E " : "") + item.title + (item.live ? "" : " (not connected)");
          select.appendChild(option);
        }
        if (!message.list.length) {
          const option = document.createElement("option");
          option.textContent = "No tabs open";
          option.value = "";
          select.appendChild(option);
        }
        select.value = message.selected;
        session = message.selected;
        hosts = message.hosts || [];
        $("new").hidden = !hosts.length;
        pending = message.list.filter((item) => item.approve && item.held);
        // Answers for commands no longer held are forgotten, so the same command held again asks again.
        answered = new Set([...answered].filter((key) => pending.some((p) => p.id + "\n" + p.held === key)));
        ask();
        if (!$("picker").hidden) drawHosts();
        break;
      }
      case "screen": {
        showTerminal();
        if (message.empty) {
          rows = []; first = 0; $("screen").innerHTML = "";
          note(hosts.length ? "No tabs are open on the Mac. Tap + to open one." : "No tabs are open on the Mac.");
          break;
        }
        // Clavra 0.4 sends only the screen, numbered from 0, with no scrollback.
        if (message.start === undefined) { message.start = 0; message.end = message.count; }
        const follow = message.full || message.session !== session || atBottom();
        const dirty = new Set();
        if (message.full || message.session !== session) {
          rows = []; first = message.start; $("screen").innerHTML = "";
        }
        session = message.session;
        // Lines the Mac no longer keeps fall off the top.
        if (message.start > first) {
          const drop = Math.min(message.start - first, rows.length);
          rows.splice(0, drop);
          const screen = $("screen");
          for (let i = 0; i < drop && screen.firstChild; i++) screen.firstChild.remove();
          first = message.start;
        }
        rows.length = Math.max(0, message.end - first);
        for (let i = 0; i < rows.length; i++) if (rows[i] === undefined) { rows[i] = []; dirty.add(i); }
        for (const [line, row] of message.rows) { rows[line - first] = JSON.parse(row); dirty.add(line - first); }
        dirty.add(cursor[1] - first);
        cols = message.cols; cursor = message.cursor;
        dirty.add(cursor[1] - first);
        draw(dirty, follow);
        typing = message.typing;
        $("input").disabled = !typing;
        $("input").placeholder = typing ? "Type here" : "View only";
        if (message.held && message.approve) note(`Needs your yes: <b>${escape(message.held)}</b>. Tap to review.`, true);
        else if (message.held) note(`Waiting for a yes on the Mac: <b>${escape(message.held)}</b>`, true);
        else if (!typing) note("Production tab: view only. Typing can be allowed in Clavra on the Mac.");
        else note("");
        break;
      }
      case "readonly":
        note("This tab is view only from a phone.", true);
        break;
    }
  }

  function connect() {
    if (!key || !place) {
      // Opened by hand, not from a QR code: explain how to get here properly.
      $("intro").hidden = true;
      $("how").hidden = false;
      document.title = "Connect your phone · Clavra";
      return;
    }
    socket = relayed
      ? new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/relay/${room}?role=phone`)
      : new WebSocket(`ws://${location.hostname}:${portText}`);
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
    socket.onclose = (event) => {
      $("dot").classList.remove("on");
      if (stopped) return;
      if (event.code === 4002 && !challenge) intro("Your Mac isn't there", "Open Clavra on your Mac and turn on Phone Access. This page keeps trying.");
      if ($("intro").hidden) note("Connection lost. Reconnecting…", true);
      challenge = null; sent = 0; received = 0;
      setTimeout(connect, 2000);
    };
  }

  // A command held on a host where only a phone can say yes: the first one not answered here.
  function ask(again) {
    if (again) answered.clear();
    const item = pending.find((p) => !answered.has(p.id + "\n" + p.held));
    asking = item || null;
    $("note").classList.toggle("ask", !!pending.length);
    if (!item) { $("approve").hidden = true; document.title = title; return; }
    $("approve-host").textContent = item.title + " · " + (item.placeName || item.place);
    $("approve-command").textContent = item.held;
    $("approve-reason").textContent = (item.reason ? item.reason + ". " : "") + "Nothing has been sent yet.";
    const impact = item.impact || [];
    $("approve-impact").hidden = !impact.length;
    $("approve-impact").innerHTML = impact.length
      ? `<b>${escape(impact[0])}</b>` + impact.slice(1).map((line) => `<span>${escape(line)}</span>`).join("") : "";
    $("approve").hidden = false;
    document.title = "Approve? · Clavra";
    if (navigator.vibrate) navigator.vibrate(120);
  }

  function answer(run) {
    if (!asking) return;
    send({ t: "approve", session: asking.id, command: asking.held, run: run });
    answered.add(asking.id + "\n" + asking.held);
    note(run ? "Sent: run it." : "Sent: don't run it.");
    ask();
  }

  // Saved hosts on the Mac, to open one in a new tab.
  function drawHosts() {
    const list = $("host-list");
    list.innerHTML = "";
    // Production, staging, the user's own labels, then personal (Clavra 0.5 sends no names).
    const order = { production: 0, staging: 1, personal: 3 };
    const label = { production: "Production", staging: "Staging", personal: "Personal" };
    const rank = (host) => order[host.place] ?? 2;
    let group = "";
    const sorted = hosts.slice().sort((a, b) => rank(a) - rank(b) || (a.placeName || "").localeCompare(b.placeName || ""));
    for (const host of sorted) {
      if (host.place !== group) {
        group = host.place;
        const heading = document.createElement("p");
        heading.className = "group " + (order[group] === undefined ? "custom" : group);
        heading.textContent = host.placeName || label[group] || "Other";
        list.appendChild(heading);
      }
      const button = document.createElement("button");
      button.type = "button";
      button.innerHTML = `<b>${escape(host.title)}</b><span>${escape(host.host)}</span>`;
      button.addEventListener("click", () => {
        send({ t: "open", host: host.id });
        $("picker").hidden = true;
        note("Opening " + escape(host.title) + "\u2026");
      });
      list.appendChild(button);
    }
  }

  function type(text) {
    if (!typing || !text) return;
    const screen = $("screen");
    if (!atBottom()) screen.scrollTop = screen.scrollHeight;
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
  $("fit").addEventListener("click", () => { fit = !fit; $("screen").scrollLeft = 0; sizeText(); });
  $("new").addEventListener("click", () => { drawHosts(); $("picker").hidden = false; });
  $("picker-close").addEventListener("click", () => { $("picker").hidden = true; });
  $("approve-yes").addEventListener("click", () => answer(true));
  $("approve-no").addEventListener("click", () => answer(false));
  $("note").addEventListener("click", () => { if (pending.length) ask(true); });
  $("picker").addEventListener("click", (event) => { if (event.target === $("picker")) $("picker").hidden = true; });
  $("latest").addEventListener("click", () => { const screen = $("screen"); screen.scrollTop = screen.scrollHeight; sizeText(false); });
  $("screen").addEventListener("scroll", () => { $("latest").hidden = atBottom(); }, { passive: true });
  window.addEventListener("resize", () => sizeText(atBottom()));
  // A tap focuses the field, unless it ended a scroll or picked out text.
  $("screen").addEventListener("click", () => { if (!String(window.getSelection() || "")) $("input").focus(); });
  connect();
})();
