// The Answering Diary — frontend.
//
// Security posture: the only credential here is the public Firebase config. Every backend call
// carries a Firebase ID token plus an App Check attestation, and the diary's replies are rendered
// with textContent — never innerHTML — so nothing written on the page can execute.
import { initializeApp } from "https://www.gstatic.com/firebasejs/10.13.2/firebase-app.js";
import {
  getAuth, GoogleAuthProvider, signInWithPopup, signOut, onAuthStateChanged, getIdToken,
} from "https://www.gstatic.com/firebasejs/10.13.2/firebase-auth.js";
import {
  initializeAppCheck, ReCaptchaEnterpriseProvider, getToken as getAppCheckToken,
} from "https://www.gstatic.com/firebasejs/10.13.2/firebase-app-check.js";

const CFG = window.APP_CONFIG;
const app = initializeApp(CFG.firebase);
const auth = getAuth(app);
const provider = new GoogleAuthProvider();

// ---------- App Check ----------
// Auth proves whose hand is writing. App Check proves the hand is holding OUR diary.
let appCheck = null;
const siteKey = CFG.appCheckSiteKey;
if (siteKey && !siteKey.startsWith("YOUR_")) {
  if (CFG.appCheckDebug) self.FIREBASE_APPCHECK_DEBUG_TOKEN = true; // dev only
  try {
    appCheck = initializeAppCheck(app, {
      provider: new ReCaptchaEnterpriseProvider(siteKey),
      isTokenAutoRefreshEnabled: true,
    });
  } catch (e) {
    console.warn("App Check init failed; continuing unattested.", e?.code);
  }
}

// ---------- State ----------
let currentUser = null;
let page = []; // this session's exchange: [{ role:'user'|'model', text }]

const $ = (id) => document.getElementById(id);
const messagesEl = $("messages");
const inputEl = $("input");

// ---------- Auth ----------
$("googleBtn").onclick = () =>
  signInWithPopup(auth, provider).catch((e) => toast("The clasp held fast. " + friendly(e.code)));
$("signOutBtn").onclick = () => signOut(auth);

onAuthStateChanged(auth, (user) => {
  currentUser = user;
  if (user) {
    $("authScreen").classList.add("hidden");
    $("appScreen").classList.remove("hidden");
    $("userName").textContent = user.displayName || user.email || "you";
    if (user.photoURL) $("avatar").src = user.photoURL;
    else $("avatar").classList.add("hidden");
    $("dateStamp").textContent = new Date().toLocaleDateString(undefined, {
      weekday: "long", day: "numeric", month: "long",
    });
    openDiary();
  } else {
    $("appScreen").classList.add("hidden");
    $("authScreen").classList.remove("hidden");
    page = [];
    messagesEl.replaceChildren();
  }
});

// ---------- API ----------
async function callApi(action, payload = {}) {
  const token = await getIdToken(currentUser, false);
  const headers = { "Content-Type": "application/json", Authorization: `Bearer ${token}` };

  // Raw fetch doesn't attach App Check automatically (unlike the Firestore/Callable SDKs),
  // so we fetch the attestation token and send it ourselves.
  if (appCheck) {
    try {
      const { token: acToken } = await getAppCheckToken(appCheck, false);
      if (acToken) headers["X-Firebase-AppCheck"] = acToken;
    } catch (e) {
      console.warn("App Check token unavailable", e?.code);
    }
  }

  const res = await fetch(CFG.apiBase, {
    method: "POST",
    headers,
    body: JSON.stringify({ action, dayKey: localDayKey(), ...payload }),
  });
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.error || `http_${res.status}`);
  }
  return res.json();
}

// ---------- Writing on the page ----------
function writeLine(who, text, hand) {
  const line = document.createElement("div");
  line.className = "entry-line";

  const label = document.createElement("span");
  label.className = "entry-who";
  label.textContent = who;

  const body = document.createElement("div");
  body.className = hand;
  body.textContent = text; // untrusted model text -> textContent, always

  line.append(label, body);
  messagesEl.appendChild(line);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return body;
}

