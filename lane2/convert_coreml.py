"""
Convert the corrector to Core ML for the iOS keyboard: two ML programs
(encoder, decoder) with flexible sequence lengths, fp16 weights.

    python3 convert_coreml.py        # writes models/GujlishEncoder.mlpackage, GujlishDecoder.mlpackage

Then checks that greedy decoding through Core ML matches PyTorch.
"""
import os
import random
import sys
import time

import coremltools as ct
import numpy as np
import torch

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from export import Decoder, Encoder, torch_greedy  # noqa: E402
from model import BOS, EOS, MAX_POS, decode, encode, load  # noqa: E402
from train import load_pairs  # noqa: E402


def convert(model_path, out_dir):
    m = load(model_path, "cpu").eval()
    src = torch.tensor([encode("kem cho majama")], dtype=torch.int32)
    tgt = torch.tensor([[BOS] + encode("kem ch")], dtype=torch.int32)
    with torch.no_grad():
        memory = m.encode(src.long())
        enc_ts = torch.jit.trace(Encoder(m).eval(), (src,))
        dec_ts = torch.jit.trace(Decoder(m).eval(), (tgt, memory))
    S = ct.RangeDim(lower_bound=1, upper_bound=MAX_POS, default=16)
    T = ct.RangeDim(lower_bound=1, upper_bound=MAX_POS, default=8)
    common = dict(convert_to="mlprogram", minimum_deployment_target=ct.target.iOS17,
                  compute_precision=ct.precision.FLOAT16, compute_units=ct.ComputeUnit.CPU_AND_NE)
    enc = ct.convert(enc_ts, inputs=[ct.TensorType(name="src", shape=(1, S), dtype=np.int32)],
                     outputs=[ct.TensorType(name="memory")], **common)
    dec = ct.convert(dec_ts, inputs=[ct.TensorType(name="tgt", shape=(1, T), dtype=np.int32),
                                     ct.TensorType(name="memory", shape=(1, S, m.d_model), dtype=np.float32)],
                     outputs=[ct.TensorType(name="logits")], **common)
    for mlm, name in ((enc, "GujlishEncoder"), (dec, "GujlishDecoder")):
        mlm.short_description = "Gujlish sentence corrector (" + name[7:].lower() + ")"
        mlm.save(os.path.join(out_dir, name + ".mlpackage"))
    return m, enc, dec


def coreml_greedy(enc, dec, text, max_len=MAX_POS):
    ids = encode(text)[:max_len - 2]
    memory = enc.predict({"src": np.array([ids], dtype=np.int32)})["memory"].astype(np.float32)
    ys = [BOS]
    for _ in range(max_len - 1):
        logits = dec.predict({"tgt": np.array([ys], dtype=np.int32), "memory": memory})["logits"]
        nxt = int(np.asarray(logits)[0].argmax())
        if nxt == EOS:
            break
        ys.append(nxt)
    return decode(ys[1:])


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.path.join(HERE, "models", "gujlish_corrector.pt"))
    ap.add_argument("--out", default=os.path.join(HERE, "models"))
    args = ap.parse_args()
    model_path, out_dir = args.model, args.out
    m, _, _ = convert(model_path, out_dir)
    # Check the saved packages, not the in-memory conversions (those predicted differently).
    # CPU only: the strictest path (the keyboard extension runs on CPU/NE).
    enc = ct.models.MLModel(os.path.join(out_dir, "GujlishEncoder.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    dec = ct.models.MLModel(os.path.join(out_dir, "GujlishDecoder.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
    pairs = load_pairs(os.path.join(HERE, "data", "pairs_test.jsonl"))
    random.Random(1).shuffle(pairs)
    tests = [s for s, _ in pairs[:30]]
    same, t = 0, time.time()
    diffs = []
    for s in tests:
        a, b = torch_greedy(m, s), coreml_greedy(enc, dec, s)
        same += a == b
        if a != b:
            diffs.append((s, a, b))
    ms = (time.time() - t) * 1000 / len(tests)
    print(f"coreml fp16: {same}/{len(tests)} identical to PyTorch, {ms:.0f} ms/sentence (incl. torch)")
    for s, a, b in diffs[:5]:
        print(f"   {s!r}: torch {a!r}  coreml {b!r}")
    size = sum(os.path.getsize(os.path.join(dp, f)) for name in ("GujlishEncoder", "GujlishDecoder")
               for dp, _, fs in os.walk(os.path.join(out_dir, name + ".mlpackage")) for f in fs)
    print(f"mlpackage total {size/1e6:.2f} MB")
    sys.stdout.flush()
    os._exit(0)


if __name__ == "__main__":
    main()
