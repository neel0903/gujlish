"""
Export the corrector to ONNX (encoder + decoder graphs), int8-quantise,
and verify ONNX Runtime matches PyTorch greedy decoding.

    python3 export.py            # writes models/encoder.onnx, decoder.onnx (+ _int8)

Graphs take int32 ids with batch 1 and no padding, so no masks are
needed at inference; the causal mask is built inside the decoder graph.
"""
import argparse
import json
import os
import random
import sys
import time

import numpy as np
import onnx
import torch
import onnxruntime as ort
from onnxruntime.quantization import QuantType, quantize_dynamic

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import BOS, EOS, MAX_POS, VOCAB, decode, encode, load  # noqa: E402
from train import load_pairs  # noqa: E402


import math

import torch.nn.functional as F

from model import NEG


# nn.MultiheadAttention's fast path bakes the traced sequence length into
# its reshapes, so the graphs below recompute the same maths with plain
# ops over the trained weights. Batch is fixed at 1; sequence axes stay
# dynamic. Parity with the PyTorch model is checked in main().
def attention(mha, q_in, kv_in, mask=None):
    d, h = mha.embed_dim, mha.num_heads
    hd = d // h
    W, b = mha.in_proj_weight, mha.in_proj_bias
    q = F.linear(q_in, W[:d], b[:d])
    k = F.linear(kv_in, W[d:2 * d], b[d:2 * d])
    v = F.linear(kv_in, W[2 * d:], b[2 * d:])
    q = q.view(1, -1, h, hd).transpose(1, 2)
    k = k.view(1, -1, h, hd).transpose(1, 2)
    v = v.view(1, -1, h, hd).transpose(1, 2)
    scores = torch.matmul(q, k.transpose(-1, -2)) / math.sqrt(hd)
    if mask is not None:
        scores = scores + mask
    p = scores.softmax(-1)
    o = torch.matmul(p, v).transpose(1, 2).reshape(1, -1, d)
    return mha.out_proj(o)


def ff(layer, x):
    return layer.linear2(layer.activation(layer.linear1(x)))


def enc_layer(layer, x):
    x = x + attention(layer.self_attn, layer.norm1(x), layer.norm1(x))
    return x + ff(layer, layer.norm2(x))


def dec_layer(layer, x, memory, mask):
    y = layer.norm1(x)
    x = x + attention(layer.self_attn, y, y, mask)
    x = x + attention(layer.multihead_attn, layer.norm2(x), memory)
    return x + ff(layer, layer.norm3(x))


def embed(m, ids):
    n = ids.shape[1]
    pos = torch.arange(n, device=ids.device).unsqueeze(0)
    return m.tok(ids) + m.pos(pos)


class Encoder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, src):
        x = embed(self.m, src.long())
        for layer in self.m.encoder.layers:
            x = enc_layer(layer, x)
        return self.m.enc_norm(x)


class Decoder(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, tgt, memory):
        tgt = tgt.long()
        n = tgt.shape[1]
        mask = torch.triu(torch.full((n, n), NEG), diagonal=1)
        x = embed(self.m, tgt)
        for layer in self.m.decoder.layers:
            x = dec_layer(layer, x, memory, mask)
        return self.m.out(self.m.dec_norm(x))[:, -1, :]


def ort_greedy(enc, dec, text, max_len=MAX_POS):
    src = np.array([encode(text)], dtype=np.int32)
    memory = enc.run(None, {"src": src})[0]
    ys = [BOS]
    for _ in range(max_len - 1):
        logits = dec.run(None, {"tgt": np.array([ys], dtype=np.int32), "memory": memory})[0]
        nxt = int(logits[0].argmax())
        ys.append(nxt)
        if nxt == EOS:
            break
    return decode(ys[1:])


def torch_greedy(m, text):
    from model import batch_encode
    return decode(m.greedy(batch_encode([text]))[0])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.path.join(HERE, "models", "gujlish_corrector.pt"))
    ap.add_argument("--out", default=os.path.join(HERE, "models"))
    ap.add_argument("--n", type=int, default=20)
    args = ap.parse_args()

    m = load(args.model, "cpu")
    m.eval()
    enc_path = os.path.join(args.out, "encoder.onnx")
    dec_path = os.path.join(args.out, "decoder.onnx")

    src = torch.tensor([encode("kem cho majama")], dtype=torch.int32)
    tgt = torch.tensor([[BOS] + encode("kem ch")], dtype=torch.int32)
    with torch.no_grad():
        memory = m.encode(src.long())
    torch.onnx.export(Encoder(m), (src,), enc_path, input_names=["src"],
                      output_names=["memory"], opset_version=17, dynamo=False,
                      dynamic_axes={"src": {1: "S"}, "memory": {1: "S"}})
    torch.onnx.export(Decoder(m), (tgt, memory), dec_path, input_names=["tgt", "memory"],
                      output_names=["logits"], opset_version=17, dynamo=False,
                      dynamic_axes={"tgt": {1: "T"}, "memory": {1: "S"}})
    for p in (enc_path, dec_path):
        onnx.checker.check_model(onnx.load(p))

    q_paths = []
    for p in (enc_path, dec_path):
        q = p.replace(".onnx", "_int8.onnx")
        quantize_dynamic(p, q, weight_type=QuantType.QInt8)
        q_paths.append(q)

    def mb(p):
        return os.path.getsize(p) / 1e6
    print(f"fp32: encoder {mb(enc_path):.2f} MB  decoder {mb(dec_path):.2f} MB")
    print(f"int8: encoder {mb(q_paths[0]):.2f} MB  decoder {mb(q_paths[1]):.2f} MB  "
          f"total {mb(q_paths[0]) + mb(q_paths[1]):.2f} MB")

    pairs = load_pairs(os.path.join(HERE, "data", "pairs_test.jsonl"))
    random.Random(1).shuffle(pairs)
    tests = [s for s, _ in pairs[:args.n]]
    so = ort.SessionOptions()
    so.intra_op_num_threads = 2
    for label, (e, d) in (("fp32", (enc_path, dec_path)), ("int8", q_paths)):
        es, ds = ort.InferenceSession(e, so), ort.InferenceSession(d, so)
        same, t = 0, time.time()
        diffs = []
        for s in tests:
            a, b = torch_greedy(m, s), ort_greedy(es, ds, s)
            same += a == b
            if a != b:
                diffs.append((s, a, b))
        ms = (time.time() - t) * 1000 / len(tests)
        print(f"{label}: {same}/{len(tests)} identical to PyTorch, {ms:.0f} ms/sentence")
        for s, a, b in diffs[:5]:
            print(f"   {s!r}: torch {a!r}  ort {b!r}")
    json.dump({"vocab": VOCAB, "max_len": MAX_POS},
              open(os.path.join(args.out, "vocab.json"), "w"))


if __name__ == "__main__":
    main()
    sys.stdout.flush()
    os._exit(0)  # skip interpreter teardown: torch + onnxruntime trip over each other on exit
