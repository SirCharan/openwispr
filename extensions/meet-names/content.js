// OpenWispr Meet Names: posts the roster to the app's loopback listener.
const ENDPOINT = "http://127.0.0.1:47891/meet";

// PLACEHOLDERS: another worker fills these from the live Meet DOM.
const SELECTORS = {
  NAME: "",       // participant name element, relative to a TILE or PEOPLE_ROW
  TILE: "",       // video tile container
  PEOPLE_ROW: "", // row in the People panel
  SPEAKING: "",   // present inside a tile/row while that person speaks
};

const meeting = () => (location.pathname.match(/^\/([a-z]{3}-[a-z]{4}-[a-z]{3})/) || [])[1] || "";

function collect() {
  const out = new Map();
  if (!SELECTORS.NAME) return [];
  for (const root of document.querySelectorAll([SELECTORS.TILE, SELECTORS.PEOPLE_ROW].filter(Boolean).join(","))) {
    const name = root.querySelector(SELECTORS.NAME)?.textContent.trim();
    if (!name) continue;
    const speaking = !!SELECTORS.SPEAKING && !!root.querySelector(SELECTORS.SPEAKING);
    out.set(name, (out.get(name) || false) || speaking);
  }
  return [...out].map(([name, speaking]) => ({ name, speaking }));
}

function post(event, participants = []) {
  fetch(ENDPOINT, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ v: 1, event, meeting: meeting(), participants }),
  }).catch(() => {}); // app not running: stay quiet
}

let lastBody = "", lastSent = 0, joined = false, left = false;

setInterval(() => {
  const inCall = !!meeting() && !!document.querySelector('[aria-label="Leave call"], [data-call-ended="false"]');
  const ended = !!meeting() && !inCall && joined;
  if (inCall && !joined) { joined = true; left = false; post("joined"); }
  if (ended && !left) { left = true; joined = false; post("left"); }
  if (!inCall) return;
  const participants = collect();
  const body = JSON.stringify(participants);
  const now = Date.now();
  if (body === lastBody && now - lastSent < 5000) return; // debounce identical payloads
  lastBody = body; lastSent = now;
  post("roster", participants);
}, 1000);