function showWaiting() {
  const line = document.createElement("div");
  line.className = "entry-line";
  const label = document.createElement("span");
  label.className = "entry-who";
  label.textContent = "The diary";
  const dots = document.createElement("div");
  dots.className = "waiting";
  ["the ", "ink ", "rises…"].forEach((w) => {
    const s = document.createElement("span");
    s.textContent = w;
    dots.appendChild(s);
  });
  line.append(label, dots);
  messagesEl.appendChild(line);
  messagesEl.scrollTop = messagesEl.scrollHeight;
  return line;
}

// The diary's reply seeps up through the page rather than appearing at once.
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
function riseInk(el, text) {
  if (reduceMotion) { el.textContent = text; return Promise.resolve(); }
  return new Promise((resolve) => {
    el.classList.add("rising");
    let i = 0;
    const step = Math.max(1, Math.round(text.length / 260)); // ~4s ceiling for long replies
    const timer = setInterval(() => {
      i = Math.min(text.length, i + step);
      el.textContent = text.slice(0, i);
      messagesEl.scrollTop = messagesEl.scrollHeight;
      if (i >= text.length) {
        clearInterval(timer);
        el.classList.remove("rising");
        resolve();
      }
    }, 16);
  });
}

async function inscribe() {
  const text = inputEl.value.trim();
  if (!text || !currentUser) return;

  // The words sink into the page before they reappear in your hand.
  if (!reduceMotion) {
    inputEl.classList.add("absorbing");
    await new Promise((r) => setTimeout(r, 260));
    inputEl.classList.remove("absorbing");
  }
  inputEl.value = "";
  inputEl.style.height = "auto";
  $("sendBtn").disabled = true;

  writeLine("You", text, "hand-writer");
  page.push({ role: "user", text });

  const waiting = showWaiting();
  try {
    const { reply } = await callApi("inscribe", { history: page.slice(0, -1), message: text });
    waiting.remove();
    const el = writeLine("The diary", "", "hand-diary");
    await riseInk(el, reply);
    page.push({ role: "model", text: reply });
  } catch (e) {
    waiting.remove();
    writeLine("The diary", "The page stays blank. " + friendly(e.message), "hand-diary");
  } finally {
    $("sendBtn").disabled = false;
    inputEl.focus();
  }
}

$("sendBtn").onclick = inscribe;
inputEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); inscribe(); }
});
inputEl.addEventListener("input", () => {
  inputEl.style.height = "auto";
  inputEl.style.height = Math.min(inputEl.scrollHeight, 150) + "px";
});

$("freshBtn").onclick = () => {
  page = [];
  messagesEl.replaceChildren();
  loadWhisper();
  inputEl.focus();
};

// ---------- Sealing a memory ----------
$("sealBtn").onclick = async () => {
  if (page.length === 0) return toast("There is nothing on the page to seal.");
  const btn = $("sealBtn");
  btn.disabled = true;
  btn.textContent = "Pressing the wax…";
  try {
    const { memory, vigil } = await callApi("seal", { history: page });
    toast(`Sealed — “${memory.title}”`);
    setVigil(vigil);
    page = [];
    messagesEl.replaceChildren();
    await Promise.all([loadMemories(), loadWhisper()]);
  } catch (e) {
    toast("The wax would not take. " + friendly(e.message));
  } finally {
    btn.disabled = false;
    btn.textContent = "Seal this memory";
  }
};

// ---------- The whispered prompt ----------
async function loadWhisper() {
  try {
    const { prompt } = await callApi("whisper");
    const slot = $("whisperSlot");
    slot.replaceChildren();
    const btn = document.createElement("button");
    btn.className = "whisper";
    btn.textContent = prompt;
    btn.onclick = () => {
      inputEl.value = prompt;
      inputEl.dispatchEvent(new Event("input"));
      inputEl.focus();
    };
    slot.appendChild(btn);
  } catch { /* a quiet diary is not an error */ }
}

