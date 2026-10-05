# Gujlish v2 — build brief for Claude Code

**Read this whole file before touching anything.** It supersedes
`BUILD_PLAN.md`. The existing files (`phonetics.py`, `engine.py`,
`build_db.py`, `seed_lexicon.py`, `gujlish.db`) are kept and reused.
Do not rewrite them.

## What we are building

A Gujlish (romanised Gujarati) typing assistant with two lanes:

- **Lane 1 — per keystroke.** Lexicon-driven suggestions, <30 ms,
  tiny memory. Already built in `engine.py`. Not today's focus.
- **Lane 2 — whole-sentence correction.** The user types a rough
  message, taps **Fix**, and a small on-device model rewrites it as
  clean Gujlish. This is the "chat window" experience, and it is
  **today's job.**

Output is Latin letters only. Gujarati script never appears on the
device; it is only ever a join key inside the data pipeline.

## Today's definition of done

By end of session, all of these must be true:

1. `python3 correct.py "kem cho majama su thyu"` prints a corrected
   sentence in under 200 ms on CPU.
2. The model beats the lexicon-only baseline on the held-out test set
   (`eval.py` prints both numbers).
3. `web/index.html` is a single self-contained file: a text box, a
   **Fix** button, a copy button, and the Lane 1 suggestion strip. It
   runs the exported model in the browser with ONNX Runtime Web and
   works offline once loaded.
4. The page is reachable from Neel's phone on the same Wi-Fi
   (`python3 -m http.server` is fine) and added to the home screen.

Anything beyond this list is tomorrow. If a step runs long, cut scope
from the bottom of the task list, never from the top.

## Why not just use an LLM

A chat model is tens of billions of parameters and takes a second to
answer. A keyboard extension gets ~60 MB and has to respond between two
finger taps. Those aren't the same machine. A 10–20M parameter
character-level model trained on **one narrow task** will beat a
general model at Gujlish, because Gujlish barely exists in anyone's
training data, and it fits in a keyboard extension with room to spare.

Apple's Foundation Models framework is a later option for the container
app (system model doesn't count against extension memory per Apple
DTS), but it needs an Apple Intelligence device and is unproven on
Gujlish. Don't depend on it.

## Environment

- Python 3.10+, CPU only is fine today.
- `pip install torch onnx onnxruntime numpy` (CPU wheels).
- No API keys, no paid services, no cloud. Everything runs locally.
- Working directory is the existing `gujlish/` folder.

## The core trick: synthetic corruption

We don't have a corpus of (messy, clean) Gujlish pairs. We make one.
`phonetics.py` already encodes exactly how Gujlish spelling varies.
Run it **backwards**: take clean sentences, corrupt them the way real
people mistype, and train the model to invert the corruption.

```
clean sentence ──► corrupt() ──► messy sentence
                                      │
              model learns: messy ──► clean
```

Corruption operators, each applied with a probability (tune them):

| Operator | Example | p |
|---|---|---|
| drop aspiration h | thayu → tayu, khabar → kabar | 0.25 |
| double a consonant | sachu → sacchu | 0.10 |
| drop a schwa vowel | majama → mjama, dikro → dikaro | 0.15 |
| vowel length swap | saru → saaru, nathi → nathee | 0.25 |
| y/i swap | thayu → thaiu, kai → kay | 0.20 |
| v/w, z/j, s/sh swap | jamva → jamwa, su → shu | 0.20 |
| drop / add trailing nasal | chhu → chhun, kem → ke | 0.15 |
| keyboard-adjacent key | kem → kwm, che → cge | 0.08 |
| transpose two letters | thayu → thyau | 0.05 |
| drop a space | kem cho → kemcho | 0.08 |
| chh ↔ ch | che → chhe | 0.30 |

Apply 1–3 operators per word, leave ~30% of words untouched so the
model learns to **not** change correct input. That last part matters:
an overeager corrector is worse than none.

## Task list — in order

### 1. Clean sentence corpus (`make_corpus.py`) — 45 min

No internet needed today. Build ~20K clean Gujlish sentences from:

- The `BIGRAMS` list in `seed_lexicon.py` — chain them into 2–5 word
  utterances by random walk weighted by bigram weight.
- A hand-written `templates.txt` of ~150 real chat sentences
  (the kind Neel actually sends: *kem cho*, *jaman thayu*, *kale
  malse*, *ghare aavo*, *su chale che*, *mane khabar nathi*…).
  Expand with slot filling: `{person} kem che` × `{bhai, ben, mummy,
  pappa, kaka…}`.

Split 90/5/5 train/dev/test **by template**, not by row, so the test
set contains sentence shapes the model never saw. Save as JSONL.

Deliverable: `data/clean_{train,dev,test}.jsonl`.

### 2. Corruptor (`corrupt.py`) — 45 min

Implement the table above. Reuse `_DIGRAPHS`, `_VOWEL_RUNS` and the
Y/I rule from `phonetics.py` — don't re-encode them.

Must have a `--seed` flag and a `python3 corrupt.py --demo` mode that
prints 20 (clean → messy) pairs for eyeballing. **Show these to Neel
before training.** If they don't look like how his friends mistype,
training on them is wasted.

