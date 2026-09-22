// Grammar rules, script fallback, and the golden sentences: the whole
// commit pipeline (autocorrect each word with two words of context, then
// apply every grammar fix) against what a fluent writer expects.
//     python build_site.py && node web/test_grammar.js
"use strict";
const fs = require("fs");
const path = require("path");
const G = require("./gujlish.js");
const Grammar = require("./grammar.js");
const Reverse = require("./reverse.js");

function loadVar(file) {
  const src = fs.readFileSync(path.join(__dirname, file), "utf8");
  return JSON.parse(src.slice(src.indexOf("=") + 1).trim().replace(/;$/, ""));
}
const DATA = loadVar("lexicon.js"), ENGLISH = loadVar("english.js");
const engine = new G.Engine(DATA.words, DATA.bigrams, ENGLISH, DATA.trigrams);

let bad = 0;
function check(label, cond) { if (!cond) { bad++; console.log("FAIL " + label); } else console.log("ok   " + label); }

// 1. Rules in isolation.
function fixes(text) { return Grammar.check(text, engine).map(i => i.from + ">" + i.to); }
check("hu ... cho -> chu", fixes("hu ghare gayo cho").join() === "cho>chu");
check("tame ... che -> cho", fixes("tame kem che").join() === "che>cho");
check("ame ... chu -> chie", fixes("ame majama chu").join() === "chu>chie");
check("tu ... cho -> che", fixes("tu su kare cho").join() === "cho>che");
check("e ... che is fine", fixes("e ghare che").length === 0);
check("no subject, no check", fixes("su karo cho").length === 0);
check("hu ane tame ... cho -> chie", fixes("hu ane tame majama cho").join() === "cho>chie");
check("clause boundary: ke", fixes("hu manu chu ke tame saras cho").length === 0);
check("sentence boundary", fixes("hu ghare gayo chu. tame kem cho?").length === 0);
check("capital kept", fixes("Hu ghare Cho").join() === "Cho>Chu");
check("hu ... jashe -> jaish", fixes("hu kale jashe").join() === "jashe>jaish");
check("tame ... jaish -> jasho", fixes("tame kale jaish").join() === "jaish>jasho");
check("ame ... jashe -> jaishu", fixes("ame kale jashe").join() === "jashe>jaishu");
check("te ... jaish -> jashe", fixes("te kale jaish").join() === "jaish>jashe");
check("english -ish words are not verbs", fixes("hu english finish karish").join() === "");
check("ame ... gayo -> gaya", fixes("ame kale gayo").join() === "gayo>gaya");
check("tame ... aavyo -> aavya", fixes("tame kyare aavyo").join() === "aavyo>aavya");
check("hu ... gaya -> gayo / gayi", (() => { const i = Grammar.check("hu kale gaya", engine); return i.length === 1 && i[0].to === "gayo" && i[0].alt === "gayi"; })());
check("e ... gayo is fine", fixes("e kale gayo").length === 0);
check("hu ... hashe -> hoish", fixes("hu ghare hashe").join() === "hashe>hoish");
check("tame ... hashe -> hasho", fixes("tame kale hashe").join() === "hashe>hasho");
check("chhu/chhe variants recognised", fixes("tame majama chhu").join() === "chhu>cho");
check("tyare ends the clause", fixes("hu avyo tyare varsad che").length === 0);
check("jyare ends the clause", fixes("hu nano hato jyare e ahi che").length === 0);
check("athva ends the clause", fixes("hu avu chu athva e ave che").length === 0);
check("badha ... cho -> che", fixes("badha majama cho").join() === "cho>che");
check("tame badha ... cho is fine", fixes("tame badha majama cho").length === 0);
check("ame badha ... che -> chie", fixes("ame badha majama che").join() === "che>chie");
check("ame ... hato -> hata", fixes("ame tya hato").join() === "hato>hata");
check("tame ... hato -> hata", fixes("tame kya hato").join() === "hato>hata");
check("hu ... hata -> hato / hati", (() => { const i = Grammar.check("hu ghare hata", engine); return i.length === 1 && i[0].to === "hato" && i[0].alt === "hati"; })());
check("e ... hato and hu ... hati are fine", fixes("e ghare hato").length === 0 && fixes("hu ghare hati").length === 0);
check("apply keeps offsets", Grammar.fixAll("hu ghare gayo cho ane tame kem che", engine) === "hu ghare gayo chu ane tame kem cho");

// 2. Script fallback for words outside the lexicon.
const rev = [["ghar", "ઘર"], ["kem", "કેમ"], ["chhun", "છું"], ["sambandh", "સંબંધ"], ["pravin", "પ્રવિન"],
             ["neel", "નીલ"], ["aavjo", "આવજો"], ["thayu", "થયુ"], ["kanya", "કન્યા"], ["bhai", "ભાઈ"],
             ["paisa", "પૈસા"], ["dikra", "દિકરા"], ["chokra", "ચોકરા"]];
// Known limit, not tested: a single mid-word "a" is read as the short
// inherent vowel, so "mama" falls back to મમા and "vyavsay" to વ્યવસય.
// Lexicon words carry the real script form, so this only touches
// unknown words.
let revBad = 0;
for (const [w, want] of rev) { const got = Reverse.toGujarati(w); if (got !== want) { revBad++; console.log(`  reverse ${w}: got ${got}, want ${want}`); } }
check(`reverse transliteration (${rev.length - revBad}/${rev.length})`, revBad === 0);

// 3. Golden sentences: full commit pipeline.
function pipeline(text) {
  const parts = text.split(/(\s+)/);
  let prev = null, prev2 = null;
  const out = parts.map(p => {
    if (!p.trim()) return p;
    const clean = G.cleanSurface(p);
    if (!clean) return p;
    const fix = engine.correct(p, prev, prev2);
    const word = fix ? (/^[A-Z]/.test(p) ? fix[0].toUpperCase() + fix.slice(1) : fix) + p.replace(/^[A-Za-z]+/, "") : p;
    prev2 = prev; prev = fix || clean;
    return word;
  }).join("");
  return Grammar.fixAll(out, engine);
}
const golden = fs.readFileSync(path.join(__dirname, "golden.tsv"), "utf8").split(/\r?\n/)
  .filter(l => l.trim() && !l.startsWith("#")).map(l => l.split("\t"));
let goldBad = 0;
for (const [input, want] of golden) {
  const got = pipeline(input);
  if (got !== want) { goldBad++; console.log(`  GOLD ${JSON.stringify(input)} -> ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); }
}
check(`golden sentences (${golden.length - goldBad}/${golden.length})`, goldBad === 0);

process.exit(bad ? 1 : 0);
