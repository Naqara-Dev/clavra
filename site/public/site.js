// clavra.naqara.dev. Every moving part here acts out something Clavra does; with reduced motion
// the page shows the finished state of each instead.
(function () {
  var still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var $ = function (selector, root) { return (root || document).querySelector(selector); };
  var $$ = function (selector, root) { return Array.prototype.slice.call((root || document).querySelectorAll(selector)); };
  var wait = function (ms) { return new Promise(function (done) { setTimeout(done, ms); }); };

  if (still) document.documentElement.classList.add("no-motion");

  // Runs `play` while `element` is on screen and the tab is visible; pauses otherwise.
  function whileVisible(element, play) {
    var state = { onScreen: false, running: false };
    function live() { return state.onScreen && !document.hidden; }
    function kick() {
      if (state.running || !live()) return;
      state.running = true;
      play(live).then(function () { state.running = false; kick(); });
    }
    new IntersectionObserver(function (entries) {
      state.onScreen = entries[0].isIntersecting;
      kick();
    }, { threshold: 0.25 }).observe(element);
    document.addEventListener("visibilitychange", kick);
  }

  async function until(live) {
    while (!live()) await wait(300);
  }

  async function type(target, text, live, speed) {
    for (var i = 0; i < text.length; i++) {
      await until(live);
      target.textContent += text[i];
      await wait((speed || 46) + Math.random() * 40);
    }
  }

  async function erase(target, speed) {
    while (target.textContent.length) {
      target.textContent = target.textContent.slice(0, -1);
      await wait(speed || 14);
    }
  }

  /* ---------- The ticker runs on a second copy of its list, so it loops without a seam ---------- */

  var ticker = $("[data-ticker]");
  if (ticker) {
    var copy = $(".ticker__list", ticker).cloneNode(true);
    copy.setAttribute("aria-hidden", "true");
    ticker.appendChild(copy);
  }

  /* ---------- Menu on phones ---------- */

  var menu = $("[data-menu]");
  var nav = $("#nav");
  if (menu && nav) {
    var setMenu = function (open) {
      menu.setAttribute("aria-expanded", String(open));
      nav.classList.toggle("is-open", open);
    };
    menu.addEventListener("click", function () { setMenu(menu.getAttribute("aria-expanded") !== "true"); });
    $$("a", nav).forEach(function (link) { link.addEventListener("click", function () { setMenu(false); }); });
    document.addEventListener("keydown", function (event) { if (event.key === "Escape") setMenu(false); });
    document.addEventListener("click", function (event) {
      if (!nav.contains(event.target) && !menu.contains(event.target)) setMenu(false);
    });
  }

  /* ---------- The guard, played out ---------- */

  var guard = $("[data-guard]");
  var scenes = [
    { command: "rm -rf /var/www/releases", why: "Deletes files without asking." },
    { command: "psql -c 'DELETE FROM orders;'", why: "Deletes every row: there's no WHERE." },
    { command: "docker compose down", why: "Takes containers down." },
    { command: "git push --force origin main", why: "Rewrites history on the remote." },
    { command: "kubectl delete ns payments", why: "Changes what's running in the cluster." }
  ];

  if (guard) {
    var typed = $("[data-typed]", guard);
    var key = $("[data-key]", guard);
    var ask = $("[data-ask]", guard);
    var askCommand = $("[data-ask-command]", guard);
    var askWhy = $("[data-ask-why]", guard);
    var after = $("[data-after]", guard);
    var heldCount = $("[data-held]", guard);
    var count = $(".guard__count", guard);
    var stop = $('[data-answer="stop"]', guard);
    var held = 0;
    var pausedUntil = 0;

    var showQuestion = function (scene) {
      askCommand.textContent = scene.command;
      askWhy.textContent = scene.why + " Nothing has been sent yet.";
      ask.hidden = false;
      after.hidden = true;
      requestAnimationFrame(function () { ask.classList.add("is-in"); });
    };

    var bumpHeld = function () {
      held += 1;
      heldCount.textContent = String(held);
      count.classList.remove("is-bumped");
      void count.offsetWidth;
      count.classList.add("is-bumped");
    };

    // Clicking either button answers the way Clavra would, and holds the loop for a moment.
    $$("[data-answer]", guard).forEach(function (button) {
      button.addEventListener("click", function () {
        pausedUntil = Date.now() + 6000;
        ask.classList.remove("is-in");
        ask.hidden = true;
        after.hidden = false;
        if (button.dataset.answer === "run") {
          after.textContent = "On a real server it would run now. Here nothing did: this is only a page.";
          after.style.color = "var(--coral)";
        } else {
          after.textContent = "Held. Nothing was sent; the command is still on the line to fix.";
          after.style.color = "";
          bumpHeld();
        }
      });
    });

    if (!still) {
      typed.textContent = "";
      ask.classList.remove("is-in");
      ask.hidden = true;
      var scene = 0;
      whileVisible(guard, async function (live) {
        while (Date.now() < pausedUntil) await wait(400);
        var current = scenes[scene % scenes.length];
        scene += 1;
        after.hidden = true;
        await erase(typed);
        guard.classList.add("is-typing");
        await wait(500);
        await type(typed, current.command, live);
        guard.classList.remove("is-typing");
        await wait(380);
        key.classList.remove("is-pressed");
        void key.offsetWidth;
        key.classList.add("is-pressed");
        await wait(420);
        showQuestion(current);
        await wait(2300);
        if (Date.now() < pausedUntil) return;
        stop.classList.add("is-pressed");
        await wait(200);
        stop.classList.remove("is-pressed");
        ask.classList.remove("is-in");
        await wait(260);
        ask.hidden = true;
        key.classList.remove("is-pressed");
        after.textContent = "Held. Nothing was sent.";
        after.style.color = "";
        after.hidden = false;
        bumpHeld();
        await wait(1700);
      });
    }
  }

  /* ---------- A little terminal per label ---------- */

  var minis = {
    personal: async function (line, live) {
      line.innerHTML = '<span class="p">pi@lab:~$</span> <span class="t"></span><span class="caret"></span>';
      await type($(".t", line), "uptime", live, 60);
      await wait(250);
      $(".caret", line).remove();
      line.insertAdjacentHTML("beforeend", '<span class="out">14:02 up 41 days, load 0.08</span>');
      await wait(2600);
    },
    staging: async function (line, live) {
      line.innerHTML = '<span class="p">deploy@web-staging:~$</span> <span class="t"></span><span class="ghost"></span><span class="caret"></span>';
      await type($(".t", line), "npm run mig", live, 70);
      await wait(200);
      $(".ghost", line).textContent = "rate:latest";
      await wait(900);
      $(".caret", line).insertAdjacentHTML("afterend", '<span class="chip">→</span>');
      await wait(380);
      $(".t", line).textContent += $(".ghost", line).textContent;
      $(".ghost", line).textContent = "";
      await wait(500);
      $(".caret", line).remove();
      $(".chip", line).remove();
      line.insertAdjacentHTML("beforeend", '<span class="out">3 migrations, done in 1.2 s</span>');
      await wait(2600);
    },
    production: async function (line, live) {
      line.innerHTML = '<span class="p">deploy@api-prod:~$</span> <span class="t"></span><span class="caret"></span>';
      await type($(".t", line), "systemctl restart nginx", live, 55);
      await wait(300);
      $(".caret", line).remove();
      line.insertAdjacentHTML("beforeend", '<br><span class="held">Waiting for your yes</span>');
      await wait(2800);
    }
  };

  $$("[data-mini]").forEach(function (box) {
    var line = $(".mini__line", box);
    var play = minis[box.dataset.mini];
    if (still) {
      // The end of each little story, without the typing.
      var finished = {
        personal: '<span class="p">pi@lab:~$</span> uptime<span class="out">14:02 up 41 days, load 0.08</span>',
        staging: '<span class="p">deploy@web-staging:~$</span> npm run mig<span class="ghost">rate:latest</span>',
        production: '<span class="p">deploy@api-prod:~$</span> systemctl restart nginx<br><span class="held">Waiting for your yes</span>'
      };
      line.innerHTML = finished[box.dataset.mini];
      return;
    }
    whileVisible(box, function (live) { return play(line, live); });
  });

  /* ---------- Reveals as the page scrolls ---------- */

  var reveal = $$(
    ".places h2, .places .section__lede, .places__item, .feature__text, .phone__text, " +
    ".more h2, .more .section__lede, .more__item, .details h2, .details__list > div, .faq h2, .faq details, .end__box"
  );
  var wipes = $$("[data-wipe]");

  if (!still && "IntersectionObserver" in window) {
    document.documentElement.classList.add("js-motion");
    reveal.forEach(function (element, index) {
      element.setAttribute("data-reveal", "");
      if (element.matches(".places__item, .more__item, .details__list > div, .faq details")) {
        element.style.setProperty("--reveal-delay", (index % 4) * 90 + "ms");
      }
    });
    var revealer = new IntersectionObserver(function (entries, observer) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        var feature = entry.target.closest(".feature");
        if (feature) feature.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    }, { threshold: 0.15, rootMargin: "0px 0px -40px 0px" });
    reveal.concat(wipes).forEach(function (element) { revealer.observe(element); });
  }

  /* ---------- Phone: the camera scans, then the three steps light up in turn ---------- */

  var phone = $("[data-phone]");
  var steps = $$("[data-steps] li");
  if (phone && steps.length && !still) {
    whileVisible(phone, async function () {
      phone.classList.remove("is-scanning");
      void phone.offsetWidth;
      phone.classList.add("is-scanning");
      for (var i = 0; i < steps.length; i++) {
        steps.forEach(function (step, index) { step.classList.toggle("is-on", index === i); });
        await wait(1500);
      }
      steps.forEach(function (step) { step.classList.add("is-on"); });
      await wait(3600);
    });
  } else {
    steps.forEach(function (step) { step.classList.add("is-on"); });
  }

  /* ---------- Scroll: the header gets its backdrop once the page moves ---------- */

  var queued = false;
  function onScroll() {
    if (queued) return;
    queued = true;
    requestAnimationFrame(function () {
      queued = false;
      document.documentElement.classList.toggle("is-scrolled", window.scrollY > 8);
    });
  }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  /* ---------- Which section you're in, under the header links ---------- */

  var links = $$(".top__nav a[data-section]");
  if (links.length && "IntersectionObserver" in window) {
    var current = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        links.forEach(function (link) { link.classList.toggle("is-current", link.dataset.section === entry.target.id); });
      });
    }, { rootMargin: "-45% 0px -50% 0px" });
    links.forEach(function (link) {
      var section = document.getElementById(link.dataset.section);
      if (section) current.observe(section);
    });
  }

  /* ---------- Questions open and close smoothly ---------- */

  $$(".faq details").forEach(function (details) {
    var summary = $("summary", details);
    var body = $("p", details);
    summary.addEventListener("click", function (event) {
      if (still || !body.animate) return;
      event.preventDefault();
      if (details.open) {
        var closing = body.animate([{ height: body.offsetHeight + "px", opacity: 1 }, { height: "0px", opacity: 0 }],
          { duration: 260, easing: "cubic-bezier(.2,.75,.25,1)" });
        closing.onfinish = function () { details.open = false; };
      } else {
        details.open = true;
        var height = body.offsetHeight;
        body.animate([{ height: "0px", opacity: 0 }, { height: height + "px", opacity: 1 }],
          { duration: 360, easing: "cubic-bezier(.2,.75,.25,1)" });
      }
    });
  });
})();
