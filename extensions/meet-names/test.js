// Run: node test.js (needs jsdom installed). Loads test.html, evals content.js, asserts collect().
const { JSDOM } = require("jsdom");
const fs = require("fs");
const assert = require("assert");
const dom = new JSDOM(fs.readFileSync(__dirname + "/test.html", "utf8"), { url: "https://meet.google.com/abc-defg-hij", runScripts: "outside-only" });
dom.window.fetch = () => Promise.resolve();
dom.window.eval(fs.readFileSync(__dirname + "/content.js", "utf8"));
const got = JSON.parse(JSON.stringify(dom.window.__owCollect()));
assert.deepStrictEqual(got, [{ name: "You", speaking: false }, { name: "Asha Rao", speaking: true }]);
console.log("PASS", JSON.stringify(got));
dom.window.close();
