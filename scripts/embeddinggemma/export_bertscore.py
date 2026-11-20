#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "litert-torch==0.10.0",
#     "jax==0.10.2",
#     "torch==2.14.0",
#     "transformers==5.19.0",
#     "sentencepiece==0.2.2",
#     "numpy",
# ]
# ///
"""Export the layer-16 token model used by REPACK BERTScore, then validate it."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

MODEL = "google/embeddinggemma-300m"
FILENAME = "embeddinggemma-300m-bertscore-layer16-seq256-f32.tflite"
LAYER = 16
LENGTH = 256
DIMENSION = 768
TOKENIZER_SHA256 = "d6daa52d93d7aad10e8388bd526c4e501d914b47177398d1d9621f1fe48438c7"
TEXTS = [
    "A red package.", "The package is red.", "A white logo.", "", "  A red package.  ",
    "Café: $12.50, 200 mL. 日本語", "The word package repeats. " * 100,
]


def digest(path: Path) -> str:
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def make_wrapper(model):
    import torch

    class TokenModel(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.model = model
            positions = torch.arange(LENGTH)
            self.register_buffer("positions", positions.unsqueeze(0))
            # Gemma3's bidirectional sliding window includes distances < window.
            self.register_buffer("window", (positions[:, None] - positions[None, :]).abs()
                                 < model.config.sliding_window)

        def forward(self, input_ids):
            valid = input_ids.ne(0)[:, None, None, :]
            minimum = torch.finfo(torch.float32).min
            full = torch.where(valid, 0.0, minimum).expand(1, 1, LENGTH, LENGTH)
            sliding = torch.where(valid & self.window[None, None, :, :], 0.0, minimum)
            return self.model(
                input_ids=input_ids.to(torch.int64),
                attention_mask={"full_attention": full, "sliding_attention": sliding},
                position_ids=self.positions, use_cache=False,
            ).last_hidden_state

    return TokenModel().eval()


def export_attention(module, query, key, value, attention_mask, scaling,
                     dropout=0.0, softcap=None, **kwargs):
    import torch

    if module.training or dropout != 0 or softcap is not None or key.shape[1] != 1:
        raise ValueError("Export attention requires inference with one shared key/value head and no softcap")
    # LiteRT Torch 0.10.0 loses the key transpose after repeat_kv; broadcast the shared head instead.
    weights = (query @ key.transpose(-1, -2)) * scaling
    weights = torch.softmax(weights + attention_mask, dim=-1)
    result = weights @ value
    return result.transpose(1, 2).contiguous(), None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--sentencepiece", type=Path, required=True,
                        help="The existing REPACK sentencepiece.model; checked against Hugging Face.")
    parser.add_argument("--model", default=MODEL, help="Hugging Face ID or local checkpoint directory.")
    parser.add_argument("--revision", default="main")
    parser.add_argument("--check-only", action="store_true",
                        help="Validate tokenization, PyTorch output, and torch.export without LiteRT conversion.")
    args = parser.parse_args()

    import numpy as np
    import sentencepiece as spm
    import torch
    from transformers import AttentionInterface, AutoModel, AutoTokenizer

    torch.set_num_threads(4)
    if digest(args.sentencepiece) != TOKENIZER_SHA256:
        raise ValueError("sentencepiece.model does not match the iOS tokenizer checksum")
    tokenizer = AutoTokenizer.from_pretrained(args.model, revision=args.revision, use_fast=True)
    if tokenizer.model_max_length != 2048:
        raise ValueError("The iOS IDF tokenizer expects a 2048-token calibration limit")
    sentencepiece = spm.SentencePieceProcessor(model_file=str(args.sentencepiece))
    model = AutoModel.from_pretrained(args.model, revision=args.revision,
                                      dtype=torch.float32, attn_implementation="eager")
    if model.config.hidden_size != DIMENSION or not model.config.use_bidirectional_attention:
        raise ValueError("Expected the bidirectional EmbeddingGemma 300M text model")
    # Match bert_score.utils.get_model(num_layers=16), including the final RMSNorm.
    model.layers = torch.nn.ModuleList(list(model.layers[:LAYER]))
    model.config.layer_types = model.config.layer_types[:LAYER]
    model.eval()
    wrapper = make_wrapper(model)
    inputs = []
    reference_outputs = []
    token_lists = []
    for text in TEXTS:
        expected = tokenizer.encode(text.strip(), add_special_tokens=True,
                                    max_length=LENGTH, truncation=True)
        actual = [2] + sentencepiece.encode(text.strip())[:LENGTH - 2] + [1]
        if expected != actual:
            raise ValueError(f"Tokenizer parity failed for fixture {len(inputs)}")
        ids = torch.tensor([actual + [0] * (LENGTH - len(actual))], dtype=torch.int32)
        with torch.no_grad():
            reference = model(input_ids=ids.long(), attention_mask=ids.ne(0),
                              use_cache=False).last_hidden_state
            exported = wrapper(ids)
        torch.testing.assert_close(exported[:, :len(actual)], reference[:, :len(actual)],
                                   rtol=1e-5, atol=1e-5)
        inputs.append(ids)
        reference_outputs.append(reference.numpy())
        token_lists.append(actual)
    AttentionInterface.register("repack_export", export_attention)
    model.set_attn_implementation("repack_export")
    with torch.no_grad():
        graph = torch.export.export(wrapper, (inputs[0],), strict=True).module()
        for ids, tokens, expected in zip(inputs, token_lists, reference_outputs, strict=True):
            reference = torch.from_numpy(expected)[:, :len(tokens)]
            for output in (wrapper(ids), graph(ids)):
                torch.testing.assert_close(output[:, :len(tokens)], reference, rtol=1e-5, atol=1e-5)
    print("Tokenization, layer-16 output, and torch.export checks passed.", flush=True)
    if args.check_only:
        return

    import litert_torch
    from ai_edge_litert.interpreter import Interpreter

    args.output_dir.mkdir(parents=True, exist_ok=True)
    destination = args.output_dir / FILENAME
    if destination.exists():
        raise FileExistsError(f"Refusing to overwrite {destination}")
    pending = destination.with_suffix(".pending.tflite")
    with torch.no_grad():
        edge_model = litert_torch.convert(wrapper, (inputs[0],))
    edge_model.export(str(pending))
    interpreter = Interpreter(model_path=str(pending), num_threads=4)
    interpreter.allocate_tensors()
    input_info, = interpreter.get_input_details()
    output_info, = interpreter.get_output_details()
    if input_info["dtype"] != np.int32 or list(input_info["shape"]) != [1, LENGTH]:
        raise ValueError("LiteRT input must be Int32[1,256]")
    if output_info["dtype"] != np.float32 or list(output_info["shape"]) != [1, LENGTH, DIMENSION]:
        raise ValueError("LiteRT output must be Float32[1,256,768]")
    actual_outputs = []
    max_error = 0.0
    for ids, tokens, expected in zip(inputs, token_lists, reference_outputs, strict=True):
        interpreter.set_tensor(input_info["index"], ids.numpy())
        interpreter.invoke()
        actual = interpreter.get_tensor(output_info["index"])
        a, b = actual[0, :len(tokens)], expected[0, :len(tokens)]
        a = a / np.linalg.norm(a, axis=-1, keepdims=True)
        b = b / np.linalg.norm(b, axis=-1, keepdims=True)
        np.testing.assert_allclose(a, b, rtol=1e-3, atol=1e-3)
        max_error = max(max_error, float(np.max(np.abs(a - b))))
        actual_outputs.append(a)

    # A deterministic calibration exercises IDF without downloading the production corpora.
    from collections import Counter
    counts = Counter(token for tokens in token_lists for token in set(tokens))
    weights = {token: np.log((len(token_lists) + 1) / (count + 1))
               for token, count in counts.items()}

    def f1(a, b, left, right):
        lw = np.array([weights[t] for t in left], dtype=np.float32)
        rw = np.array([weights[t] for t in right], dtype=np.float32)
        if lw.sum() == 0 or rw.sum() == 0:
            return 0.0
        sim = a @ b.T
        p = float(sim.max(axis=1) @ (lw / lw.sum()))
        r = float(sim.max(axis=0) @ (rw / rw.sum()))
        return 2 * p * r / (p + r) if p + r != 0 else 0.0

    max_score_error = 0.0
    for i, left in enumerate(token_lists):
        for j, right in enumerate(token_lists):
            a = reference_outputs[i][0, :len(left)]
            b = reference_outputs[j][0, :len(right)]
            a = a / np.linalg.norm(a, axis=-1, keepdims=True)
            b = b / np.linalg.norm(b, axis=-1, keepdims=True)
            expected = f1(a, b, left, right)
            actual = f1(actual_outputs[i], actual_outputs[j], left, right)
            max_score_error = max(max_score_error, abs(actual - expected))
    if max_score_error > 0.01:
        raise ValueError(f"BERTScore parity failed: maximum error {max_score_error}")
    pending.rename(destination)
    report = {
        "model": MODEL, "revision": getattr(model.config, "_commit_hash", args.revision),
        "layer": LAYER, "final_rms_norm": True, "sequence_length": LENGTH,
        "filename": FILENAME, "sha256": digest(destination),
        "tokenizer_sha256": TOKENIZER_SHA256,
        "tokenizer_model_max_length": tokenizer.model_max_length,
        "max_normalized_token_error": max_error, "max_f1_error": max_score_error,
    }
    (args.output_dir / "export-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
