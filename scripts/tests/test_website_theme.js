const { test } = require("node:test");
const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { runInNewContext } = require("node:vm");

const source = readFileSync(join(__dirname, "../../website/appearance.js"), "utf8");

function page({ dark = false, stored, url = "https://example.com/SimLaunch/", blocked = false } = {}) {
  const root = { dataset: {}, style: {} };
  const meta = {};
  const events = new Map();
  const storage = new Map(stored ? [["simlaunch-site-appearance", stored]] : []);
  const location = { href: url, search: new URL(url).search };
  let systemListener;
  const system = {
    matches: dark,
    addEventListener(name, callback) { assert.equal(name, "change"); systemListener = callback; }
  };
  const buttons = ["system", "light", "dark"].map(choice => ({
    dataset: { themeChoice: choice }, attrs: {},
    setAttribute(name, value) { this.attrs[name] = value; },
    addEventListener(name, callback) { assert.equal(name, "click"); this.click = callback; }
  }));
  runInNewContext(source, {
    URL, URLSearchParams, location,
    window: { matchMedia: () => system },
    localStorage: {
      getItem(key) { if (blocked) throw new Error("Storage blocked"); return storage.get(key); },
      setItem(key, value) { if (blocked) throw new Error("Storage blocked"); storage.set(key, value); }
    },
    history: { replaceState(_, __, next) { location.href = String(next); location.search = new URL(next).search; } },
    CustomEvent: class { constructor(type) { this.type = type; } },
    document: {
      documentElement: root,
      querySelector: () => meta,
      querySelectorAll: () => buttons,
      addEventListener: (name, callback) => events.set(name, callback),
      dispatchEvent: () => {}
    }
  });
  return {
    root, meta, location, storage, buttons,
    ready() { events.get("DOMContentLoaded")(); },
    choose(choice) { buttons.find(button => button.dataset.themeChoice === choice).click(); },
    systemChanged(dark) { system.matches = dark; systemListener(); }
  };
}

test("initial appearance follows the system before the document is ready", () => {
  const p = page({ dark: true });
  assert.equal(p.root.dataset.theme, "dark");
  assert.equal(p.root.dataset.themePreference, "system");
  assert.equal(p.root.style.colorScheme, "dark");
  assert.equal(p.meta.content, "#141c1b");
  p.ready();
  assert.equal(p.buttons[0].attrs["aria-pressed"], "true");
});

test("system mode responds to a later operating system appearance change", () => {
  const p = page({ dark: true });
  p.ready();
  p.systemChanged(false);
  assert.equal(p.root.dataset.theme, "light");
  assert.equal(p.meta.content, "#f8faf8");
});

test("a manual preference survives reload and does not follow system changes", () => {
  const p = page();
  p.ready();
  p.choose("dark");
  p.systemChanged(false);
  assert.equal(p.root.dataset.theme, "dark");
  const saved = p.storage.get("simlaunch-site-appearance");
  assert.equal(saved, "dark");
  assert.equal(page({ stored: saved }).root.dataset.theme, "dark");
  p.choose("system");
  assert.equal(p.root.dataset.theme, "light");
  assert.equal(p.root.dataset.themePreference, "system");
});

test("shared URLs override stored appearance without losing language or anchors", () => {
  const p = page({ stored: "dark", url: "https://example.com/SimLaunch/?lang=en&theme=light#install" });
  assert.equal(p.root.dataset.theme, "light");
  p.ready();
  p.choose("dark");
  const url = new URL(p.location.href);
  assert.equal(url.searchParams.get("theme"), "dark");
  assert.equal(url.searchParams.get("lang"), "en");
  assert.equal(url.hash, "#install");
});

test("disabled storage still allows appearance switching", () => {
  const p = page({ dark: true, blocked: true });
  p.ready();
  p.choose("light");
  assert.equal(p.root.dataset.theme, "light");
});

test("unknown appearance values fall back to the system", () => {
  const p = page({ dark: true, stored: "invalid", url: "https://example.com/?theme=invalid" });
  assert.equal(p.root.dataset.themePreference, "system");
  assert.equal(p.root.dataset.theme, "dark");
});
