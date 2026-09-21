"""
Build the hosted PWA into docs/ (GitHub Pages serves that folder).

    python build_site.py
    node web/test_port.js       # port still exact?
    node web/test_grammar.js    # grammar rules and golden sentences
    git add -A; git commit; git push   # deploys

What goes in:
    web/index.html, app.css, app.js, gujlish.js, grammar.js, reverse.js, sw_template.js
    lexicon.tsv + .bigrams.tsv + .trigrams.tsv + .native.tsv   (the Gujlish lexicon)
    data/english/en_50k.txt                                    (FrequencyWords, MIT)

Every asset except index.html and sw.js gets a content hash in its
name, so the service worker can cache them forever and a rebuild only
re-downloads what changed. Phonetic keys are precomputed here so the
phone parses JSON instead of running 160K key computations on load.
The surface -> script map is its own file, fetched the first time the
script preview is shown.
"""
import hashlib
import json
import math
import os
import re
import shutil
import time

from build_tester import load, expected
from phonetics import strict_key, loose_key

WEB = "web"
OUT = "docs"
ENGLISH_SRC = os.path.join("data", "english", "en_50k.txt")
ENGLISH_TOP = 20000
NATIVE_SRC = "lexicon.native.tsv"


def load_english():
    if not os.path.exists(ENGLISH_SRC):
        # No corpus (fresh clone): use the committed, already-scaled copy.
        with open("english.tsv", encoding="utf-8") as fh:
            return [[w, int(f)] for w, f in (l.rstrip("\n").split("\t") for l in fh if "\t" in l)]
    rows = []
    with open(ENGLISH_SRC, encoding="utf-8") as fh:
        for line in fh:
            p = line.split()
            if len(p) != 2:
                continue
            w, c = p[0], int(p[1])
            if not re.fullmatch(r"[a-z]+", w):
                continue
            if len(w) == 1 and w not in ("a", "i"):
                continue
            rows.append((w, c))
            if len(rows) >= ENGLISH_TOP:
                break
    c_max = rows[0][1]
    # Same log scale as the Gujlish lexicon so the two compete fairly.
    scaled = [[w, max(1, round(100 * math.log1p(c) / math.log1p(c_max)))] for w, c in rows]
    # Committed copy so build_db.py (and the iOS build) need no corpus.
    with open("english.tsv", "w", encoding="utf-8") as fh:
        for w, f in scaled:
            fh.write(f"{w}\t{f}\n")
    return scaled


def load_native(words):
    keep = {s for s, _ in words}
    out = {}
    if os.path.exists(NATIVE_SRC):
        with open(NATIVE_SRC, encoding="utf-8") as fh:
            for line in fh:
                p = line.rstrip("\n").split("\t")
                if len(p) == 2 and p[0] in keep:
                    out[p[0]] = p[1]
    return out


def hashed(name, content):
    h = hashlib.md5(content.encode("utf-8")).hexdigest()[:8]
    stem, ext = os.path.splitext(name)
    return f"{stem}.{h}{ext}"


