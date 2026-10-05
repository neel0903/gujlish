"""
Inference: python3 correct.py "kem cho majama su thyu"

Splits the message into runs of letters and spaces (punctuation, digits
and emoji pass through untouched), lowercases, corrects each run, and
restores a leading capital. Runs longer than 64 characters are cut at
a space. Uses the int8 ONNX graphs when present (fast, and the same
artifact the phone runs), else the PyTorch checkpoint.

Every change goes through gate.Gate (word-level plausibility + a 40%
edit-distance cap), so names and English words are left alone.
"""
import os
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gate import Gate  # noqa: E402
from model import BOS, EOS, MAX_LEN, MAX_POS, decode, encode  # noqa: E402

RUN_RE = re.compile(r"[A-Za-z]+(?: +[A-Za-z]+)*")
MODELS = os.path.join(HERE, "models")


def chunks(run, limit=MAX_LEN):
    out, cur = [], ""
    for w in run.split(" "):
        if not cur:
            cur = w
        elif len(cur) + 1 + len(w) <= limit:
            cur += " " + w
        else:
            out.append(cur)
            cur = w
    if cur:
        out.append(cur)
    return out


class OrtBackend:
    def __init__(self, enc, dec, threads=2):
        import onnxruntime as ort
        so = ort.SessionOptions()
        so.intra_op_num_threads = threads
        so.log_severity_level = 3
        self.enc = ort.InferenceSession(enc, so)
        self.dec = ort.InferenceSession(dec, so)
        self.name = "onnx-int8" if "int8" in enc else "onnx"

    def run(self, texts):
        import numpy as np
        out = []
        for t in texts:
            ids = encode(t)[:MAX_LEN]
            if not ids:
                out.append("")
                continue
            memory = self.enc.run(None, {"src": np.array([ids], dtype=np.int32)})[0]
            ys = [BOS]
            for _ in range(MAX_POS - 1):
                logits = self.dec.run(None, {"tgt": np.array([ys], dtype=np.int32),
                                             "memory": memory})[0]
                nxt = int(logits[0].argmax())
                if nxt == EOS:
                    break
                ys.append(nxt)
            out.append(decode(ys[1:]))
        return out


class TorchBackend:
    def __init__(self, path, device="cpu"):
        import torch
        from model import load
        torch.set_num_threads(max(1, (os.cpu_count() or 2) // 2))
        self.device = torch.device(device)
        self.model = load(path, self.device)
        self.name = "torch"

    def run(self, texts):
        from model import batch_encode
        out = []
        for i in range(0, len(texts), 256):
            src = batch_encode(texts[i:i + 256], self.device)
            out += [decode(r) for r in self.model.greedy(src)]
        return out


class Corrector:
    def __init__(self, path=None, backend="auto", gate=True):
        enc = os.path.join(MODELS, "encoder_int8.onnx")
        dec = os.path.join(MODELS, "decoder_int8.onnx")
        if backend == "auto":
            backend = "ort" if (path is None and os.path.exists(enc) and os.path.exists(dec)) else "torch"
        if backend == "ort":
            self.backend = OrtBackend(enc, dec)
        else:
            self.backend = TorchBackend(path or os.path.join(MODELS, "gujlish_corrector.pt"))
        self.gate = Gate() if gate else None

    def fix_batch(self, texts):
        pieces, where = [], []
        for ti, text in enumerate(texts):
            for m in RUN_RE.finditer(text):
                for ch in chunks(m.group(0)):
                    pieces.append(ch)
                    where.append((ti, m.start(), m.end()))
        outs = self.backend.run([p.lower() for p in pieces])
        fixed = {}
        for key, src, out in zip(where, pieces, outs):
            out = self.gate.apply(src, out) if self.gate else out
            fixed.setdefault(key, []).append(out)
        results = []
        for ti, text in enumerate(texts):
            res, last = [], 0
            for m in RUN_RE.finditer(text):
                orig = m.group(0)
                new = " ".join(fixed.get((ti, m.start(), m.end()), [orig]))
                if orig[:1].isupper():
                    new = new[:1].upper() + new[1:]
                if orig.isupper() and len(orig) > 1:
                    new = new.upper()
                res.append(text[last:m.start()])
                res.append(new)
                last = m.end()
            res.append(text[last:])
            results.append("".join(res))
        return results

    def fix(self, text):
        return self.fix_batch([text])[0]


if __name__ == "__main__":
    text = " ".join(sys.argv[1:]) or "kem cho majama su thyu"
    c = Corrector()
    c.fix("warm up")
    t = time.time()
    out = c.fix(text)
    ms = (time.time() - t) * 1000
    print(out)
    print(f"({ms:.0f} ms, {c.backend.name})", file=sys.stderr)
