#!/usr/bin/env python3
"""Generate Swift fixtures with the bert_score package used by partial_abstainer.py.

Run in the partial-abstainer Python environment, with its existing dependencies.
"""
import argparse
import hashlib
import json
from pathlib import Path

import bert_score
import torch
import transformers
from bert_score import BERTScorer

PAIRS = [
    ("A red package.", "A red package."),
    ("There is a plastic bottle.", "There is a plastic container."),
    ("The bottle is red.", "The bottle is blue."),
    ("The label says 709.", "The label says 710."),
    ("A red package.", "A dog runs through a field."),
    ("Café: $12.50, 200 mL. 日本語", "Café: 200 mL. 日本語"),
    ("", "A red package."),
    ("A red package.", ""),
]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="google/embeddinggemma-300m")
    parser.add_argument("--assets", type=Path, default=Path("DevelopmentAssets/Models"))
    parser.add_argument("--output", type=Path, default=Path("repackTests/Fixtures/bertscore-reference.json"))
    args = parser.parse_args()
    torch.set_num_threads(4)
    # Match PartialAbstainer's BERTScorer construction, without the mobile export wrapper.
    scorer = BERTScorer(model_type=args.model, num_layers=16, lang="en", idf=True,
                        device="cpu", nthreads=1, use_fast_tokenizer=True)
    texts = list(dict.fromkeys(text for pair in PAIRS for text in pair))
    tokens = [scorer._tokenizer.encode(text.strip(), add_special_tokens=True,
                                     max_length=2048, truncation=True) for text in texts]
    assert all(len(ids) <= 256 for ids in tokens)
    calibrations = []
    for vision in ["gemma-4-e2b", "gemma-4-e4b"]:
        path = args.assets / f"vlm-{vision}_llm-gemma-4-e2b.json"
        corpus = json.loads(path.read_text())
        scorer.compute_idf([text for source in corpus["sources"] for text in source["statements"]])
        # bert_score 0.3.12 uses this removed Transformers API only for empty strings.
        if not hasattr(scorer._tokenizer, "build_inputs_with_special_tokens"):
            def empty_special_tokens(ids):
                assert ids == []
                return scorer._tokenizer.encode("", add_special_tokens=True)
            scorer._tokenizer.build_inputs_with_special_tokens = empty_special_tokens
        _, _, scores = scorer.score([a for a, _ in PAIRS], [b for _, b in PAIRS], batch_size=8)
        if "build_inputs_with_special_tokens" in vars(scorer._tokenizer):
            del scorer._tokenizer.build_inputs_with_special_tokens
        assert torch.isfinite(scores).all()
        calibrations.append({
            "name": vision, "filename": path.name, "sha256": digest(path),
            "weights": [[scorer._idf_dict[token] for token in ids] for ids in tokens],
            "scores": scores.tolist(),
        })
    report = json.loads((args.assets / "export-report.json").read_text())
    fixture = {
        "bert_score_version": bert_score.__version__, "torch_version": torch.__version__,
        "transformers_version": transformers.__version__,
        "checkpoint_sha256": digest(Path(args.model) / "model.safetensors") if Path(args.model).is_dir() else None,
        "model_sha256": report["sha256"], "tokenizer_sha256": report["tokenizer_sha256"],
        "layer": 16, "tolerance": 0.001, "texts": texts, "token_ids": tokens,
        "pairs": [[texts.index(a), texts.index(b)] for a, b in PAIRS],
        "calibrations": calibrations,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixture, indent=2, ensure_ascii=False) + "\n")
    print(f"Wrote {args.output}")


if __name__ == "__main__":
    main()
