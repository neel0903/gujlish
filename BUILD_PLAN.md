# Gujlish — build plan and handoff

A predictive keyboard for romanised Gujarati. You type `tha`, it suggests
`thayu`. Output stays in Latin letters — no Gujarati script anywhere on
the device. Target is iOS first (custom keyboard extension), Android later.

This document is the running brief. **Read `STATUS` first: the phonetic
layer and the corpus pipeline are built and tested. Do not rewrite them.**

---

## STATUS

Working and validated in this directory (last verified 2026-09-19, on
Windows with Python 3.12 — `python`, not `python3`):

| File | State |
|---|---|
| `phonetics.py` | **Done.** 18/18 variant groups collapse correctly. Run `python phonetics.py` |
| `engine.py` | **Done.** Suggestion engine. Run `python engine.py` |
| `build_db.py` | **Done.** `python build_db.py lexicon.tsv` emits the shipping DB |
| `translit.py` | **Done.** Rule-based Gujarati script → chat Latin, 65/65 cases. Run `python translit.py` |
| `build_lexicon.py` | **Done.** Phase 1 corpus pipeline. Run `python build_lexicon.py` (~2 min first time, wiki counts cached under `data/`) |
| `compare_db.py` | **Done.** Acceptance test: seed DB vs corpus DB side by side |
| `lexicon.tsv`, `lexicon.bigrams.tsv` | **Built.** 40,058 surfaces, 86,340 bigrams — the pipeline output |
| `lexicon.review.tsv` | Review only. Each surface with the native-script words behind it. Never ships |
| `gujlish.db` | **Built from the corpus.** 40,058 words, 4.3 MB |
| `gujlish.seed.db` | The old hand-built DB, kept as the baseline for `compare_db.py` |
| `seed_lexicon.py` | Still used — as the chat-register overlay inside the pipeline, not as the lexicon |
| `data/` | Corpus inputs, 2.1 GB. `data/SOURCES.md` records URLs, pinned revisions and licences |
| `web/gujlish.js` | **Done.** JavaScript port of phonetics + engine. Tested against Python: 40,073/40,073 keys identical, 34/34 trials identical |
| `web/tester_template.html` | **Done.** The Phase 2 UI; `build_tester.py` inlines the engine and lexicon into it |
| `build_tester.py` | **Done.** `python build_tester.py` → `tester.html` (1.4 MB, one file) + `web/expected.json` for the port test |
| `web/test_port.js` | **Done.** `node web/test_port.js` — JS vs Python, plus latency (3.5 ms worst) |
| `tester.html` | Phase 2 single-file tester. Superseded by the hosted PWA below; still builds |
| `web/index.html`, `app.js`, `app.css`, `sw_template.js` | **Done.** The hosted PWA (Phase 2b). `gujlish.js` gained a personal dictionary and English mixed mode |
| `build_site.py` | **Done.** `python build_site.py` → `docs/` (2.4 MB): hashed assets, manifest, icons, service worker |
| `docs/` | **Built, committed.** What GitHub Pages serves. Never edit by hand |
| `README.md`, `.gitignore` | Repo is git; `data/`, DBs and generated files are ignored |

Verify the handoff landed intact:

```bash
python phonetics.py            # expect 18/18
python translit.py             # expect 65/65
python build_lexicon.py        # expect ~40K surfaces (needs data/, see SOURCES.md)
python build_db.py lexicon.tsv # expect ~40K words, ~4.3 MB
python compare_db.py           # thayu for 'tha', cho after 'kem', karo after 'su'
python build_tester.py         # expect tester.html ~1.4 MB
node web/test_port.js          # expect all keys and trials identical
```

If those pass, Phases 1 and 2 are done. To try the tester on the phone,
on the same Wi-Fi:

```bash
python -m http.server 8000     # then open http://<this PC's IP>:8000/tester.html
```

and use Share → Add to Home Screen. Or just AirDrop / Drive the single
`tester.html` file; it needs no server.
`data/dakshina_dataset_v1.0.tar` (2 GB) can be deleted once
`data/dakshina/gu/lexicons/` exists; the pipeline only reads the
extracted lexicons.

---

## The design decisions already made

**Not translation.** This is autocomplete over a romanised Gujarati
lexicon. The Gujarati script appears only inside the build pipeline, as
the join key between a word's frequency and its romanisations. It never
ships.

**Two phonetic keys per word, not one.** Romanised Gujarati has no
standard spelling, so we index on a collapsed key. But not all variation
is equal:

- `strict_key` preserves aspiration — `thayu` → `Taiu`
- `loose_key` folds it — `thayu` → `taiu`, same as `tayu`

Querying strict first, then loose at a 30-point penalty, is what makes
`tha` return `thayu` instead of `tame`. A single conflated key gets this
wrong, and it was the first bug found in testing.

