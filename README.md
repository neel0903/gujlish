# Gujlish

Predictive text for romanised Gujarati ("Gujlish"): you type `tha`, it
suggests `thayu`. Output stays in Latin letters. Runs entirely on the
device; nothing is sent anywhere.

The hosted app is a PWA: open it in Safari on an iPhone, Share → Add to
Home Screen, and it works offline. `BUILD_PLAN.md` is the running brief.

## Layout

| | |
|---|---|
| `phonetics.py`, `engine.py` | Reference implementation of the phonetic keys and the ranker |
| `translit.py`, `build_lexicon.py` | Corpus pipeline: Gujarati Wikipedia counts joined to Dakshina and Aksharantar romanisations |
| `lexicon.tsv`, `lexicon.bigrams.tsv` | The lexicon the pipeline produced |
| `web/` | The app: `gujlish.js` (engine port), `app.js`, `index.html` |
| `build_site.py` | Builds `docs/`, which GitHub Pages serves |
| `docs/` | Built site. Do not edit by hand |

## Build

```bash
python build_lexicon.py        # needs the corpora under data/, see data/SOURCES.md
python build_db.py lexicon.tsv
python build_site.py
node web/test_port.js
```

## Data and licences

Code is MIT. The lexicon is derived data:

- Gujarati Wikipedia — CC BY-SA 4.0
- [Dakshina](https://github.com/google-research-datasets/dakshina) — CC BY-SA 4.0
- [Aksharantar](https://huggingface.co/datasets/ai4bharat/Aksharantar) — CC BY (manual) / CC0 (mined)
- [FrequencyWords](https://github.com/hermitdave/FrequencyWords) English list — MIT

`lexicon.tsv` and `lexicon.bigrams.tsv` are therefore CC BY-SA 4.0.
Chat exports used for personal learning never leave the phone and are
never committed here.