// ---------- The vault ----------
async function loadMemories() {
  const { memories, vigil } = await callApi("recall");
  setVigil(vigil);
  const box = $("memories");
  box.replaceChildren();
  if (!memories.length) {
    box.appendChild(hush("Nothing sealed yet. Write a page, then seal it."));
    return;
  }
  memories.forEach((m) => box.appendChild(renderMemory(m)));
}

function renderMemory(m) {
  const card = document.createElement("div");
  card.className = "memory";

  const title = document.createElement("div");
  title.className = "memory-title";
  title.textContent = m.title;

  const sum = document.createElement("div");
  sum.className = "memory-sum";
  sum.textContent = m.summary;

  const meta = document.createElement("div");
  meta.className = "memory-meta";

  const wax = document.createElement("span");
  wax.className = "wax";
  wax.style.background = inkColour(m.humourScore);
  wax.title = `${m.humour} · ${m.humourScore}/10`;

  const stamp = document.createElement("span");
  stamp.className = "stamp";
  stamp.textContent = [m.humour, fmtDate(m.createdAt)].filter(Boolean).join(" · ");

  meta.append(wax, stamp);
  (m.threads || []).forEach((t) => {
    const th = document.createElement("span");
    th.className = "thread";
    th.textContent = t;
    meta.appendChild(th);
  });

  card.append(title, sum, meta);

  if ((m.resolutions || []).length) {
    const r = document.createElement("div");
    r.className = "resolutions";
    r.textContent = m.resolutions.join(" · ");
    card.appendChild(r);
  }
  return card;
}

// ---------- Humours ----------
async function loadHumours() {
  const { series } = await callApi("humours");
  const box = $("humourChart");
  box.replaceChildren();
  if (!series.length) {
    box.appendChild(hush("Seal a few memories and the ink will show its colour."));
    $("humourLegend").textContent = "";
    return;
  }
  box.appendChild(humourChart(series));
  const avg = (series.reduce((a, b) => a + b.humourScore, 0) / series.length).toFixed(1);
  $("humourLegend").textContent = `${series.length} memories · the ink runs ${avg} of 10`;
}

function humourChart(series) {
  const W = 300, H = 128, pad = 24;
  const NS = "http://www.w3.org/2000/svg";
  const svg = document.createElementNS(NS, "svg");
  svg.setAttribute("viewBox", `0 0 ${W} ${H}`);
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", "Your emotional trend across recent memories");

  const xs = series.map((_, i) => pad + (i * (W - 2 * pad)) / Math.max(1, series.length - 1));
  const ys = series.map((d) => H - pad - ((d.humourScore - 1) / 9) * (H - 2 * pad));

  [1, 5, 10].forEach((v) => {
    const y = H - pad - ((v - 1) / 9) * (H - 2 * pad);
    const line = document.createElementNS(NS, "line");
    line.setAttribute("x1", pad); line.setAttribute("x2", W - pad);
    line.setAttribute("y1", y); line.setAttribute("y2", y);
    line.setAttribute("stroke", "currentColor");
    line.setAttribute("stroke-opacity", ".16");
    line.setAttribute("stroke-dasharray", "2 4");
    svg.appendChild(line);
    const t = document.createElementNS(NS, "text");
    t.setAttribute("x", 2); t.setAttribute("y", y + 3);
    t.textContent = v;
    svg.appendChild(t);
  });

  const path = document.createElementNS(NS, "path");
  let d = "";
  xs.forEach((x, i) => (d += (i ? "L" : "M") + x.toFixed(1) + " " + ys[i].toFixed(1) + " "));
  path.setAttribute("d", d);
  path.setAttribute("fill", "none");
  path.setAttribute("stroke", "currentColor");
  path.setAttribute("stroke-opacity", ".5");
  path.setAttribute("stroke-width", "1.4");
  svg.appendChild(path);

  series.forEach((pt, i) => {
    const c = document.createElementNS(NS, "circle");
    c.setAttribute("cx", xs[i]); c.setAttribute("cy", ys[i]); c.setAttribute("r", 3.6);
    c.setAttribute("fill", inkColour(pt.humourScore));
    const title = document.createElementNS(NS, "title");
    title.textContent = `${pt.humour} · ${pt.humourScore}/10`;
    c.appendChild(title);
    svg.appendChild(c);
  });
  return svg;
}

