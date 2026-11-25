// OpenWispr Meet Names: posts the roster to the app's loopback listener.
const ENDPOINT = "http://127.0.0.1:47891/meet";

// Confirmed 2026-11-03 on a live Meet call. Semantic selectors are stable; jsname/class ones are fragile.
const SELECTORS = {
  TILE: '[data-participant-id^="spaces/"]:not([role])',
  PEOPLE_ROW: '[role=list][aria-label="Participants"] [role=listitem][data-participant-id]',
  NAME: "span.notranslate",
  SPEAKING: '[jsname="QgSmzd"]',
  SELF_TILE: '[jsname="E2KThb"]',
  LEAVE: 'button[aria-label="Leave call"]',
  LEFT_HEADING: 'h1[jsname="r4nke"]',
};
const SILENT_CLASS = "gjg47c"; // level classes rotate; only the silent class is matched

const meeting = () => (location.href.match(/meet\.google\.com\/(?:meet\/)?([a-z]{3}-[a-z]{4}-[a-z]{3})/) || [])[1] || "";

// Speaking detectors. Each is small and independent so one renamed class cannot zero out detection.
// None of these has been checked against the live Meet DOM since the 2026-11-03 selector pass.
const ACTIVE_TILE = '[data-is-speaking="true"], [data-active-speaker="true"]'; // guess, unverified
const ACTIVITY_WINDOW_MS = 1500;
const seen = new WeakMap(); // leaf element -> { sig, changedAt }

// 1. The known level indicator: present and not carrying the silent class.
const speakingByIndicator = (root) => {
  const el = root.querySelector(SELECTORS.SPEAKING);
  return !!el && el.matches(SELECTORS.SPEAKING) && !el.classList.contains(SILENT_CLASS);
};

// 2. Any empty leaf inside the tile whose class list or inline style changed in the last 1.5 s
//    (the audio-level bars animate). The first sighting of an element never counts.
const speakingByActivity = (root, now = Date.now()) => {
  let active = false;
  for (const el of root.querySelectorAll("div, span")) {
    if (el.children.length || el.textContent.trim()) continue;
    const sig = `${el.getAttribute("class") || ""}|${el.getAttribute("style") || ""}`;
    const prev = seen.get(el);
    if (!prev) { seen.set(el, { sig, changedAt: 0 }); continue; }
    if (prev.sig !== sig) { prev.sig = sig; prev.changedAt = now; }
    if (now - prev.changedAt < ACTIVITY_WINDOW_MS) active = true;
  }
  return active;
};

// 3. The tile itself (or an ancestor) is flagged as the active speaker.
const speakingByActiveTile = (root) => !!root.closest?.(ACTIVE_TILE) || !!root.querySelector?.(ACTIVE_TILE);

const isSpeaking = (root, now = Date.now()) =>
  speakingByIndicator(root) || speakingByActivity(root, now) || speakingByActiveTile(root);

function tileName(tile) {
  const n = tile.querySelector(SELECTORS.NAME)?.textContent.trim();
  if (n) return n;
  const speakEl = tile.querySelector(SELECTORS.SPEAKING);
  let best = "";
  const walker = document.createTreeWalker(tile, NodeFilter.SHOW_TEXT);
  for (let t = walker.nextNode(); t; t = walker.nextNode()) {
    if (speakEl && speakEl.contains(t)) continue;
    const s = t.textContent.trim();
    if (s.length > best.length) best = s;
  }
  return best;
}

// The local user is always sent as "You"; `self: true` marks it explicitly for the app.
const withSelf = (p, self) => (self ? { ...p, self: true } : p);

function collect(now = Date.now()) {
  const out = new Map(); // participant-id -> {name, speaking}
  const rows = document.querySelectorAll(SELECTORS.PEOPLE_ROW);
  if (rows.length) {
    for (const row of rows) {
      const id = row.getAttribute("data-participant-id");
      const self = [...row.querySelectorAll("span")].some((s) => s.textContent.trim() === "(You)");
      const name = self ? "You" : (row.getAttribute("aria-label") || "").trim();
      if (name && !out.has(id)) out.set(id, withSelf({ name, speaking: isSpeaking(row, now) }, self));
    }
  } else {
    const tiles = [...document.querySelectorAll(SELECTORS.TILE)];
    // Live Meet (2026-11-18) puts SELF_TILE's jsname on every tile root, so it only identifies
    // the local user when exactly one tile carries it. Otherwise nobody is flagged as self.
    const selfTrusted = tiles.filter((t) => t.matches(SELECTORS.SELF_TILE)).length === 1 && tiles.length > 1;
    for (const tile of tiles) {
      const id = tile.getAttribute("data-participant-id");
      const self = selfTrusted && tile.matches(SELECTORS.SELF_TILE);
      const name = self ? "You" : tileName(tile);
      if (name && !out.has(id)) out.set(id, withSelf({ name, speaking: isSpeaking(tile, now) }, self));
    }
  }
  return [...out.values()];
}

if (typeof window !== "undefined") {
  globalThis.__owCollect = collect;
  globalThis.__owDetectors = { speakingByIndicator, speakingByActivity, speakingByActiveTile };
}

function post(event, participants = []) {
  fetch(ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ v: 1, event, meeting: meeting(), participants }),
  }).catch(() => {}); // app not running: stay quiet
}

let lastBody = "", lastSent = 0, joined = false, left = false, leaveSince = 0, leaveSeenLong = false, warned = false;

function tick() {
  if (!meeting()) return;
  const hasLeave = !!document.querySelector(SELECTORS.LEAVE);
  const now = Date.now();
  if (hasLeave) {
    if (!leaveSince) leaveSince = now;
    if (now - leaveSince >= 5000) leaveSeenLong = true;
  }
  if (hasLeave && !joined) { joined = true; left = false; leaveSince = leaveSince || now; post("joined"); }
  const leftHeading = /You left the meeting/i.test(document.querySelector(SELECTORS.LEFT_HEADING)?.textContent || "");
  const gone = !hasLeave && leaveSeenLong;
  if (joined && !left && (leftHeading || gone)) {
    left = true; joined = false; leaveSince = 0; leaveSeenLong = false;
    post("left");
    return;
  }
  if (!hasLeave) return;
  const participants = collect();
  console.debug(`[OpenWispr] roster n=${participants.length}`);
  const body = JSON.stringify(participants);
  // Debounce identical payloads, but keep 1/s while someone speaks: the app weighs speaking samples.
  const anySpeaking = participants.some((p) => p.speaking);
  if (body === lastBody && now - lastSent < (anySpeaking ? 900 : 5000)) return;
  lastBody = body; lastSent = now;
  post("roster", participants);
}

setInterval(() => {
  try { tick(); } catch (e) {
    if (!warned) { warned = true; console.warn("[OpenWispr] Meet UI changed, collector failed:", e); }
  }
}, 1000);