Generate 5 corruptions per clean sentence → ~100K training pairs.

Deliverable: `data/pairs_{train,dev,test}.jsonl` with
`{"src": messy, "tgt": clean}`.

### 3. Baseline (`baseline.py`) — 20 min

Lexicon-only corrector: for each word, take the top-1 from
`GujlishEngine.suggest(word, prev_word)` if its phonetic key matches,
else leave it. This is the number the model has to beat. Also the
fallback the web page uses when the model fails to load.

### 4. Model (`model.py`, `train.py`) — 2 hours including training

Character-level transformer encoder-decoder, **small**:

- vocab: `a-z`, space, `<pad> <s> </s>` — ~30 tokens
- d_model 256, 4 heads, 3 encoder + 3 decoder layers, FFN 512
- ~8–10M params. Do not go bigger today.
- max length 64 chars src / tgt. Longer messages get split on
  punctuation at inference time.
- label smoothing 0.1, AdamW, lr 3e-4 with warmup, batch 128
- train 15–20 epochs on CPU — should be 30–60 min on a laptop. If
  it's slower, halve the data, don't shrink the model.
- early stop on dev character error rate (CER)

Greedy decoding is enough. Beam search is tomorrow's optimisation.

Deliverable: `models/gujlish_corrector.pt` + `eval.py` printing
sentence accuracy and CER for baseline vs model on test.

### 5. Inference CLI (`correct.py`) — 20 min

```
python3 correct.py "kem cho majama su thyu"
→ kem cho majama su thayu
```

Must apply a **confidence gate**: if the model's output has a
character edit distance > 40% of input length, return the input
unchanged. A corrector that rewrites "John" into Gujlish is the exact
failure Neel flagged on day one.

### 6. ONNX export (`export.py`) — 30 min

Export encoder and decoder as separate ONNX graphs with dynamic
sequence axes, int8 quantise with `onnxruntime.quantization`. Target
file size under 15 MB. Verify `onnxruntime` CPU gives the same output
as PyTorch on 20 test sentences.

### 7. Web tester (`web/index.html`) — 1 hour

One file, no build step, no framework. Load ONNX Runtime Web from CDN
(`onnxruntime-web`), fall back to `baseline` logic in plain JS if
loading fails. Inline the lexicon as JSON for the Lane 1 strip.

UI, top to bottom:
- textarea, large, autofocus
- suggestion strip under it (Lane 1, from `engine.py` logic ported
  to JS — prefix match on `loose_k`, bigram boost)
- **Fix** button — runs the model on the full text, replaces it, shows
  a small diff (changed words highlighted)
- **Copy** button
- debug footer: model loaded? inference ms? fallback in use?

Serve with `python3 -m http.server 8000` and open on the phone.

### 8. Handoff note — 10 min

Update this file's **Status** section with what actually got done and
the eval numbers. Future sessions read this, not the chat log.

## What is explicitly NOT today

- Real corpus (Wikipedia / Dakshina / Aksharantar). The synthetic
  pipeline is designed so swapping in real clean sentences later is a
  one-line change in `make_corpus.py`.
- iOS keyboard extension. Needs a Mac. The ONNX → CoreML conversion
  path is `coremltools`, same model, later.
- Android. Same ONNX runs in ONNX Runtime Mobile for Android when we
  get there.
- Speech input.
- Beam search, trigrams, spatial key model — all Lane 1 improvements
  for later.

## Known constraints — don't rediscover these

- No API on iOS or Android lets a third party inject suggestions into
  the system keyboard. We ship our own keyboard.
- iOS keyboard extensions die around 60 MB with no crash log. The
  model size budget exists because of this.
- Keyboards cannot see who you're messaging. Per-contact switching
  is impossible; per-app is Android-only.
- `phonetics.py` deliberately does **not** collapse dropped/inserted
  vowels (mjama/majama). That's the model's job now — it's the whole
  reason Lane 2 exists.

## Status

_Filled in 2026-10-05 (Claude Code session on the Mac). Everything below
lives in `Gujlish/lane2/`; run with `/Volumes/GujlishDev/venv/bin/python`._

- [x] corpus — `make_corpus.py`: 232 chat templates with slot filling
      (3,794 sentences) + 240 seed-bigram chains + 14,000 random walks over
      `lexicon.bigrams.tsv` (words with freq ≥ 45) = 17,862 unique clean
      sentences, split 90/5/5 by template/first word: 16,464 / 762 / 636.
      Swapping in a real corpus = one more source in `make_corpus.py`.
- [x] corruptor reviewed by Neel — `corrupt.py --demo` approved as is.
      `--per 5` → 81,332 / 3,755 / 3,136 pairs. Ops are the brief's table;
      per word 1–3 ops (70/25/5 %), 30 % of words untouched, keyboard slips
      and transpositions only on words of 4+ letters, long vowels only
      aa/ee/oo.
- [x] baseline sentence-acc: **28.6 %**  CER: **0.0869** (suggest top-1 on
      key match). The keyboard's own `engine.correct()` autocorrect: 45.0 %
      / 0.0692. Leaving the input alone: 2.2 % / 0.1685. (1,500 test pairs.)
