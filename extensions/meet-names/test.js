// Run: node test.js (needs jsdom installed). Loads test.html, evals content.js, asserts collect() and each detector.
const { JSDOM } = require("jsdom");
const fs = require("fs");
const assert = require("assert");
const dom = new JSDOM(fs.readFileSync(__dirname + "/test.html", "utf8"), { url: "https://meet.google.com/abc-defg-hij", runScripts: "outside-only" });
dom.window.fetch = () => Promise.resolve();
dom.window.eval(fs.readFileSync(__dirname + "/content.js", "utf8"));
const doc = dom.window.document;
const { speakingByIndicator, speakingByActivity, speakingByActiveTile } = dom.window.__owDetectors;
const collect = (now) => JSON.parse(JSON.stringify(dom.window.__owCollect(now)));
const tile = (n) => doc.querySelector(`[data-participant-id="spaces/x/devices/${n}"]:not([role])`);

// Detectors one by one (activity: first sighting never counts, a later change inside 1.5 s does).
assert.strictEqual(speakingByIndicator(tile(2)), true);
assert.strictEqual(speakingByIndicator(tile(1)), false, "silent class");
assert.strictEqual(speakingByIndicator(tile(3)), false, "no jsname indicator");
assert.strictEqual(speakingByActiveTile(tile(4)), true);
assert.strictEqual(speakingByActiveTile(tile(3)), false);
assert.strictEqual(speakingByActivity(tile(3), 1000), false, "first sighting");
doc.getElementById("bars").setAttribute("style", "height:9px");
assert.strictEqual(speakingByActivity(tile(3), 2000), true, "style changed");
assert.strictEqual(speakingByActivity(tile(3), 4000), false, "settled after 1.5 s");
doc.getElementById("bars").className = "b";
assert.strictEqual(speakingByActivity(tile(3), 5000), true, "class changed");
assert.strictEqual(speakingByActivity(tile(5), 5000) || speakingByActivity(tile(5), 5100), false, "static leaf");

// collect(): self flag on the local tile only; combined detectors.
const got = collect(9000);
assert.deepStrictEqual(got, [
  { name: "You", speaking: false, self: true },
  { name: "Asha Rao", speaking: true },
  { name: "Ben Cho", speaking: false },
  { name: "Dia Rao", speaking: true },
  { name: "Eli Roy", speaking: false },
]);
doc.getElementById("bars").setAttribute("style", "height:3px");
assert.strictEqual(collect(9100).find((p) => p.name === "Ben Cho").speaking, true, "collect uses activity detector");
console.log("PASS", JSON.stringify(got));
dom.window.close();
