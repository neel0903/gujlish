// JS port vs the Python reference. Run after build_tester.py:
//     node web/test_port.js
"use strict";
const fs = require("fs");
const path = require("path");
const G = require("./gujlish.js");

const expected = JSON.parse(fs.readFileSync(path.join(__dirname, "expected.json"), "utf8"));
const src = fs.readFileSync(path.join(__dirname, "lexicon.js"), "utf8");
const GUJLISH_DATA = JSON.parse(src.slice(src.indexOf("=") + 1).trim().replace(/;$/, ""));

let bad = 0;

// 1. Phonetic keys: every lexicon word, prefix and whole-word mode.
let keyBad = 0;
for (const [s, skP, lkP, skW, lkW] of expected.keys.concat(expected.probeKeys)) {
  const got = [G.strictKey(s, true), G.looseKey(s, true), G.strictKey(s), G.looseKey(s)];
  const want = [skP, lkP, skW, lkW];
  if (got.join("|") !== want.join("|")) {
    keyBad++;
    if (keyBad <= 10) console.log(`KEY ${JSON.stringify(s)}: js ${got.join("|")}  py ${want.join("|")}`);
  }
}
const nKeys = expected.keys.length + expected.probeKeys.length;
console.log(`${nKeys - keyBad}/${nKeys} words key identically`);
bad += keyBad;

// 2. Engine trials.
const t0 = Date.now();
const engine = new G.Engine(GUJLISH_DATA.words, GUJLISH_DATA.bigrams);
console.log(`engine built in ${Date.now() - t0} ms`);
let trialBad = 0;
for (const { typed, prev, result } of expected.trials) {
  const got = typed ? engine.suggest(typed, prev) : engine.nextWord(prev);
  const same = got.join(",") === result.join(",");
  const sameSet = [...got].sort().join(",") === [...result].sort().join(",");
  if (!same) {
    trialBad += sameSet ? 0 : 1;
    const label = (prev ? `[${prev}] ` : "") + JSON.stringify(typed);
    console.log(`${sameSet ? "order" : "DIFF "} ${label.padEnd(18)} js: ${got.join(", ")}   py: ${result.join(", ")}`);
  }
}
console.log(`${expected.trials.length - trialBad}/${expected.trials.length} trials give the same candidates`);
bad += trialBad;

// 3. Latency: the thing the phone will feel.
const probes = ["c", "ch", "che", "tha", "thay", "kem", "majam", "mjama", "sarkar", "gujar", "k", "a"];
let worst = 0;
for (let rep = 0; rep < 3; rep++) {
  for (const p of probes) {
    const t = process.hrtime.bigint();
    engine.suggest(p, "tame");
    const ms = Number(process.hrtime.bigint() - t) / 1e6;
    if (ms > worst) worst = ms;
  }
}
console.log(`worst suggest latency ${worst.toFixed(1)} ms`);

process.exit(bad ? 1 : 0);
