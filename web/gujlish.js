/*
 * Gujlish phonetics + suggestion engine, JavaScript port.
 *
 * Line-for-line with phonetics.py and engine.py. The Python is the
 * reference; test_port.js checks this against it (every key in the
 * lexicon, every trial in the harness). When you port to Swift, port
 * from the Python and test the same way.
 *
 * The only structural difference: engine.py reads SQLite, this holds
 * the lexicon in memory sorted by frequency, so "ORDER BY freq DESC
 * LIMIT n" becomes "scan in order, stop at n".
 */
(function (root) {
  "use strict";

  // ---------- phonetics ----------

  var DIGRAPHS = [
    ["chh", "C"], ["ch", "C"], ["shh", "s"], ["sh", "s"],
    ["th", "T"], ["dh", "D"], ["kh", "K"], ["gh", "G"],
    ["ph", "F"], ["bh", "B"], ["jh", "J"], ["zh", "J"],
  ];
  var SINGLES = { z: "J", w: "v", q: "k", f: "F" };
  var VOWEL_RUNS = [
    ["aa", "a"], ["ee", "i"], ["ii", "i"],
    ["oo", "u"], ["uu", "u"], ["ei", "e"],
  ];
  var DEASPIRATE = { T: "t", D: "d", K: "k", G: "g", F: "f", B: "b", J: "j", C: "c" };
  var VOWELS = "aeiou";

  function replaceAll(s, from, to) { return s.split(from).join(to); }

  function core(word, prefix) {
    var w = word.toLowerCase().replace(/[^a-z]/g, "");
    if (!w) return "";
    w = replaceAll(w, "x", "ks");
    for (var i = 0; i < DIGRAPHS.length; i++) w = replaceAll(w, DIGRAPHS[i][0], DIGRAPHS[i][1]);
    var chars = w.split("");
    for (i = 0; i < chars.length; i++) if (SINGLES[chars[i]]) chars[i] = SINGLES[chars[i]];
    w = chars.join("");
    if (w.length > 1) w = w[0] + replaceAll(w.slice(1), "y", "i");
    for (var pass = 0; pass < 3; pass++) {
      var before = w;
      for (i = 0; i < VOWEL_RUNS.length; i++) w = replaceAll(w, VOWEL_RUNS[i][0], VOWEL_RUNS[i][1]);
      if (w === before) break;
    }
    var out = [];
    for (i = 0; i < w.length; i++) {
      var c = w[i], cl = c.toLowerCase();
      if (out.length && out[out.length - 1].toLowerCase() === cl && VOWELS.indexOf(cl) < 0) {
        if (c !== cl) out[out.length - 1] = c;
        continue;
      }
      out.push(c);
    }
    w = out.join("");
    if (!prefix) {
      while (w.length > 2 && "nm".indexOf(w[w.length - 1]) >= 0 && VOWELS.indexOf(w[w.length - 2]) >= 0) w = w.slice(0, -1);
      while (w.length > 2 && w[w.length - 1] === "h") w = w.slice(0, -1);
    }
    return w;
  }

  function strictKey(word, prefix) { return core(word, !!prefix); }

  function looseKey(word, prefix) {
    var w = core(word, !!prefix), out = "";
    for (var i = 0; i < w.length; i++) out += DEASPIRATE[w[i]] || w[i];
    return out;
  }

  // ---------- engine ----------

  var MAX_SUGGESTIONS = 5;

  function withinOneEdit(a, b) {
    if (a === b) return true;
    if (Math.abs(a.length - b.length) > 1) return false;
    if (a.length > b.length) { var t = a; a = b; b = t; }
    var i = 0, j = 0, edited = false;
    while (i < a.length && j < b.length) {
      if (a[i] === b[j]) { i++; j++; continue; }
      if (edited) return false;
      edited = true;
      if (a.length === b.length) i++;
      j++;
    }
    return true;
  }

  // words: [[surface, freq], ...] sorted by freq desc.
  // bigrams: { prevIndex: [nextIndex, weight, nextIndex, weight, ...] }
  function Engine(words, bigrams) {
    this.words = new Array(words.length);
    this.byLoose = {};
    for (var i = 0; i < words.length; i++) {
      var s = words[i][0];
      var w = { id: i, surface: s, freq: words[i][1], sk: strictKey(s, true), lk: looseKey(s, true) };
      this.words[i] = w;
      (this.byLoose[w.lk] || (this.byLoose[w.lk] = [])).push(i);
    }
    this.followers = bigrams || {};
    this.userCounts = {};
  }

  Engine.prototype.byPrefix = function (keyPrefix, field, limit) {
    limit = limit || 60;
    var out = [];
    for (var i = 0; i < this.words.length; i++) {
      var w = this.words[i];
      if (w[field].lastIndexOf(keyPrefix, 0) === 0) {
        out.push(w);
        if (out.length >= limit) break;
      }
    }
    return out;
  };

  Engine.prototype.fuzzy = function (key, limit) {
    limit = limit || 40;
    var lo = Math.max(1, key.length - 1), hi = key.length + 2;
    var out = [], scanned = 0;
    for (var i = 0; i < this.words.length && scanned < 400; i++) {
      var w = this.words[i];
      if (w.lk.length < lo || w.lk.length > hi) continue;
      scanned++;
      if (withinOneEdit(key, w.lk)) {
        out.push(w);
        if (out.length >= limit) break;
      }
    }
    return out;
  };

  Engine.prototype.bigramWeights = function (prevWord) {
    var weights = {};
    if (!prevWord) return weights;
    var ids = this.byLoose[looseKey(prevWord, true)] || [];
    for (var i = 0; i < ids.length; i++) {
      var f = this.followers[ids[i]];
      if (!f) continue;
      for (var j = 0; j < f.length; j += 2) weights[f[j]] = f[j + 1];
    }
    return weights;
  };

  function notIn(rows, seen) {
    var out = [];
    for (var i = 0; i < rows.length; i++) if (!seen[rows[i].id]) out.push(rows[i]);
    return out;
  }
  function mark(seen, rows) { for (var i = 0; i < rows.length; i++) seen[rows[i].id] = true; }

  // Returns { surfaces, sk, lk, tiers: {strict, loose, fuzzy} }.
  Engine.prototype.suggestDetailed = function (typed, prevWord) {
    var sk = strictKey(typed, true), lk = looseKey(typed, true);
    if (!sk) return { surfaces: this.nextWord(prevWord), sk: "", lk: "", tiers: { strict: 0, loose: 0, fuzzy: 0 } };

    var skAlt = strictKey(typed, false), lkAlt = looseKey(typed, false);

    var strictRows = this.byPrefix(sk, "sk");
    var seen = {};
    if (skAlt !== sk && strictRows.length < 3) {
      mark(seen, strictRows);
      strictRows = strictRows.concat(notIn(this.byPrefix(skAlt, "sk"), seen));
    }
    var tiers = [[strictRows, 0]];
    seen = {}; mark(seen, strictRows);
    var looseRows = notIn(this.byPrefix(lk, "lk"), seen);
    if (lkAlt !== lk && strictRows.length + looseRows.length < 3) {
      var have = {}; mark(have, strictRows); mark(have, looseRows);
      looseRows = looseRows.concat(notIn(this.byPrefix(lkAlt, "lk"), have));
    }
    tiers.push([looseRows, 30]);
    mark(seen, looseRows);
    var fuzzyRows = [];
    if (strictRows.length + looseRows.length < 3 && lk.length >= 4) {
      fuzzyRows = notIn(this.fuzzy(lk), seen);
      tiers.push([fuzzyRows, 60]);
    }

    var weights = this.bigramWeights(prevWord);
    var scored = [];
    for (var t = 0; t < tiers.length; t++) {
      var rows = tiers[t][0], penalty = tiers[t][1];
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var score = r.freq - penalty;
        score += (weights[r.id] || 0) * 4;
        score += (this.userCounts[r.surface] || 0) * 25;
        score -= (r.lk.length - lk.length) * 3;
        if (r.sk === sk) score += 40;
        scored.push([score, r.surface]);
      }
    }
    scored.sort(function (a, b) {
      if (a[0] !== b[0]) return b[0] - a[0];
      if (a[1].length !== b[1].length) return a[1].length - b[1].length;
      return a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0;
    });
    var out = [], used = {};
    for (i = 0; i < scored.length; i++) {
      var s = scored[i][1];
      if (used[s]) continue;
      used[s] = true;
      out.push(s);
      if (out.length >= MAX_SUGGESTIONS) break;
    }
    return { surfaces: out, sk: sk, lk: lk,
             tiers: { strict: strictRows.length, loose: looseRows.length, fuzzy: fuzzyRows.length } };
  };

  Engine.prototype.suggest = function (typed, prevWord) {
    return this.suggestDetailed(typed, prevWord).surfaces;
  };

  Engine.prototype.nextWord = function (prevWord) {
    if (!prevWord) return [];
    var ids = this.byLoose[looseKey(prevWord, true)] || [];
    var cands = [];
    for (var i = 0; i < ids.length; i++) {
      var f = this.followers[ids[i]];
      if (!f) continue;
      for (var j = 0; j < f.length; j += 2) cands.push([f[j + 1], this.words[f[j]].surface]);
    }
    cands.sort(function (a, b) { return b[0] - a[0]; });
    var out = [];
    for (i = 0; i < cands.length && out.length < MAX_SUGGESTIONS; i++) out.push(cands[i][1]);
    return out;
  };

  Engine.prototype.accept = function (surface) {
    this.userCounts[surface] = (this.userCounts[surface] || 0) + 1;
  };

  var api = { strictKey: strictKey, looseKey: looseKey, Engine: Engine, MAX_SUGGESTIONS: MAX_SUGGESTIONS };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.Gujlish = api;
})(typeof window !== "undefined" ? window : this);