**Prefix mode matters.** A complete word gets its trailing nasal stripped
(`chhun` → `Cu`) because nasalisation is written inconsistently. A
half-typed prefix must not — stripping the m from `jam` gives `ja` and
buries `jaman` under every ja- word. Words are indexed un-stripped;
the engine tries the stripped form only when the direct match is thin.

**Ranking order**, strongest signal first: bigram weight for the previous
word → user dictionary count → corpus frequency → shorter completions
first.

---

## Phase 1 — the corpus pipeline (`build_lexicon.py`)

The seed lexicon is my guess at common Gujlish. Real frequency data will
be better, and this is the step that decides whether the whole thing
feels right.

**The join.** Frequency lives on the native-script word; romanisations
inherit it.

```
gu.wikipedia dump ──► word counts + bigrams (Gujarati script)
                              │
Dakshina gu lexicon ──────────┼──► join on the native-script word
Aksharantar guj pairs ────────┘
                              ▼
        surface<TAB>freq   +   prev<TAB>next<TAB>weight
                              ▼
                      build_db.py  ──►  gujlish.db
```

**Sources** (none reachable from my sandbox — all three need your
machine):

1. **Gujarati Wikipedia** — `https://dumps.wikimedia.org/guwiki/latest/guwiki-latest-pages-articles.xml.bz2`, roughly 150 MB. Strip markup, tokenise on Gujarati Unicode range `\u0A80-\u0AFF`, count unigrams and bigrams.
2. **Dakshina** — `github.com/google-research-datasets/dakshina`. Use `gu/lexicons/` — native-script words with attested romanisations, human-validated. Highest quality, smaller coverage. Around 300K word pairs across all languages.
3. **Aksharantar** — `huggingface.co/datasets/ai4bharat/Aksharantar`, `guj` split. 26M pairs total across 21 languages, mined plus annotated. Much bigger coverage, noisier.

**Licence check before you commit to Aksharantar.** The dataset card has
been inconsistent across revisions — some list CC-BY-NC-4.0, the current
one lists CC0 for the mined packaging and CC-BY for the manual portion.
Pin the revision you use and record it. NC would be fine for a free
personal app and a problem if you ever charge. Dakshina is the safer
base if you want one clean answer.

**Scoring.** For each native word with count `c` and romanisations
`r1..rn` with attestation shares `s1..sn`, emit `(ri, c * si)`. Cap the
output at the top 30–50K surface forms — bigger is actively worse, since
rare words crowd out common ones in the suggestion strip.

**Deliverables:** `lexicon.tsv` and `lexicon.bigrams.tsv`, then
`python3 build_db.py lexicon.tsv`. The loader for both already exists.

**Acceptance test:** run `engine.py` against the new DB and eyeball it.
The seed lexicon's outputs above are the baseline — corpus data should be
at least as good on common phrases (`kem` → `cho`, `su` → `karo`,
`khabar` → `nathi`) and much better on vocabulary breadth.

### Phase 1 outcome (2026-09-19)

Done. Acceptance holds (`compare_db.py`): `tha` → thayu, `kem` → cho,
`su` → karo, `khabar` → nathi, `mjama` → majama, and breadth probes the
seed could not answer now do (`sarkar`, `amdavad`, `gujar`, `pra`, next
word after `bharat` / `gujarat` / `ane`). Top of the lexicon by weight is
che, ane, hu, chu, kem, su, ha, nathi, cho, mane, na, tame — the language,
not Wikipedia's boilerplate.

Things learned that changed the design, so they aren't rediscovered:

- **The Dakshina URL in the original notes is dead.** Working one is
  `storage.googleapis.com/gresearch/dakshina/dakshina_dataset_v1.0.tar`.
  Licence CC BY-SA 4.0. Aksharantar pinned at revision `e418c1fc…`
  (CC-BY manual / CC0 mined, no NC clause). Details in `data/SOURCES.md`.
- **Aksharantar cannot be the join on its own.** It has no entry for 18
  of the 80 most frequent words — છે, આ, એક, માટે, પણ, તે among them —
  and where it has one spelling it is often a single mined hit (`nope`
  for ના, `aneey` for અને). Dakshina covers 98% of the top 1,000 wiki
  words with real annotator counts, so it decides spellings where it
  exists. `translit.py` generates a rule-based spelling for every native
  word to fill the gaps; against Dakshina's 30K words it lands in a human
  spelling group 91.6% of the time. Its known losses are compounds
  (bhavangar) and English-convention place names (gujrat) — the attested
  data covers those.
- **Gujarati Wikipedia is ~18K village stubs from one template.** Raw
  counts put "primary school, panchayat house, anganwadi, dairy" at the
  top. The pipeline counts each distinct sentence once (234K repeats
  skipped out of 700K) and that fixes it.
