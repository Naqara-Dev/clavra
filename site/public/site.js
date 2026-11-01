// The hero's two buttons answer the way Clavra would, without a server to answer for.
document.querySelectorAll("[data-answer]").forEach(function (button) {
  button.addEventListener("click", function () {
    var ask = document.querySelector("[data-ask]");
    var after = document.querySelector("[data-after]");
    after.textContent = button.dataset.answer === "run"
      ? "On a real server it would run now. Here, nothing did: this is only a page."
      : "Nothing was sent. The command is still on the line, ready to fix.";
    ask.hidden = true;
    after.hidden = false;
  });
});