// ---------- Divination ----------
$("divineBtn").onclick = divine;
$("divineInput").addEventListener("keydown", (e) => { if (e.key === "Enter") divine(); });

async function divine() {
  const q = $("divineInput").value.trim();
  if (!q) return;
  const box = $("divineResults");
  box.replaceChildren(hush("Turning back the pages…"));
  try {
    const { results } = await callApi("divine", { query: q });
    box.replaceChildren();
    if (!results.length) {
      box.appendChild(hush("The diary recalls nothing like that yet."));
      return;
    }
    results.forEach((r) => {
      const card = renderMemory({ ...r, threads: [] });
      const rel = document.createElement("div");
      rel.className = "relevance";
      rel.textContent = `${(r.score * 100).toFixed(0)}% kinship`;
      card.appendChild(rel);
      box.appendChild(card);
    });
  } catch (e) {
    box.replaceChildren(hush("The pages would not turn. " + friendly(e.message)));
  }
}

// ---------- Owl Post ----------
$("owlBtn").onclick = async () => {
  const out = $("owlOut");
  out.replaceChildren(hush("The owl is on the wing…"));
  try {
    const { post } = await callApi("owlpost");
    if (!post) {
      out.replaceChildren(hush("Seal a few memories this week and the owl will have something to carry."));
      return;
    }
    const box = document.createElement("div");
    box.className = "owl";
    const text = document.createElement("div");
    text.className = "owl-text";
    text.textContent = post.reflection;
    box.appendChild(text);
    (post.prompts || []).forEach((p) => {
      const el = document.createElement("div");
      el.className = "owl-prompt";
      el.textContent = p;
      box.appendChild(el);
    });
    out.replaceChildren(box);
  } catch (e) {
    out.replaceChildren(hush("The owl turned back. " + friendly(e.message)));
  }
};

// ---------- Tabs ----------
const TABS = ["memories", "humours", "divine", "owlpost"];
document.querySelectorAll(".tab").forEach((tab) => {
  tab.onclick = () => {
    document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
    tab.classList.add("active");
    TABS.forEach((name) => $("tab-" + name).classList.toggle("hidden", name !== tab.dataset.tab));
    if (tab.dataset.tab === "humours") loadHumours();
  };
});

// ---------- Open ----------
async function openDiary() {
  await Promise.all([loadMemories().catch(() => {}), loadWhisper()]);
}

// ---------- Utils ----------
function setVigil(n) {
  $("vigilCount").textContent = n;
  $("vigilWord").textContent = n === 1 ? "night" : "nights";
}

function localDayKey() {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
}

// Wax colour by humour: gold when bright, indigo when low.
function inkColour(score) {
  if (score >= 8) return "#B8912F"; // gilt
  if (score >= 6) return "#5E7A55"; // moss
  if (score >= 4) return "#6B5B8A"; // violet
  return "#7A3B36";                 // oxblood
}

function fmtDate(ms) {
  return ms ? new Date(ms).toLocaleDateString(undefined, { day: "numeric", month: "short" }) : "";
}

function hush(text) {
  const p = document.createElement("p");
  p.className = "hush";
  p.textContent = text;
  return p;
}

function friendly(code) {
  return ({
    unauthenticated: "Sign in once more.",
    rate_limited: "You are writing faster than the ink can dry.",
    internal_error: "Something went wrong behind the page.",
    empty_message: "Write something first.",
    empty_inscription: "There is nothing on the page yet.",
    failed_app_check: "This diary could not be verified. Reload and try again.",
    origin_not_allowed: "This page is not permitted to open the diary.",
    payload_too_large: "That is more than one page can hold.",
    "auth/popup-closed-by-user": "The clasp stayed shut.",
  }[code]) || code;
}

let toastTimer;
function toast(msg) {
  const el = $("toast");
  el.textContent = msg;
  el.classList.remove("hidden");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add("hidden"), 3400);
}
