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

// 2b. Autocorrect, against the Python reference.
let corrBad = 0;
for (const { typed, prev, result } of expected.corrections) {
  const got = engine.correct(typed, prev);
  if (got !== result) { corrBad++; console.log(`CORR ${JSON.stringify(typed)} after ${JSON.stringify(prev)}: js ${got}  py ${result}`); }
}
console.log(`${expected.corrections.length - corrBad}/${expected.corrections.length} corrections match Python`);
console.log("   " + expected.corrections.map(c => `${c.typed}->${c.result || "keep"}`).join("  "));
bad += corrBad;

// 3. Beyond the Python reference: English mixed mode and personal words.
const engSrc = fs.readFileSync(path.join(__dirname, "english.js"), "utf8");
const ENGLISH = JSON.parse(engSrc.slice(engSrc.indexOf("=") + 1).trim().replace(/;$/, ""));
const mixed = new G.Engine(GUJLISH_DATA.words, GUJLISH_DATA.bigrams, ENGLISH);
function check(label, cond) { if (!cond) { bad++; console.log("FAIL " + label); } else console.log("ok   " + label); }
check("mixed: 'kem' shows no English", mixed.suggestDetailed("kem").surfaces.every(s => mixed.suggestDetailed("kem").sources[s] !== "en"));
const meet = mixed.suggestDetailed("meet");
check("mixed: 'meet' -> meeting/meet in English (" + meet.surfaces.join(",") + ")", meet.surfaces.some(s => meet.sources[s] === "en"));
mixed.mode = "gujlish";
check("gujlish only: 'meet' has no English", Object.values(mixed.suggestDetailed("meet").sources).every(v => v !== "en"));
mixed.mode = "mixed";
check("'neelbhai' is not a corpus word", !mixed.bySurface["neelbhai"]);
mixed.learnWord("neelbhai", 3);
const nb = mixed.suggestDetailed("neelbh");
check("personal word appears (" + nb.surfaces.join(",") + ")", nb.sources["neelbhai"] === "me");
mixed.learnBigram("kem", "neelbhai", 5);
check("personal bigram predicts (" + mixed.nextWord("kem").join(",") + ")", mixed.nextWord("kem").indexOf("neelbhai") >= 0);
for (let i = 0; i < 3; i++) mixed.accept("thashe", "kem");
check("accepting thashe after kem puts it first (" + mixed.suggest("th", "kem").join(",") + ")", mixed.suggest("th", "kem")[0] === "thashe");
mixed.forgetPersonal();
check("forget restores (" + mixed.suggest("th", "kem").join(",") + ")", mixed.suggest("th", "kem").join(",") === engine.suggest("th", "kem").join(",") && !mixed.bySurface["neelbhai"]);

// The user's own spec for autocorrect.
let prev = null, fixed = [];
for (const w of ["Avi", "gaye", "ghara"]) { const f = mixed.correct(w, prev); fixed.push(f || w); prev = f || w; }
check("'Avi gaye ghara' -> aavi gaya ghare (" + fixed.join(" ") + ")", fixed.join(" ") === "aavi gaya ghare");
check("mixed: 'meeting' is not corrected", mixed.correct("meeting") === null);
check("mixed: 'gate' (English) is not corrected", mixed.correct("gate") === null);
check("'kem cho' untouched", mixed.correct("kem") === null && mixed.correct("cho", "kem") === null);
mixed.learnWord("bhabhiji", 2);
check("a taught word is never corrected", mixed.correct("bhabhiji") === null);
mixed.forgetPersonal();

// 4. Latency: the thing the phone will feel.
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