- **Annotator convention ≠ chat register.** Dakshina writes hatee,
  praapt, rajyamaan; the register writes hati, prapt, rajyama. `canon()`
  in the pipeline folds long vowels, `ae`, `q`/`w`, and the trailing
  nasal of an anusvara-final word, so spellings that differ only by
  convention count together. A word-initial `aa` is kept (aaje, aavjo).
- **One surface per phonetic group.** Every native word's romanisations
  are grouped by whole-word strict key; each group emits one surface. The
  primary group carries the word's full count, secondary groups need a
  30% share. Otherwise the strip fills with thayu/thayoo/thaiu.
- **Wikipedia has no "kem cho".** The seed lexicon is merged back as an
  overlay: seed words keep at least their seed weight, seed bigrams are
  kept verbatim, and where the corpus spelled a seed word differently
  (kam vs kaam) the seed spelling takes over the entry. Counts are
  log-scaled onto the engine's 1–100 range.

Knobs, all at the top of `build_lexicon.py`: `--top` (default 40,000
surfaces), `MIN_GROUP_SHARE`, `GENERATED_WEIGHT`, `TRUST_HUMANS_AT`,
`FOLLOWERS_PER_WORD`. `--refresh-wiki` recounts the dump after any
tokeniser change.

Known rough edges, deliberately left for real-usage feedback rather than
more tuning: `ch` for both ચ and word-initial છ is a style call (che,
cho, chokro — but chhella, chhod for medial છ); `jam` now outranks
`jamva` because જામ is a real word; `ae`-style and `-ya`/`-y` final
spellings (samany vs samanya) both survive as separate groups where
humans are split. The user dictionary (Phase 4) is the real fix for
spelling taste.

## Phase 2 — web tester

Self-contained HTML, lexicon inlined as JSON, opened on the phone from
the home screen. Typing box, tappable suggestion strip, a composed-message
area with a copy button, and a debug line showing the strict and loose
keys plus match count.

Purpose is a judgement call, not a product: does this feel like how Neel
and his friends actually write? Clumsy to chat with — you type here and
paste into WhatsApp — but it answers the only question that matters
before buying a Mac.

### Phase 2 outcome (2026-09-19)

Built. `tester.html` is one 1.4 MB file: the JS port of the engine plus
the 40K-word lexicon and 86K bigrams inlined as JSON, keys computed on
load (~250 ms). One textarea is the message; the word after the last
space is what's being typed, the word before it drives the bigrams.
Tapping a chip replaces the typed word, appends a space, and records the
acceptance in localStorage so the Phase 4 user-dictionary effect can be
felt now (there is a "forget" link). After a space the strip shows
next-word predictions. Debug line: strict key, loose key, match count by
tier, and the milliseconds. Tab takes the first suggestion on a desktop
keyboard. iOS autocorrect is disabled on the box; a "⌫ word" button
deletes the last word because the iOS keyboard's backspace is per letter.

The JS port is the first port of the engine and it is exact (see
`web/test_port.js`). The Swift port should be tested the same way:
dump the Python engine's answers, compare.

Things to judge with it, in this order: (1) does the first chip after
`kem`, `su`, `mane`, `hu` feel right, (2) does typing 2–3 letters of an
ordinary word reach it, (3) do the spellings look like yours or like
Wikipedia's. Note what jars; that is the Phase 4 / tuning list.

## Phase 2b — hosted PWA (2026-09-19)

Plan change: instead of waiting for a Mac, ship the web app as an
installable PWA on free hosting and make it good enough to use daily.
Built and verified locally in Chrome; deploy is the next step.

**Hosting:** GitHub Pages from the `docs/` folder of the public repo
`neel0903/gujlish` (Pages on a private repo needs a paid plan).
**Live since 2026-09-19 at `https://neel0903.github.io/gujlish/`.**
Deploy = `python build_site.py`, commit, `git push`; Pages rebuilds in
about a minute. Verified live in Chrome: service worker active with
scope `/gujlish/`, manifest standalone, typing and prediction work.
Install on iPhone: open the URL in Safari → Share → Add to Home Screen.

First-time setup was (kept for reference; `gh auth login` first):

```bash
gh repo create gujlish --public --source . --remote origin --push
gh api -X POST repos/neel0903/gujlish/pages -f "source[branch]=main" -f "source[path]=/docs"
```

**What the app does now, beyond the tester:**

- Installable (manifest + icons), offline (service worker; hashed assets
  cached forever, `index.html` network-first so a deploy is picked up;
  an "update ready" banner only when an old worker is still active).
- Suggestion strip pinned above the on-screen keyboard via
  `visualViewport`.
