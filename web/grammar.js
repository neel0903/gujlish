/*
 * Gujlish grammar: agreement checks that catch what actually goes wrong
 * in chat Gujarati. Rules, not a model, so every finding has a reason.
 *
 *   1. The present copula must match the subject pronoun:
 *        hu chu · tu che · tame cho · ame chie · e/te che
 *   2. Future verbs carry person:   hu jaish · tame jasho · ame jaishu · te jashe
 *      and the future copula:       hu hoish · tame hasho · te hashe
 *   3. A past verb in -yo after a plural subject wants -ya:  ame gaya
 *      and after hu, -ya wants -yo or -yi (gender is the writer's call).
 *
 * The subject is the nearest pronoun to the left inside the clause;
 * a conjunction (ane, pan, ke, etle, to, ...) or sentence punctuation
 * ends the clause. "hu ane tame" counts as first person plural.
 *
 * Verb stems are verified against the lexicon (stem + vu/va must be a
 * known word) so that "english" or "finish" never look like futures.
 *
 * Pure functions; test_grammar.js runs the rules and the golden
 * sentences. Not ported to Python: this is app logic, not the engine.
 */
(function (root) {
  "use strict";
  var G = root.Gujlish || (typeof require === "function" ? require("./gujlish.js") : null);
  // Prefix-mode keys: the whole-word key strips a final nasal, which
  // would make "kem" look like the conjunction "ke". Nasal variants
  // (hun, chhun) are listed explicitly instead.
  var lk = function (w) { return G.looseKey(w, true); };

  // Tables are written as people spell the words and keyed by loose key
  // at load, because every lookup is by loose key ("tyare" keys as
  // "tiare", "badha" as "bada"; spelled-out keys would never match).
  function keyed(src) { var out = {}; for (var k in src) out[lk(k)] = src[k]; return out; }

  var SUBJECT = keyed({
    hu: "1sg", hun: "1sg", tu: "2sg", tun: "2sg", tame: "2pl", ap: "2pl",
    ame: "1pl", apne: "1pl", e: "3sg", te: "3sg", a: "3sg",
    pelo: "3sg", peli: "3sg", pelu: "3sg", teo: "3pl", pela: "3pl", badha: "3pl", loko: "3pl",
  });
  var STOPS = keyed({ ane: 1, pan: 1, ke: 1, etle: 1, to: 1, karan: 1, karanke: 1,
                      jo: 1, tyare: 1, jyare: 1, athva: 1, matlab: 1, bas: 1 });
  // "tame badha", "ame badha": badha only strengthens the pronoun before it.
  var QUANTIFIER = keyed({ badha: 1 });
  // Past copula: hu hato/hati, ame/tame/teo hata. Only the masculine
  // singular is checked; hati and hatu are left to the writer.
  var PAST_COPULA_SG = lk("hato"), PAST_COPULA_PL = lk("hata");

  // loose key -> persons this form agrees with
  var COPULA = { cu: "1sg", cun: "1sg", ce: "2sg 3sg 3pl", co: "2pl", cie: "1pl" };
  var COPULA_FOR = { "1sg": "chu", "2sg": "che", "2pl": "cho", "1pl": "chie", "3sg": "che", "3pl": "che" };
  var FUT_COPULA = { hois: "1sg 2sg", hoisu: "1pl", haso: "2pl", hase: "3sg 3pl" };
  var FUT_COPULA_FOR = { "1sg": "hoish", "2sg": "hoish", "2pl": "hasho", "1pl": "hoishu", "3sg": "hashe", "3pl": "hashe" };
  // future endings, longest first
  var FUTURE = [["ishu", "1pl"], ["shu", "1pl"], ["ish", "1sg 2sg"], ["sho", "2pl"], ["she", "3sg 3pl"]];
  var FUTURE_FOR = { "1sg": "ish", "2sg": "ish", "2pl": "sho", "1pl": "ishu", "3sg": "she", "3pl": "she" };
  // stems whose infinitive is irregular or absent from the lexicon
  var IRREGULAR_STEMS = { ga: 1, ja: 1, tha: 1, aav: 1, av: 1, kar: 1, le: 1, de: 1, la: 1, kah: 1, rah: 1, jo: 1, ho: 1 };

  function agrees(persons, subj) { return persons.split(" ").indexOf(subj) >= 0; }

  function matchCase(typed, fix) {
    if (typed.length > 1 && typed === typed.toUpperCase() && /[A-Z]/.test(typed)) return fix.toUpperCase();
    if (/^[A-Z]/.test(typed)) return fix.charAt(0).toUpperCase() + fix.slice(1);
    return fix;
  }

  function tokenize(text) {
    var out = [], re = /[A-Za-z]+|\n|[^\sA-Za-z]+/g, m;
    while ((m = re.exec(text))) {
      out.push({ text: m[0], start: m.index, end: m.index + m[0].length, word: /^[A-Za-z]+$/.test(m[0]) });
    }
    return out;
  }

  function isVerbStem(stem, engine) {
    if (stem.length < 2) return false;
    if (IRREGULAR_STEMS[stem]) return true;
    if (!engine) return false;
    var forms = [stem + "vu", stem + "vun", stem + "va"];
    for (var i = 0; i < forms.length; i++) {
      if (engine.byLoose[G.looseKey(forms[i], true)]) return true;
    }
    return false;
  }

  // Nearest subject pronoun to the left, inside the clause.
  // Returns { person: "1sg", word: "hu" } or null.
  function subjectFor(tokens, i) {
    var found = [];
    for (var j = i - 1; j >= 0; j--) {
      var t = tokens[j];
      if (!t.word) {
        if (/[.!?\n]/.test(t.text)) break;
        continue;
      }
      var k = lk(t.text);
      if (STOPS[k]) break;
      if (SUBJECT[k]) {
        if (QUANTIFIER[k] && j >= 1 && tokens[j - 1].word && SUBJECT[lk(tokens[j - 1].text)] &&
            !QUANTIFIER[lk(tokens[j - 1].text)]) continue;
        found.push({ person: SUBJECT[k], word: t.text });
        if (j >= 2 && tokens[j - 1].word && lk(tokens[j - 1].text) === "ane" &&
            tokens[j - 2].word && SUBJECT[lk(tokens[j - 2].text)]) {
          found.push({ person: SUBJECT[lk(tokens[j - 2].text)], word: tokens[j - 2].text });
        }
        break;
      }
    }
    if (!found.length) return null;
    if (found.length === 1) return found[0];
    var persons = found.map(function (f) { return f.person.charAt(0); });
    var word = found[1].word + " ane " + found[0].word;
    if (persons.indexOf("1") >= 0) return { person: "1pl", word: word };
    if (persons.indexOf("2") >= 0) return { person: "2pl", word: word };
    return { person: "3pl", word: word };
  }

  function issue(t, fix, why, alt) {
    var out = { start: t.start, end: t.end, from: t.text, to: matchCase(t.text, fix), why: why };
    if (alt) out.alt = matchCase(t.text, alt);
    return out;
  }

  // check(text, engine) -> [{start, end, from, to, alt?, why}]
  function check(text, engine) {
    var tokens = tokenize(text), issues = [];
    for (var i = 0; i < tokens.length; i++) {
      var t = tokens[i];
      if (!t.word) continue;
      var lower = t.text.toLowerCase(), key = lk(lower), subj;

      if (COPULA[key]) {
        subj = subjectFor(tokens, i);
        if (subj && !agrees(COPULA[key], subj.person)) {
          issues.push(issue(t, COPULA_FOR[subj.person], "after " + subj.word + " it is " + COPULA_FOR[subj.person]));
        }
        continue;
      }
      if (FUT_COPULA[key]) {
        subj = subjectFor(tokens, i);
        if (subj && !agrees(FUT_COPULA[key], subj.person)) {
          issues.push(issue(t, FUT_COPULA_FOR[subj.person], "after " + subj.word + " it is " + FUT_COPULA_FOR[subj.person]));
        }
        continue;
      }

      if (key === PAST_COPULA_SG || key === PAST_COPULA_PL) {
        subj = subjectFor(tokens, i);
        if (subj && key === PAST_COPULA_SG && /pl$/.test(subj.person)) {
          issues.push(issue(t, "hata", "after " + subj.word + " it is hata"));
        } else if (subj && key === PAST_COPULA_PL && subj.person === "1sg") {
          issues.push(issue(t, "hato", "after hu it is hato or hati", "hati"));
        }
        continue;
      }

      var handled = false;
      for (var f = 0; f < FUTURE.length && !handled; f++) {
        var ending = FUTURE[f][0], persons = FUTURE[f][1];
        if (lower.length > ending.length + 1 && lower.slice(-ending.length) === ending) {
          var stem = lower.slice(0, -ending.length);
          if (!isVerbStem(stem, engine)) continue;
          handled = true;
          subj = subjectFor(tokens, i);
          if (subj && !agrees(persons, subj.person)) {
            issues.push(issue(t, stem + FUTURE_FOR[subj.person],
              "after " + subj.word + " the verb ends in -" + FUTURE_FOR[subj.person]));
          }
        }
      }
      if (handled) continue;

      if (lower.length > 3 && lower.slice(-2) === "yo") {
        stem = lower.slice(0, -2);
        if (isVerbStem(stem, engine)) {
          subj = subjectFor(tokens, i);
          if (subj && /pl$/.test(subj.person)) {
            issues.push(issue(t, stem + "ya", "after " + subj.word + " the verb ends in -ya"));
          }
        }
        continue;
      }
      if (lower.length > 3 && lower.slice(-2) === "ya") {
        stem = lower.slice(0, -2);
        if (isVerbStem(stem, engine)) {
          subj = subjectFor(tokens, i);
          if (subj && subj.person === "1sg") {
            issues.push(issue(t, stem + "yo", "after hu the verb ends in -yo or -yi", stem + "yi"));
          }
        }
      }
    }
    return issues;
  }

  function apply(text, iss, useAlt) {
    var to = useAlt && iss.alt ? iss.alt : iss.to;
    return text.slice(0, iss.start) + to + text.slice(iss.end);
  }

  // Apply every issue, first option, right to left so offsets hold.
  function fixAll(text, engine) {
    var issues = check(text, engine);
    for (var i = issues.length - 1; i >= 0; i--) text = apply(text, issues[i]);
    return text;
  }

  var api = { check: check, apply: apply, fixAll: fixAll, tokenize: tokenize };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.GujlishGrammar = api;
})(typeof window !== "undefined" ? window : this);