def make_icons(out_dir):
    from PIL import Image, ImageDraw, ImageFont
    os.makedirs(out_dir, exist_ok=True)
    font_path = None
    for cand in (r"C:\Windows\Fonts\segoeuib.ttf", r"C:\Windows\Fonts\arialbd.ttf",
                 "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
        if os.path.exists(cand):
            font_path = cand
            break

    def draw(size, pad_frac, radius_frac, path):
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        pad = int(size * pad_frac)
        d.rounded_rectangle([pad, pad, size - pad, size - pad], radius=int(size * radius_frac), fill=(10, 102, 194, 255))
        text = "Gu"
        font = ImageFont.truetype(font_path, int(size * 0.46)) if font_path else ImageFont.load_default()
        box = d.textbbox((0, 0), text, font=font)
        w, h = box[2] - box[0], box[3] - box[1]
        d.text(((size - w) / 2 - box[0], (size - h) / 2 - box[1] - size * 0.02), text, font=font, fill=(255, 255, 255, 255))
        img.save(path, "PNG")

    draw(512, 0.0, 0.22, os.path.join(out_dir, "icon-512.png"))
    draw(192, 0.0, 0.22, os.path.join(out_dir, "icon-192.png"))
    draw(180, 0.0, 0.0, os.path.join(out_dir, "apple-touch-icon.png"))   # iOS rounds it
    draw(512, 0.10, 0.0, os.path.join(out_dir, "icon-maskable-512.png"))  # full-bleed, safe zone
    img = Image.open(os.path.join(out_dir, "icon-maskable-512.png")).convert("RGBA")
    bg = Image.new("RGBA", img.size, (10, 102, 194, 255))
    bg.alpha_composite(img)
    bg.save(os.path.join(out_dir, "icon-maskable-512.png"), "PNG")


def read(name):
    with open(os.path.join(WEB, name), encoding="utf-8") as fh:
        return fh.read()


def main():
    words, bigrams, trigrams, n_bigrams, n_trigrams = load()
    english = load_english()
    native = load_native(words)

    data = {
        "words": [[s, f, strict_key(s, True), loose_key(s, True)] for s, f in words],
        "bigrams": bigrams, "trigrams": trigrams,
        "bigramCount": n_bigrams, "trigramCount": n_trigrams,
    }
    lexicon_js = "var GUJLISH_DATA=" + json.dumps(data, separators=(",", ":")) + ";\n"
    english_js = "var GUJLISH_ENGLISH=" + json.dumps(english, separators=(",", ":")) + ";\n"
    native_js = "window.GUJLISH_NATIVE=" + json.dumps(native, separators=(",", ":"), ensure_ascii=False) + ";\n"
    engine_js, grammar_js, reverse_js = read("gujlish.js"), read("grammar.js"), read("reverse.js")
    app_js, app_css = read("app.js"), read("app.css")

    version = time.strftime("%Y-%m-%d") + "." + hashlib.md5(
        (lexicon_js + english_js + native_js + engine_js + grammar_js + reverse_js + app_js + app_css
         ).encode("utf-8")).hexdigest()[:6]
    native_name = hashed("native.js", native_js)
    app_js = ("window.GUJLISH_VERSION=" + json.dumps(version) + ";"
              "window.GUJLISH_FILES=" + json.dumps({"native": native_name}) + ";\n" + app_js)

    names = {
        "LEXICON_JS": (hashed("lexicon.js", lexicon_js), lexicon_js),
        "ENGLISH_JS": (hashed("english.js", english_js), english_js),
        "GUJLISH_JS": (hashed("gujlish.js", engine_js), engine_js),
        "GRAMMAR_JS": (hashed("grammar.js", grammar_js), grammar_js),
        "REVERSE_JS": (hashed("reverse.js", reverse_js), reverse_js),
        "APP_JS": (hashed("app.js", app_js), app_js),
        "APP_CSS": (hashed("app.css", app_css), app_css),
        "NATIVE_JS": (native_name, native_js),
    }

    # Clear the contents rather than the folder: a dev server may have
    # it open as its working directory.
    os.makedirs(OUT, exist_ok=True)
    for entry in os.listdir(OUT):
        p = os.path.join(OUT, entry)
        shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
    for _, (name, content) in names.items():
        with open(os.path.join(OUT, name), "w", encoding="utf-8") as fh:
            fh.write(content)

    html = read("index.html")
    for key, (name, _) in names.items():
        html = html.replace("{{" + key + "}}", name)
    with open(os.path.join(OUT, "index.html"), "w", encoding="utf-8") as fh:
        fh.write(html)

    manifest = {
        "name": "Gujlish", "short_name": "Gujlish",
        "description": "Predictive text for romanised Gujarati. Works offline.",
        "start_url": "./", "scope": "./", "display": "standalone",
        "background_color": "#f5f5f7", "theme_color": "#0a66c2",
        "icons": [
            {"src": "icons/icon-192.png", "sizes": "192x192", "type": "image/png"},
            {"src": "icons/icon-512.png", "sizes": "512x512", "type": "image/png"},
            {"src": "icons/icon-maskable-512.png", "sizes": "512x512", "type": "image/png", "purpose": "maskable"},
        ],
    }
    with open(os.path.join(OUT, "manifest.webmanifest"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, indent=1)

    make_icons(os.path.join(OUT, "icons"))

    precache = ["./", "./index.html", "./manifest.webmanifest",
                "./icons/icon-192.png", "./icons/icon-512.png", "./icons/apple-touch-icon.png",
                "./icons/icon-maskable-512.png"] + ["./" + name for name, _ in names.values()]
    sw = read("sw_template.js").replace("__VERSION__", version).replace("__PRECACHE__", json.dumps(precache))
    with open(os.path.join(OUT, "sw.js"), "w", encoding="utf-8") as fh:
        fh.write(sw)
    open(os.path.join(OUT, ".nojekyll"), "w").close()

    # For the node tests.
    with open(os.path.join(WEB, "lexicon.js"), "w", encoding="utf-8") as fh:
        fh.write(lexicon_js)
    with open(os.path.join(WEB, "english.js"), "w", encoding="utf-8") as fh:
        fh.write(english_js)
    with open(os.path.join(WEB, "native.js"), "w", encoding="utf-8") as fh:
        fh.write(native_js)
    with open(os.path.join(WEB, "expected.json"), "w", encoding="utf-8") as fh:
        json.dump(expected(words), fh, ensure_ascii=False)

    total = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(OUT) for f in fs)
    print(f"docs/: version {version}, {len(words)} words, {n_bigrams} bigrams, {n_trigrams} trigrams, "
          f"{len(native)} script forms, {len(english)} English words, {total / 1024 / 1024:.1f} MB total")


if __name__ == "__main__":
    main()
