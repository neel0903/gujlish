"""
Character-level transformer encoder-decoder for whole-sentence Gujlish
correction. Small on purpose: it has to fit in a keyboard extension.

vocab: <pad> <s> </s> a-z space  (30 tokens)
"""
import math

import torch
import torch.nn as nn

PAD, BOS, EOS = 0, 1, 2
CHARS = "abcdefghijklmnopqrstuvwxyz "
VOCAB = ["<pad>", "<s>", "</s>"] + list(CHARS)
STOI = {c: i for i, c in enumerate(VOCAB)}
MAX_LEN = 64          # characters of src / tgt
MAX_POS = MAX_LEN + 2  # + <s> </s>

# Additive mask value. Finite and fp16-safe: Core ML's CPU path computes
# triu as a multiply by zero, and -inf * 0 is NaN. exp(-1e4) is 0 anyway.
NEG = -1e4


def encode(text):
    return [STOI[c] for c in text if c in STOI]


def decode(ids):
    out = []
    for i in ids:
        if i == EOS:
            break
        if i > EOS:
            out.append(VOCAB[i])
    return "".join(out)


def causal_mask(n, device=None):
    return torch.triu(torch.full((n, n), NEG, device=device), diagonal=1)


class CharTransformer(nn.Module):
    def __init__(self, vocab=len(VOCAB), d_model=256, nhead=4, enc_layers=3,
                 dec_layers=3, ff=512, dropout=0.1, max_pos=MAX_POS):
        super().__init__()
        self.cfg = dict(vocab=vocab, d_model=d_model, nhead=nhead,
                        enc_layers=enc_layers, dec_layers=dec_layers, ff=ff,
                        dropout=dropout, max_pos=max_pos)
        self.d_model = d_model
        self.tok = nn.Embedding(vocab, d_model, padding_idx=PAD)
        self.pos = nn.Embedding(max_pos, d_model)
        enc = nn.TransformerEncoderLayer(d_model, nhead, ff, dropout,
                                         batch_first=True, norm_first=True)
        dec = nn.TransformerDecoderLayer(d_model, nhead, ff, dropout,
                                         batch_first=True, norm_first=True)
        self.encoder = nn.TransformerEncoder(enc, enc_layers, enable_nested_tensor=False)
        self.decoder = nn.TransformerDecoder(dec, dec_layers)
        self.enc_norm = nn.LayerNorm(d_model)
        self.dec_norm = nn.LayerNorm(d_model)
        self.out = nn.Linear(d_model, vocab)
        self.drop = nn.Dropout(dropout)

    def embed(self, ids):
        n = ids.shape[1]
        pos = torch.arange(n, device=ids.device).unsqueeze(0)
        # No sqrt(d) scaling: with PyTorch's unit-variance embedding init it
        # would drown the positional signal (the model then learns anagrams).
        return self.drop(self.tok(ids) + self.pos(pos))

    def encode(self, src, src_pad_mask=None):
        x = self.embed(src)
        return self.enc_norm(self.encoder(x, src_key_padding_mask=src_pad_mask))

    def decode(self, tgt, memory, src_pad_mask=None):
        y = self.embed(tgt)
        mask = causal_mask(tgt.shape[1], tgt.device)
        y = self.decoder(y, memory, tgt_mask=mask,
                         memory_key_padding_mask=src_pad_mask)
        return self.out(self.dec_norm(y))

    def forward(self, src, tgt_in):
        src_pad = src.eq(PAD)
        memory = self.encode(src, src_pad)
        return self.decode(tgt_in, memory, src_pad)

    @torch.no_grad()
    def greedy(self, src, max_len=MAX_POS):
        """src: (B, S) padded. Returns list of id lists (no BOS, cut at EOS)."""
        self.eval()
        src_pad = src.eq(PAD)
        memory = self.encode(src, src_pad)
        B = src.shape[0]
        ys = torch.full((B, 1), BOS, dtype=torch.long, device=src.device)
        done = torch.zeros(B, dtype=torch.bool, device=src.device)
        for _ in range(max_len - 1):
            logits = self.decode(ys, memory, src_pad)[:, -1]
            nxt = logits.argmax(-1)
            nxt = torch.where(done, torch.full_like(nxt, PAD), nxt)
            ys = torch.cat([ys, nxt.unsqueeze(1)], dim=1)
            done |= nxt.eq(EOS)
            if bool(done.all()):
                break
        return [row[1:].tolist() for row in ys]


def batch_encode(texts, device=None, bos=False, eos=False):
    rows = []
    for t in texts:
        ids = encode(t)[:MAX_LEN]
        if bos:
            ids = [BOS] + ids
        if eos:
            ids = ids + [EOS]
        rows.append(ids)
    n = max(len(r) for r in rows)
    out = torch.full((len(rows), n), PAD, dtype=torch.long)
    for i, r in enumerate(rows):
        out[i, :len(r)] = torch.tensor(r)
    return out.to(device) if device is not None else out


def save(model, path):
    torch.save({"cfg": model.cfg, "state": model.state_dict()}, path)


def load(path, device="cpu"):
    ck = torch.load(path, map_location=device)
    m = CharTransformer(**ck["cfg"])
    m.load_state_dict(ck["state"])
    m.to(device).eval()
    return m


if __name__ == "__main__":
    m = CharTransformer()
    n = sum(p.numel() for p in m.parameters())
    print(f"params: {n/1e6:.2f}M")
    src = batch_encode(["kem cho", "su thyu che"])
    tgt = batch_encode(["kem cho", "su thayu che"], bos=True)
    print(m(src, tgt).shape)
    print([decode(r) for r in m.greedy(src, 8)])