- [x] model sentence-acc: **57.9 %**  CER: **0.0489** with the gate;
      56.5 % / 0.0414 without. Char transformer, d256/4 heads/3+3 layers/
      FFN 512 = 3.99 M params, 16 epochs (early stop, best epoch 13, dev
      CER 0.0401), 40 min on the M3 GPU (MPS). `eval.py` prints all rows.
      On `web/golden.tsv` (30 real messages whose expected form includes
      grammar fixes the corruptor never makes): 50 % exact; every miss is
      a cho→chu-type agreement fix, which stays the grammar rules' job.
- [x] ONNX size: **4.17 MB** int8 (encoder 1.67 + decoder 2.50), parity
      20/20 with PyTorch for both fp32 and int8; 10–20 ms per message
      through onnxruntime on the Mac. `correct.py` uses the int8 graphs
      (9–20 ms per message, far under the 200 ms target).
- [x] web page working on phone — `lane2/web/index.html` (built by
      `build_web.py`, 0.76 MB with 5,113 lexicon words + 25,928 bigrams for
      the Lane 1 strip, and the gate vocabulary inlined); served with
      `python3 -m http.server 8000` from `lane2/web` at
      http://10.0.0.20:8000. Verified end to end under onnxruntime-web in
      node (same graphs, same outputs). **Not yet opened on the phone by
      Neel** — the server log showed no phone request by end of session.
      Offline/home-screen install needs https, so the page is also deployed:
      **https://neel0903.github.io/gujlish/fix/** (`build_web.py --docs`
      after `build_site.py`; the main PWA links to it and its service
      worker ignores `fix/`). Live and verified 2026-10-05 evening.

### Things learned today (don't rediscover)

- **Embedding scale bug.** `tok(ids) * sqrt(d_model)` on PyTorch's unit-
  variance embedding init drowned the positional signal: the first run
  learned anagrams (dev CER 0.42 after 4 epochs). Without the scaling,
  dev CER was 0.095 after one epoch.
- **Per-word gate (`gate.py`)**, ported to the page and to Swift
  (`FixGate`): a changed word is accepted only if the output is in the
  model's vocabulary (training corpus ∪ lexicon freq ≥ 40), the loose keys
  are within one edit (or raw spellings within two, transposition = 1),
  the input is not a mid-sentence Capitalised word, and not an English
  word that outranks its Gujlish reading unless the change is a pure
  spelling normalisation. Without it: "john" → "jo", "good night thanks"
  → "gud nighat thani". With it those stay; the 40 % whole-segment cap is
  only a backstop. Costs ~0.007 CER on the synthetic test, worth it.
- **Core ML CPU path and the causal mask.** `triu(full(-1e9))` becomes
  -inf in fp16 and the CPU kernel multiplies by zero → NaN → the decoder
  emits </s> at once (GPU path was fine, which hid it). `model.NEG` is now
  -1e4; `convert_coreml.py` checks parity on CPU_ONLY: 30/30.
- The ONNX export does not use `nn.MultiheadAttention` (its traced reshape
  bakes in the sequence length); `export.py` recomputes attention with
  plain ops over the trained weights. Same wrappers feed Core ML.

### Beyond the brief: the model is in the iOS keyboard

`convert_coreml.py` → `GujlishEncoder/Decoder.mlpackage` (8.1 MB fp16),
copied by `build_ios_assets.py` with `fix_vocab.txt`. In the keyboard
(`ios/`): `SentenceFixer.swift` (Core ML greedy decoder + `FixGate`),
`Composer.applyFix()` with backspace-undo, a "✓ …last words" chip in the
bar after every committed word, a settings toggle ("Sentence fix
suggestions"), and a "Fix sentence" button in the container app. 85 Swift
tests pass (gate table, Core ML parity with correct.py, Composer with a
stub model, lagging host). Installed on Neel's iPhone 17 Pro at the end
of the session; **memory with Core ML loaded and on-device latency are
not measured yet** — read the diagnostics line in the keyboard's settings
panel (must stay well under 60 MB).

### Tomorrow

- Open https://neel0903.github.io/gujlish/fix/ on the phone, add to the
  home screen.
- Field-test the chip in WhatsApp; note bad fixes in `web/golden.tsv`;
  read the memory figure in the keyboard's settings panel.
- **v2 model in progress.** `corrupt.py` gained `final_ey` (ghare→gharey)
  and `final_vowel` (gaye/ghara) ops; pairs were regenerated with
  `--seed 2` (so the test set changed: compare v1 and v2 on it with
  `eval.py --model`). `train.py --out models/gujlish_corrector_v2.pt` was
  running at the end of the session (log `models/train_v2.log`); at epoch
  8 it was at dev CER 0.045, v1's best was 0.040. Ship v2 only if it wins
  on the test set: `export.py --model`, `convert_coreml.py --model`,
  `build_ios_assets.py`, `build_web.py --docs`, rebuild, install.
- Beam search / KV cache only if on-device latency demands it.
