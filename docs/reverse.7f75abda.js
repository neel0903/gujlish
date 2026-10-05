/*
 * Latin -> Gujarati script, rule-based. The fallback for the script
 * preview when a word is not in the lexicon's surface -> script map
 * (names, new slang, typos). Lexicon words use the real script form.
 *
 * Deliberately simple: dental t/d (Latin cannot tell ત from ટ), s for
 * સ, sh for શ, inherent 'a' assumed between consonants unless the pair
 * is a common conjunct (pr, ky, tv, kl, doubled) or a nasal before a
 * consonant (which becomes anusvara: sambandh -> સંબંધ).
 */
(function (root) {
  "use strict";

  var CONS = {
    chh: "છ", ksh: "ક્ષ", ch: "ચ", kh: "ખ", gh: "ઘ", jh: "ઝ", th: "થ", dh: "ધ",
    ph: "ફ", bh: "ભ", sh: "શ", gn: "જ્ઞ",
    k: "ક", g: "ગ", c: "ક", j: "જ", z: "ઝ", t: "ત", d: "દ", n: "ન", p: "પ", f: "ફ",
    b: "બ", m: "મ", y: "ય", r: "ર", l: "લ", v: "વ", w: "વ", s: "સ", h: "હ", q: "ક", x: "ક્સ",
  };
  var SIGN = { a: "", aa: "ા", i: "િ", ee: "ી", ii: "ી", u: "ુ", oo: "ૂ", uu: "ૂ", e: "ે", ai: "ૈ", o: "ો", au: "ૌ", ei: "ે" };
  var IND = { a: "અ", aa: "આ", i: "ઇ", ee: "ઈ", ii: "ઈ", u: "ઉ", oo: "ઊ", uu: "ઊ", e: "એ", ai: "ઐ", o: "ઓ", au: "ઔ", ei: "એ" };
  var CONS_KEYS = ["chh", "ksh", "ch", "kh", "gh", "jh", "th", "dh", "ph", "bh", "sh", "gn",
                   "k", "g", "c", "j", "z", "t", "d", "n", "p", "f", "b", "m", "y", "r", "l", "v", "w", "s", "h", "q", "x"];
  var VOWEL_KEYS = ["aa", "ee", "ii", "oo", "uu", "ai", "au", "ei", "a", "i", "u", "e", "o"];
  var VIRAMA = "્", ANUSVARA = "ં";

  function units(word) {
    var out = [], i = 0;
    while (i < word.length) {
      var hit = null, k;
      for (k = 0; k < CONS_KEYS.length; k++) {
        if (word.lastIndexOf(CONS_KEYS[k], i) === i) { hit = ["c", CONS_KEYS[k]]; break; }
      }
      if (!hit) {
        for (k = 0; k < VOWEL_KEYS.length; k++) {
          if (word.lastIndexOf(VOWEL_KEYS[k], i) === i) { hit = ["v", VOWEL_KEYS[k]]; break; }
        }
      }
      if (!hit) { i++; continue; }
      out.push(hit);
      i += hit[1].length;
    }
    return out;
  }

  function toGujarati(word) {
    word = (word || "").toLowerCase().replace(/[^a-z]/g, "");
    var u = units(word), out = "";
    for (var i = 0; i < u.length; i++) {
      var kind = u[i][0], val = u[i][1], next = u[i + 1];
      if (kind === "v") {
        out += IND[val];
        continue;
      }
      var isNasal = val === "n" || val === "m";
      if (next && next[0] === "c") {
        var nc = next[1];
        if (isNasal && !/^[yrlvh]/.test(nc) && i > 0) { out += ANUSVARA; continue; }
        out += CONS[val];
        // Conjunct only where Latin is unambiguous: a doubled consonant,
        // a glide (kanya, vyavsay), or r/l/v right after a word-initial
        // consonant (pravin, kripa). Mid-word "kr" is usually a dropped
        // schwa (dikra, chokra), so it stays two syllables.
        if (nc === val || /^[yv]/.test(nc) || (i === 0 && /^[rl]/.test(nc))) out += VIRAMA;
        continue;
      }
      if (next && next[0] === "v") {
        var sign = SIGN[next[1]];
        var last = i + 1 === u.length - 1;
        // A final written "a" is a real long vowel (kanya -> કન્યા);
        // a bare final consonant would have no a at all. Final "ai"
        // is a + i (bhai -> ભાઈ), mid-word it is the diphthong (paisa).
        if (last && next[1] === "a") sign = "ા";
        if (last && next[1] === "ai") sign = "ાઈ";
        out += CONS[val] + sign;
        i++;
        continue;
      }
      // word-final consonant
      var prev = u[i - 1];
      if (val === "n" && prev && prev[0] === "v" && prev[1] === "u") out += ANUSVARA;
      else out += CONS[val];
    }
    return out;
  }

  var api = { toGujarati: toGujarati };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.GujlishReverse = api;
})(typeof window !== "undefined" ? window : this);
