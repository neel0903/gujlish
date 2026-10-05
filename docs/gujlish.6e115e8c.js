/*
 * Gujlish phonetics + suggestion engine, JavaScript.
 *
 * phonetics and the core ranking are line-for-line with phonetics.py and
 * engine.py; test_port.js checks this against the Python on every key
 * in the lexicon, every trial and every correction. Port the Swift
 * version from the Python and test it the same way.
 *
 * Beyond the Python reference this engine also has:
 *   - a personal dictionary: words, bigrams and trigrams learned from
 *     what you accept, type and import. Personal words the corpus never
 *     saw become real candidates, not just score bonuses.
 *   - English mixed mode: a plain-prefix English list competes with the
 *     Gujlish candidates at a fixed penalty, so "meet" shows meeting
 *     while "kem" never shows an English word.
 *
 * Structural difference from engine.py: the lexicon is in memory sorted
 * by frequency, so "ORDER BY freq DESC LIMIT n" is "scan in order, stop
 * at n". Personal additions mark the list unsorted; it re-sorts lazily.
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

  // ---------- scoring helpers ----------

  var MAX_SUGGESTIONS = 5;
  var ENGLISH_PENALTY = 15;
  var CORRECT_MARGIN = 20;

  // How much a word you have accepted or typed moves up. Three
  // acceptances put a word firmly ahead of the corpus; beyond that it
  // grows slowly, so a chat export with a word used 800 times does not
  // drown everything else.
  function userBoost(count) {
    return count ? 25 * Math.min(count, 3) + 10 * Math.log(1 + count) : 0;
  }
  // Corpus-scale frequency (1..100) for a word the corpus never had.
  function personalFreq(count) {
    return Math.min(100, Math.round(30 + 12 * Math.log(1 + count)));
  }
  // Bigram/trigram weight (1..100) for a pair learned from you.
  function personalWeight(count) {
    return Math.min(100, Math.round(20 * Math.min(count, 3) + 10 * Math.log(1 + count)));
  }

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

  // "gaye" vs "gaya": one vowel differs. The barakhadi is where typing
  // goes wrong most — the matra — so a vowel-only slip is the most
  // likely error and gets a bonus over consonant edits.
  function isVowelSwap(a, b) {
    if (a.length !== b.length) return false;
    var diff = -1;
    for (var i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) { if (diff >= 0) return false; diff = i; }
    }
    return diff >= 0 && VOWELS.indexOf(a[diff]) >= 0 && VOWELS.indexOf(b[diff]) >= 0;
  }

  function cleanSurface(s) {
    return (s || "").toLowerCase().replace(/[^a-z]/g, "");
  }

  function copyTable(src) {
    var out = {};
    for (var k in src) out[k] = src[k].slice();
    return out;
  }

  // ---------- engine ----------

  // words:    [[surface, freq, strictKey?, looseKey?], ...] sorted by freq desc
  // bigrams:  { prevId: [nextId, weight, nextId, weight, ...] }
  // english:  [[word, freq], ...] sorted by freq desc (optional)
  // trigrams: { "prev2Id prev1Id": [nextId, weight, ...] } (optional)
  function Engine(words, bigrams, english, trigrams) {
    this.words = [];        // scan order (freq desc)
    this.byId = [];         // id -> entry
    this.bySurface = {};
    this.byLoose = {};
    this.baseBigrams = bigrams || {};
    this.baseTrigrams = trigrams || {};
    this.userCounts = {};        // surface -> count (accepted, typed, imported)
    this.personalBigrams = {};   // "prev next" -> count
    this.personalTrigrams = {};  // "prev2 prev1 next" -> count
    this.mode = "mixed";         // mixed | gujlish | english
    this.sorted = true;
    for (var i = 0; i < words.length; i++) {
      var w = words[i];
      this._addWord(w[0], w[1], false, w[2], w[3]);
    }
    this._resetContext();
    this.english = [];
    this.englishSet = {};
    if (english) this.setEnglish(english);
  }

  Engine.prototype._addWord = function (surface, freq, personal, sk, lk) {
    var id = this.byId.length;
    var w = { id: id, surface: surface, freq: freq, personal: personal,
              sk: sk || strictKey(surface, true), lk: lk || looseKey(surface, true) };
    this.byId.push(w);
    this.words.push(w);
    this.bySurface[surface] = w;
    (this.byLoose[w.lk] || (this.byLoose[w.lk] = [])).push(id);
    return w;
  };

  Engine.prototype._resetContext = function () {
    this.followers = copyTable(this.baseBigrams);
    this.tri = copyTable(this.baseTrigrams);
  };

  Engine.prototype._ensureSorted = function () {
    if (this.sorted) return;
    this.words.sort(function (a, b) {
      if (a.freq !== b.freq) return b.freq - a.freq;
      return a.surface < b.surface ? -1 : a.surface > b.surface ? 1 : 0;
    });
    this.sorted = true;
  };

  Engine.prototype.setEnglish = function (list) {
    this.english = [];
    this.englishSet = {};          // word -> freq
    for (var i = 0; i < list.length; i++) {
      this.english.push({ surface: list[i][0], freq: list[i][1] });
      this.englishSet[list[i][0]] = list[i][1];
    }
  };

  Engine.prototype.byPrefix = function (keyPrefix, field, limit) {
    this._ensureSorted();
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
    this._ensureSorted();
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

  Engine.prototype.englishByPrefix = function (typed, limit) {
    limit = limit || 20;
    var out = [];
    for (var i = 0; i < this.english.length; i++) {
      var e = this.english[i];
      if (e.surface.lastIndexOf(typed, 0) === 0) {
        out.push(e);
        if (out.length >= limit) break;
      }
    }
    return out;
  };

  Engine.prototype.bigramWeights = function (prev1) {
    var weights = {};
    if (!prev1) return weights;
    var ids = this.byLoose[looseKey(prev1, true)] || [];
    for (var i = 0; i < ids.length; i++) {
      var f = this.followers[ids[i]];
      if (!f) continue;
      for (var j = 0; j < f.length; j += 2) {
        if (!(weights[f[j]] >= f[j + 1])) weights[f[j]] = f[j + 1];
      }
    }
    return weights;
  };

  Engine.prototype.trigramWeights = function (prev2, prev1) {
    var weights = {};
    if (!prev1 || !prev2) return weights;
    var ids2 = this.byLoose[looseKey(prev2, true)] || [];
    var ids1 = this.byLoose[looseKey(prev1, true)] || [];
    for (var a = 0; a < ids2.length; a++) {
      for (var b = 0; b < ids1.length; b++) {
        var f = this.tri[ids2[a] + " " + ids1[b]];
        if (!f) continue;
        for (var j = 0; j < f.length; j += 2) {
          if (!(weights[f[j]] >= f[j + 1])) weights[f[j]] = f[j + 1];
        }
      }
    }
    return weights;
  };

  // id -> score contribution from the words before.
  Engine.prototype.context = function (prev1, prev2) {
    var ctx = {}, id;
    var bi = this.bigramWeights(prev1), tri = this.trigramWeights(prev2, prev1);
    for (id in bi) ctx[id] = (ctx[id] || 0) + bi[id] * 4;
    for (id in tri) ctx[id] = (ctx[id] || 0) + tri[id] * 6;
    return ctx;
  };

  function notIn(rows, seen) {
    var out = [];
    for (var i = 0; i < rows.length; i++) if (!seen[rows[i].id]) out.push(rows[i]);
    return out;
  }
  function mark(seen, rows) { for (var i = 0; i < rows.length; i++) seen[rows[i].id] = true; }

  // Returns { surfaces, sources, sk, lk, tiers: {strict, loose, fuzzy, english} }.
  // sources[surface] is "gu", "en" or "me" (a personal word).
  Engine.prototype.suggestDetailed = function (typed, prev1, prev2) {
    var typedClean = cleanSurface(typed);
    var sk = strictKey(typed, true), lk = looseKey(typed, true);
    var empty = { surfaces: [], sources: {}, sk: "", lk: "", tiers: { strict: 0, loose: 0, fuzzy: 0, english: 0 } };
    if (!sk) { empty.surfaces = this.nextWord(prev1, prev2); return empty; }

    var scored = [], src = {};
    var strictRows = [], looseRows = [], fuzzyRows = [], engRows = [];

    if (this.mode !== "english") {
      var skAlt = strictKey(typed, false), lkAlt = looseKey(typed, false);

      strictRows = this.byPrefix(sk, "sk");
      var seen = {};
      if (skAlt !== sk && strictRows.length < 3) {
        mark(seen, strictRows);
        strictRows = strictRows.concat(notIn(this.byPrefix(skAlt, "sk"), seen));
      }
      var tiers = [[strictRows, 0]];
      seen = {}; mark(seen, strictRows);
      looseRows = notIn(this.byPrefix(lk, "lk"), seen);
      if (lkAlt !== lk && strictRows.length + looseRows.length < 3) {
        var have = {}; mark(have, strictRows); mark(have, looseRows);
        looseRows = looseRows.concat(notIn(this.byPrefix(lkAlt, "lk"), have));
      }
      tiers.push([looseRows, 30]);
      mark(seen, looseRows);
      if (strictRows.length + looseRows.length < 3 && lk.length >= 4) {
        fuzzyRows = notIn(this.fuzzy(lk), seen);
        tiers.push([fuzzyRows, 60]);
      }

      var ctx = this.context(prev1, prev2);
      for (var t = 0; t < tiers.length; t++) {
        var rows = tiers[t][0], penalty = tiers[t][1];
        for (var i = 0; i < rows.length; i++) {
          var r = rows[i];
          var score = r.freq - penalty;
          score += ctx[r.id] || 0;
          score += userBoost(this.userCounts[r.surface]);
          score -= (r.lk.length - lk.length) * 3;
          if (r.sk === sk) score += 40;
          scored.push([score, r.surface]);
          if (!src[r.surface]) src[r.surface] = r.personal ? "me" : "gu";
        }
      }
    }

    if (this.mode !== "gujlish" && typedClean) {
      engRows = this.englishByPrefix(typedClean);
      for (i = 0; i < engRows.length; i++) {
        var e = engRows[i];
        var es = e.freq - ENGLISH_PENALTY;
        es += userBoost(this.userCounts[e.surface]);
        es -= (e.surface.length - typedClean.length) * 3;
        if (e.surface === typedClean) es += 40;
        scored.push([es, e.surface]);
        if (!src[e.surface]) src[e.surface] = "en";
      }
    }

    scored.sort(function (a, b) {
      if (a[0] !== b[0]) return b[0] - a[0];
      if (a[1].length !== b[1].length) return a[1].length - b[1].length;
      return a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0;
    });
    var out = [], used = {}, sources = {};
    for (i = 0; i < scored.length; i++) {
      var s = scored[i][1];
      if (used[s]) continue;
      used[s] = true;
      out.push(s);
      sources[s] = src[s];
      if (out.length >= MAX_SUGGESTIONS) break;
    }
    return { surfaces: out, sources: sources, sk: sk, lk: lk,
             tiers: { strict: strictRows.length, loose: looseRows.length,
                      fuzzy: fuzzyRows.length, english: engRows.length } };
  };

  Engine.prototype.suggest = function (typed, prev1, prev2) {
    return this.suggestDetailed(typed, prev1, prev2).surfaces;
  };

  Engine.prototype.nextWord = function (prev1, prev2) {
    if (!prev1) return [];
    var bi = this.bigramWeights(prev1), tri = this.trigramWeights(prev2, prev1);
    var scores = {}, id;
    for (id in bi) scores[id] = (scores[id] || 0) + bi[id];
    for (id in tri) scores[id] = (scores[id] || 0) + tri[id] * 1.5;
    var cands = [];
    for (id in scores) cands.push([scores[id], this.byId[id].surface]);
    cands.sort(function (a, b) {
      if (a[0] !== b[0]) return b[0] - a[0];
      return a[1] < b[1] ? -1 : a[1] > b[1] ? 1 : 0;
    });
    var out = [];
    for (var i = 0; i < cands.length && out.length < MAX_SUGGESTIONS; i++) out.push(cands[i][1]);
    return out;
  };

  // ---------- autocorrect ----------

  // What the committed word should have been, or null to leave it.
  // Mirrors GujlishEngine.correct in engine.py. Candidates are words
  // with the same phonetic key (gharey -> ghare, thayoo -> thayu) and
  // words one letter away (gaye -> gaya, ghara -> ghare), scored like
  // suggestions plus a closeness bonus, against a bias to keep what was
  // typed. Words you have taught it (accepted or restored twice) are
  // never corrected; common known words are never corrected. In mixed
  // mode an English word defends itself with its own frequency, so
  // "meeting" and "gate" stay but "avi" (a video format) still becomes
  // aavi.
  Engine.prototype.correct = function (typed, prev1, prev2) {
    var clean = cleanSurface(typed);
    if (clean.length < 3) return null;
    var known = this.bySurface[clean];
    var uc = this.userCounts[clean] || 0;
    if (uc >= 2) return null;
    if (known && !known.personal && known.freq >= 60) return null;

    var ctx = this.context(prev1, prev2);
    var keep = 30;
    if (known && !known.personal) keep = known.freq + (ctx[known.id] || 0) + userBoost(uc) + 25;
    var eng = this.englishSet && this.mode !== "gujlish" ? this.englishSet[clean] : 0;
    if (eng) keep = Math.max(keep, eng - ENGLISH_PENALTY + userBoost(uc) + 25);

    var cands = {}, id, i;
    var keys = [looseKey(clean, true), looseKey(clean, false)];
    for (i = 0; i < keys.length; i++) {
      var ids = this.byLoose[keys[i]] || [];
      for (var j = 0; j < ids.length; j++) cands[ids[j]] = 30;
    }
    this._ensureSorted();
    for (i = 0; i < this.words.length; i++) {
      var w = this.words[i];
      if (cands[w.id] !== undefined || Math.abs(w.surface.length - clean.length) > 1) continue;
      if (withinOneEdit(clean, w.surface)) cands[w.id] = isVowelSwap(clean, w.surface) ? 10 : 0;
    }
    var best = null;
    for (id in cands) {
      w = this.byId[id];
      if (w.surface === clean) continue;
      if (w.personal && (this.userCounts[w.surface] || 0) < 2) continue;
      var s = w.freq + (ctx[w.id] || 0) + userBoost(this.userCounts[w.surface]) + cands[id];
      if (!best || s > best.score || (s === best.score && w.surface < best.surface)) best = { surface: w.surface, score: s };
    }
    if (!best || best.score - keep < CORRECT_MARGIN) return null;
    return best.surface;
  };

  // ---------- personal dictionary ----------

  Engine.prototype.learnWord = function (surface, count) {
    surface = cleanSurface(surface);
    if (!surface) return;
    count = count || 1;
    var total = (this.userCounts[surface] || 0) + count;
    this.userCounts[surface] = total;
    var w = this.bySurface[surface];
    if (!w) {
      this._addWord(surface, personalFreq(total), true);
      this.sorted = false;
    } else if (w.personal) {
      w.freq = personalFreq(total);
      this.sorted = false;
    }
  };

  function mergeFollower(list, nextId, weight) {
    for (var j = 0; j < list.length; j += 2) {
      if (list[j] === nextId) { if (weight > list[j + 1]) list[j + 1] = weight; return; }
    }
    list.push(nextId, weight);
  }

  Engine.prototype.learnBigram = function (prev, next, count) {
    prev = cleanSurface(prev); next = cleanSurface(next);
    var p = this.bySurface[prev], n = this.bySurface[next];
    if (!p || !n || p === n) return;
    var key = prev + " " + next;
    var total = (this.personalBigrams[key] || 0) + (count || 1);
    this.personalBigrams[key] = total;
    mergeFollower(this.followers[p.id] || (this.followers[p.id] = []), n.id, personalWeight(total));
  };

  Engine.prototype.learnTrigram = function (prev2, prev1, next, count) {
    prev2 = cleanSurface(prev2); prev1 = cleanSurface(prev1); next = cleanSurface(next);
    var a = this.bySurface[prev2], b = this.bySurface[prev1], n = this.bySurface[next];
    if (!a || !b || !n) return;
    var key = prev2 + " " + prev1 + " " + next;
    var total = (this.personalTrigrams[key] || 0) + (count || 1);
    this.personalTrigrams[key] = total;
    var k = a.id + " " + b.id;
    mergeFollower(this.tri[k] || (this.tri[k] = []), n.id, personalWeight(total));
  };

  // Called when the user takes a suggestion or commits a typed word.
  Engine.prototype.accept = function (surface, prev1, prev2) {
    this.learnWord(surface, 1);
    if (prev1) this.learnBigram(prev1, surface, 1);
    if (prev1 && prev2) this.learnTrigram(prev2, prev1, surface, 1);
  };

  // { words: {surface: count}, bigrams: {"a b": count}, trigrams: {"a b c": count} }
  Engine.prototype.loadPersonal = function (data) {
    if (!data) return;
    var words = data.words || {}, bigrams = data.bigrams || {}, trigrams = data.trigrams || {}, k, p;
    for (k in words) this.learnWord(k, words[k]);
    for (k in bigrams) {
      p = k.split(" ");
      if (p.length === 2) this.learnBigram(p[0], p[1], bigrams[k]);
    }
    for (k in trigrams) {
      p = k.split(" ");
      if (p.length === 3) this.learnTrigram(p[0], p[1], p[2], trigrams[k]);
    }
  };

  Engine.prototype.personalSnapshot = function () {
    return { words: this.userCounts, bigrams: this.personalBigrams, trigrams: this.personalTrigrams };
  };

  Engine.prototype.forgetPersonal = function () {
    this.userCounts = {};
    this.personalBigrams = {};
    this.personalTrigrams = {};
    var keep = [];
    for (var i = 0; i < this.words.length; i++) if (!this.words[i].personal) keep.push(this.words[i]);
    this.words = keep;
    this.byId = []; this.bySurface = {}; this.byLoose = {};
    for (i = 0; i < keep.length; i++) {
      var w = keep[i];
      this.byId[w.id] = w;
      this.bySurface[w.surface] = w;
      (this.byLoose[w.lk] || (this.byLoose[w.lk] = [])).push(w.id);
    }
    this._resetContext();
    this.sorted = false;
  };

  var api = { strictKey: strictKey, looseKey: looseKey, Engine: Engine,
              MAX_SUGGESTIONS: MAX_SUGGESTIONS, userBoost: userBoost, cleanSurface: cleanSurface };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.Gujlish = api;
})(typeof window !== "undefined" ? window : this);
