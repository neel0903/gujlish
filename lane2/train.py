"""
Train the corrector on data/pairs_{train,dev}.jsonl.

    python3 train.py --epochs 20 --device auto

Early-stops on dev character error rate; saves models/gujlish_corrector.pt
"""
import argparse
import json
import math
import os
import random
import time

import torch
import torch.nn.functional as F

from model import (CharTransformer, MAX_LEN, PAD, batch_encode, decode, save)

HERE = os.path.dirname(os.path.abspath(__file__))


def load_pairs(path, limit=None):
    out = []
    with open(path) as f:
        for line in f:
            d = json.loads(line)
            if len(d["src"]) <= MAX_LEN and len(d["tgt"]) <= MAX_LEN:
                out.append((d["src"], d["tgt"]))
    if limit:
        out = out[:limit]
    return out


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def cer(hyps, refs):
    e = sum(edit_distance(h, r) for h, r in zip(hyps, refs))
    n = sum(len(r) for r in refs)
    return e / max(1, n)


def predict(model, srcs, device, bs=256):
    out = []
    for i in range(0, len(srcs), bs):
        chunk = srcs[i:i + bs]
        src = batch_encode(chunk, device)
        out += [decode(r) for r in model.greedy(src)]
    return out


def evaluate(model, pairs, device):
    hyps = predict(model, [s for s, _ in pairs], device)
    refs = [t for _, t in pairs]
    acc = sum(h == r for h, r in zip(hyps, refs)) / len(refs)
    return acc, cer(hyps, refs)


def pick_device(name):
    if name != "auto":
        return torch.device(name)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--warmup", type=int, default=500)
    ap.add_argument("--smoothing", type=float, default=0.1)
    ap.add_argument("--patience", type=int, default=3)
    ap.add_argument("--dev-limit", type=int, default=1500)
    ap.add_argument("--train-limit", type=int, default=None)
    ap.add_argument("--max-minutes", type=float, default=90)
    ap.add_argument("--device", default="auto")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default=os.path.join(HERE, "models", "gujlish_corrector.pt"))
    args = ap.parse_args()

    torch.manual_seed(args.seed)
    random.seed(args.seed)
    device = pick_device(args.device)
    train = load_pairs(os.path.join(HERE, "data", "pairs_train.jsonl"), args.train_limit)
    dev = load_pairs(os.path.join(HERE, "data", "pairs_dev.jsonl"))
    random.Random(0).shuffle(dev)
    dev = dev[:args.dev_limit]
    print(f"device {device}  train {len(train)}  dev {len(dev)}")

    model = CharTransformer().to(device)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"params {n_params/1e6:.2f}M")
    opt = torch.optim.AdamW(model.parameters(), lr=args.lr, betas=(0.9, 0.98), weight_decay=0.01)
    steps_per_epoch = math.ceil(len(train) / args.batch)
    total = steps_per_epoch * args.epochs

    def lr_at(step):
        if step < args.warmup:
            return args.lr * step / args.warmup
        p = (step - args.warmup) / max(1, total - args.warmup)
        return args.lr * (0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * p)))

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    best, bad, step = None, 0, 0
    t0 = time.time()
    for epoch in range(1, args.epochs + 1):
        model.train()
        random.shuffle(train)
        tot_loss, nb = 0.0, 0
        te = time.time()
        for i in range(0, len(train), args.batch):
            chunk = train[i:i + args.batch]
            src = batch_encode([s for s, _ in chunk], device)
            tgt = batch_encode([t for _, t in chunk], device, bos=True, eos=True)
            tgt_in, tgt_out = tgt[:, :-1], tgt[:, 1:]
            for g in opt.param_groups:
                g["lr"] = lr_at(step)
            logits = model(src, tgt_in)
            loss = F.cross_entropy(logits.reshape(-1, logits.shape[-1]), tgt_out.reshape(-1),
                                   ignore_index=PAD, label_smoothing=args.smoothing)
            opt.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step()
            step += 1
            tot_loss += loss.item()
            nb += 1
            if nb % 100 == 0:
                print(f"  ep {epoch} step {nb}/{steps_per_epoch} loss {tot_loss/nb:.3f} "
                      f"lr {lr_at(step):.2e} {(time.time()-te)/nb*1000:.0f} ms/step", flush=True)
        acc, c = evaluate(model, dev, device)
        mins = (time.time() - t0) / 60
        print(f"epoch {epoch}  loss {tot_loss/nb:.3f}  dev acc {acc:.3f}  dev CER {c:.4f}  "
              f"{mins:.1f} min", flush=True)
        if best is None or c < best:
            best, bad = c, 0
            save(model, args.out)
            print(f"  saved {args.out}", flush=True)
        else:
            bad += 1
            if bad >= args.patience:
                print("early stop")
                break
        if mins > args.max_minutes:
            print("time budget reached")
            break
    print(f"best dev CER {best:.4f}")


if __name__ == "__main__":
    main()
