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

const isSpeaking = (root) => {
  const el = root.querySelector(SELECTORS.SPEAKING);
  return !!el && el.matches(SELECTORS.SPEAKING) && !el.classList.contains(SILENT_CLASS);
};

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

function collect() {
  const out = new Map(); // participant-id -> {name, speaking}
  const rows = document.querySelectorAll(SELECTORS.PEOPLE_ROW);
  if (rows.length) {
    for (const row of rows) {
      const id = row.getAttribute("data-participant-id");
      const self = [...row.querySelectorAll("span")].some((s) => s.textContent.trim() === "(You)");
      const name = self ? "You" : (row.getAttribute("aria-label") || "").trim();
      if (name && !out.has(id)) out.set(id, { name, speaking: isSpeaking(row) });
    }
  } else {
    for (const tile of document.querySelectorAll(SELECTORS.TILE)) {
      const id = tile.getAttribute("data-participant-id");
      const name = tile.matches(SELECTORS.SELF_TILE) ? "You" : tileName(tile);
      if (name && !out.has(id)) out.set(id, { name, speaking: isSpeaking(tile) });
    }
  }
  return [...out.values()];
}

if (typeof window !== "undefined") globalThis.__owCollect = collect;

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
  if (body === lastBody && now - lastSent < 5000) return; // debounce identical payloads
  lastBody = body; lastSent = now;
  post("roster", participants);
}

setInterval(() => {
  try { tick(); } catch (e) {
    if (!warned) { warned = true; console.warn("[OpenWispr] Meet UI changed, collector failed:", e); }
  }
}, 1000);