- WhatsApp button (`wa.me/?text=`), Share (Web Share API), Copy.
- Personal dictionary in IndexedDB: every accepted or space-committed
  word and its pair with the previous word is learned. Words the corpus
  never had become real candidates (marked with a green dot). Boost is
  `25*min(n,3) + 10*ln(1+n)`, mirrored in `engine.py`, so a chat export
  cannot drown the corpus. Export/import as JSON; forget all.
- Learn from a WhatsApp chat export (.txt or the iPhone .zip, unzipped
  in-browser with `DecompressionStream`), per-sender selection, never
  uploaded. This is the intended fix for register: Wikipedia taught the
  words, the chat teaches how Neel and his friends spell them.
- English mixed mode (default) from FrequencyWords' top 20K, penalty 15
  against Gujlish; also Gujlish-only / English-only in settings.
- Lexicon raised to 80K surfaces; Dakshina's 10K hand-romanised
  sentences (148K aligned tokens) added as human attestations.

**Verified:** `node web/test_port.js` — 80,056/80,056 keys and 34/34
trials identical to Python, plus mixed-mode and personal-dictionary
checks; Chrome: install, typing, bigram prediction, English mixing,
settings, chat learning UI, update flow.

**Known follow-ups:** engine build on load is ~0.7 s on a PC (80K keys
computed in JS), likely 1.5–2 s on a phone — precompute keys at build
time if it feels slow. The WhatsApp export parser is untested against a
real export; the regex handles both Android and iPhone line formats on
paper. iOS PWA specifics (standalone-mode `wa.me` handoff, keyboard
strip placement) need a real iPhone to confirm.

## Phase 3 — iOS

Needs a Mac. Xcode only runs on macOS; there is no Linux path. A used M1
Mac mini around $300–400 beats cloud Mac rental within two years.

1. Plain SwiftUI app first, **not** the keyboard extension. Bundle
   `gujlish.db`, open read-only, port `phonetics.py` and `engine.py` to
   Swift. Breakpoints work here and there is no memory ceiling.
2. Then add the Keyboard Extension target plus KeyboardKit (free tier)
   for the QWERTY shell and suggestion bar. Check KeyboardKit's current
   licence — the FAQ now describes the SDK as closed-source but free to
   use in any app, which differs from the older MIT README. Their paid
   autocomplete is irrelevant; we have our own engine.

Non-negotiables in the extension:

- **Never load the lexicon into RAM.** SQLite off disk is already
  memory-mapped. Extensions die around 60 MB with no crash log — iOS just
  silently switches the user back to their previous keyboard mid-sentence.
- **Do not request Allow Full Access.** Fully offline, so it isn't needed.
  Better privacy story, smoother review.
- **Mixed mode over a hard toggle.** If the prefix strongly matches a
  common English word, show English; else show Gujlish. Keeps "John" safe
  without touching the switch. Manual toggle icon on the suggestion bar
  as the override.
- **Free Apple ID works** for personal use: 7-day expiry, re-sign from
  Xcode, 3 apps max. The one real limitation is no App Groups entitlement,
  so put settings inside the keyboard itself and keep the user dictionary
  in the extension's own container. KeyboardKit's demo does exactly this.
  The $99/year only becomes worth it when weekly re-signing gets old.

## Phase 4 — user dictionary

Separate writable SQLite. Log accepted surfaces and bigrams, weight them
at 25 points per acceptance in the ranker (already wired in `engine.py`
via `accept()`). Within two weeks of daily use this should beat the corpus
frequencies for Neel's own vocabulary, because it learns his spellings
rather than Wikipedia's.

## Phase 5 — Android

Same `gujlish.db`, port the ~300 lines of query logic to Kotlin, thin
`InputMethodService`. Android Studio runs natively on Linux, free, with
indefinite USB install — so if a spare Android device is around, this is
the zero-cost path to a *real* keyboard while the Mac decision waits.
Android can also read the host app package from `EditorInfo`, which makes
genuine per-app auto-toggle possible. iOS cannot do this.

---

## Known limits, recorded so they aren't rediscovered

- No API on iOS or Android lets a third party add suggestions to Apple's
  keyboard or to Gboard. Shipping your own keyboard is the only route.
- Keyboards cannot see who you are messaging. Per-contact switching is
  impossible on both platforms; per-app is Android-only.
- Dropped and inserted vowels (`mjama` for `majama`, `dikaro` for `dikro`)
  do not collapse on either key by design — they are typos and schwa
  variation, not sound variation. The one-edit fuzzy fallback in
  `engine.py` handles them, and it only fires for input of 4+ characters
  to avoid polluting short prefixes.
- Six phonetic keys in the seed lexicon carry more than one word
  (`ke`: ke/kem, `te`: te/tem, `na`: na/naam). This is correct — both
  candidates surface, ranked by frequency.
- Speech input is deferred. iOS keyboard extensions cannot use the
  microphone cleanly; it would have to live in the container app.
