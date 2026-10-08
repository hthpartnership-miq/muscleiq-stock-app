// Storage layer for the hosted (Vercel) build of MuscleIQ Rack Stock.
// The page was written against Claude's artifact runtime (window.claude.use("db"), ...).
// This file provides the same calls on top of /api/db, so the page code itself is unchanged.
(function () {
  "use strict";
  const API = "/api/db", POLL_MS = 4000, PASS_KEY = "miq-pass";
  const store = {
    get() { try { return localStorage.getItem(PASS_KEY) || ""; } catch (_) { return ""; } },
    set(v) { try { localStorage.setItem(PASS_KEY, v); } catch (_) {} }
  };
  let pass = store.get(), state = null, ver = null, started = false, blocked = false;
  const listeners = new Set();
  const err = (code, message) => ({ code, message: message || code });
  const clone = v => JSON.parse(JSON.stringify(v));

  /* ---------- overlay: passcode prompt and setup notice ---------- */
  let asking = null;
  function overlay() {
    let o = document.getElementById("miq-gate");
    if (o) return o;
    o = document.createElement("div"); o.id = "miq-gate";
    o.style.cssText = "position:fixed;inset:0;z-index:20;background:var(--bg);display:flex;align-items:center;justify-content:center;padding:16px";
    document.body.appendChild(o);
    return o;
  }
  function askPass(wrong) {
    if (asking) return asking;
    asking = new Promise(resolve => {
      const o = overlay();
      o.innerHTML = '<form style="background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:20px;width:min(380px,100%);display:flex;flex-direction:column;gap:12px">' +
        '<p class="eyebrow">MuscleIQ warehouse</p><h2 style="font-size:28px;font-weight:700;line-height:1.05">Rack stock</h2>' +
        '<label style="display:flex;flex-direction:column;gap:4px;font-size:13px;font-weight:600;color:var(--muted)">Passcode<input class="field" id="miq-pass" type="password" autocomplete="current-password" required></label>' +
        '<p class="msg" id="miq-pass-msg"' + (wrong ? "" : " hidden") + '>Wrong passcode. Try again.</p>' +
        '<button class="btn in" type="submit">Open stock</button></form>';
      o.querySelector("form").addEventListener("submit", e => {
        e.preventDefault();
        const v = o.querySelector("#miq-pass").value.trim();
        if (!v) return;
        pass = v; store.set(v); o.remove(); asking = null; resolve();
      });
    });
    return asking;
  }
  function setupNotice(message) {
    blocked = true;
    const o = overlay();
    o.innerHTML = '<div class="notice warn" style="max-width:460px"><b>Stock storage is not set up yet.</b><br>' +
      'This site needs Supabase connected and an APP_PASSCODE in its Vercel settings. The steps are in README.md.</div>';
    if (message) console.warn(message);
  }

  /* ---------- transport ---------- */
  async function call(method, body, qs) {
    for (let tries = 0; ; tries++) {
      let r;
      try {
        r = await fetch(API + (qs || ""), {
          method, cache: "no-store",
          headers: { "content-type": "application/json", "x-passcode": pass },
          body: body ? JSON.stringify(body) : undefined
        });
      } catch (_) { throw err("unavailable", "No connection."); }
      if (r.status === 401) { await askPass(tries > 0 || !!pass); continue; }
      let j = null; try { j = await r.json(); } catch (_) {}
      if (r.status === 503 && j && j.code === "not_configured") { setupNotice(j.message); throw err("not_configured", j.message); }
      if (r.status === 404) { setupNotice("The /api/db function was not found."); throw err("not_configured"); }
      if (!r.ok) throw err((j && j.code) || (r.status >= 500 ? "unavailable" : "invalid_argument"), j && j.message);
      return j || {};
    }
  }

  /* ---------- sync: one request at a time, newest state wins ---------- */
  let chain = Promise.resolve();
  function sync() {
    const run = chain.then(async () => {
      const j = await call("GET", null, ver != null ? "?v=" + encodeURIComponent(ver) : "");
      if (!j.same) { state = j.data || {}; ver = j.ver; }
      notify();
    });
    chain = run.catch(() => {});
    return run;
  }
  function start() {
    if (started) return; started = true;
    const tick = () => { if (!blocked && document.visibilityState === "visible") sync().catch(() => {}); };
    setInterval(tick, POLL_MS);
    document.addEventListener("visibilitychange", tick);
    window.addEventListener("online", tick);
    sync().catch(() => {});
  }

  /* ---------- snapshots ---------- */
  const docSnap = (id, body) => ({ id, exists: !!body, data: () => (body ? clone(body) : undefined), metadata: { fromCache: false, hasPendingWrites: false } });
  const cmp = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
  const OPS = {
    "==": (a, b) => a === b, "!=": (a, b) => a !== b, "<": (a, b) => a < b, "<=": (a, b) => a <= b, ">": (a, b) => a > b, ">=": (a, b) => a >= b,
    "in": (a, b) => Array.isArray(b) && b.includes(a), "not-in": (a, b) => Array.isArray(b) && !b.includes(a),
    "array-contains": (a, b) => Array.isArray(a) && a.includes(b)
  };
  function runQuery(q) {
    const all = (state && state[q.col]) || {};
    let rows = Object.keys(all).sort().map(id => [id, all[id]]);
    for (const [f, op, v] of q.filters) rows = rows.filter(([, b]) => b[f] !== undefined && OPS[op] && OPS[op](b[f], v));
    if (q.order) {
      const [f, dir] = q.order;
      rows.sort((x, y) => {
        const a = x[1][f], b = y[1][f];
        if (a === undefined || b === undefined) return a === b ? cmp(x[0], y[0]) : a === undefined ? 1 : -1;
        return (dir === "desc" ? -1 : 1) * cmp(a, b) || cmp(x[0], y[0]);
      });
    }
    if (q.max) rows = rows.slice(0, q.max);
    const docs = rows.map(([id, b]) => docSnap(id, b));
    return { docs, size: docs.length, empty: !docs.length, docChanges: () => [], metadata: { fromCache: false, hasPendingWrites: false } };
  }
  function notify() {
    if (!state) return;
    for (const l of [...listeners]) {
      const snap = l.read(), sig = l.sign(snap);
      if (sig === l.last) continue;
      l.last = sig;
      try { l.next(snap); } catch (e) { console.error(e); }
    }
  }
  function listen(read, sign, next) {
    const l = { read, sign, next, last: null };
    listeners.add(l); start();
    if (state) Promise.resolve().then(notify);
    return () => listeners.delete(l);
  }

  /* ---------- refs ---------- */
  function split(path, even) {
    const p = String(path).split("/");
    if (p.length % 2 !== (even ? 0 : 1) || p.some(s => !/^[A-Za-z0-9_\-.~:@+]{1,200}$/.test(s))) throw new TypeError("Bad path: " + path);
    return p;
  }
  const newId = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
  function docRef(col, id) {
    const write = async body => { await call("POST", body); await sync().catch(() => {}); };
    return {
      id, path: col + "/" + id,
      async get() { await sync(); return docSnap(id, (state[col] || {})[id]); },
      set(data) { return write({ op: "set", col, id, data }); },
      update(data) { return write({ op: "update", col, id, data }); },
      delete() { return write({ op: "delete", col, id }); },
      acquire(o) { return call("POST", { op: "acquire", col, id, holder: o && o.holder, ttlMs: o && o.ttlMs }); },
      onSnapshot(next) { return listen(() => docSnap(id, ((state && state[col]) || {})[id]), s => JSON.stringify(s.data() || null), next); },
      collection() { throw new TypeError("Nested collections are not supported in this build."); }
    };
  }
  function query(q) {
    return {
      path: q.col,
      where(f, op, v) { return query(Object.assign({}, q, { filters: q.filters.concat([[f, op, v]]) })); },
      orderBy(f, dir) { return query(Object.assign({}, q, { order: [f, dir === "desc" ? "desc" : "asc"] })); },
      limit(n) { return query(Object.assign({}, q, { max: n })); },
      async get() { await sync(); return runQuery(q); },
      onSnapshot(next) { return listen(() => runQuery(q), s => JSON.stringify(s.docs.map(d => [d.id, d.data()])), next); },
      doc(id) { return docRef(q.col, id || newId()); },
      async add(data) { const r = docRef(q.col, newId()); await r.set(data); return r; }
    };
  }
  const db = {
    doc(path) { const p = split(path, true); if (p.length !== 2) throw new TypeError("Bad path: " + path); return docRef(p[0], p[1]); },
    collection(path) { const p = split(path, false); if (p.length !== 1) throw new TypeError("Bad path: " + path); return query({ col: p[0], filters: [], order: null, max: 0 }); }
  };

  /* ---------- file saving (CSV, QR label sheets) ---------- */
  const downloads = {
    async save({ filename, data }) {
      const blob = data instanceof Blob ? data : new Blob([data], { type: /\.html?$/i.test(filename) ? "text/html" : /\.csv$/i.test(filename) ? "text/csv" : "application/octet-stream" });
      const a = document.createElement("a"), url = URL.createObjectURL(blob);
      a.href = url; a.download = filename; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 10000);
    }
  };

  /* ---------- Shopify stock items: staff movements ---------- */
  window.miqItems = {
    async move(code, kind, qty, note) { const r = await call("POST", { op: "item-move", col: "items", id: code, kind, qty, note }); await sync().catch(() => {}); return r; },
    async setType(code, type) { const r = await call("POST", { op: "item-type", col: "items", id: code, type }); await sync().catch(() => {}); return r; },
    async history(code) { const r = await call("POST", { op: "item-history", col: "items", id: code }); return r.rows || []; }
  };

  const caps = { db, downloads };
  window.claude = { use: name => Promise.resolve(caps[name] || null) };
})();
