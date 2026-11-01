// Resolve appearance before styles paint, including when browser storage is unavailable.
(() => {
  "use strict";
  const root = document.documentElement;
  const system = window.matchMedia("(prefers-color-scheme: dark)");
  const choices = ["system", "light", "dark"];
  let stored;
  try { stored = localStorage.getItem("simlaunch-site-appearance"); } catch { /* Optional storage. */ }
  const requested = new URLSearchParams(location.search).get("theme");
  let choice = [requested, stored].find(value => choices.includes(value)) || "system";

  function apply(persist = false) {
    const theme = choice === "system" ? (system.matches ? "dark" : "light") : choice;
    root.dataset.theme = theme;
    root.dataset.themePreference = choice;
    root.style.colorScheme = theme;
    document.querySelector('meta[name="theme-color"]').content = theme === "dark" ? "#141c1b" : "#f8faf8";
    document.querySelectorAll("[data-theme-choice]").forEach(button => {
      button.setAttribute("aria-pressed", String(button.dataset.themeChoice === choice));
    });
    if (persist) {
      try { localStorage.setItem("simlaunch-site-appearance", choice); } catch { /* Optional storage. */ }
      try {
        const url = new URL(location.href);
        url.searchParams.set("theme", choice);
        history.replaceState(null, "", url);
      } catch { /* File previews may not support history updates. */ }
    }
    document.dispatchEvent(new CustomEvent("simlaunch:appearancechange"));
  }

  apply();
  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll("[data-theme-choice]").forEach(button => {
      button.addEventListener("click", () => {
        choice = button.dataset.themeChoice;
        apply(true);
      });
    });
    apply();
  }, { once: true });
  system.addEventListener("change", () => {
    if (choice === "system") apply();
  });
})();
