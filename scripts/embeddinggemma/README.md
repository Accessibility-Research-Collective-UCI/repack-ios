# Export the BERTScore token model

This script exports `google/embeddinggemma-300m` after its first 16 transformer layers, including the final RMS normalization.
It matches the model construction in `partial_abstainer.py` and `bert_score.utils.get_model`.
It removes sentence pooling, projection, and the sentence-similarity prompt.

Run the conversion on Linux or Apple Silicon macOS with access to the gated Hugging Face checkpoint.
The full export passes on Apple Silicon with Python 3.12. The Linux command uses Python 3.11.
Accept the model license on Hugging Face before downloading its weights.
If authentication is required, set `HF_TOKEN` outside the repository.
Install [uv](https://docs.astral.sh/uv/getting-started/installation/) before running the script.
The script declares its dependencies inline. uv manages an isolated environment automatically.
The adjacent `.lock` file pins the resolved dependencies.
JAX 0.10.2 matches the converter's supported StableHLO format.

From the `repack-ios` repository root, run:

```bash
uv run --no-project --script --locked --python 3.11 scripts/embeddinggemma/export_bertscore.py \
  --sentencepiece DevelopmentAssets/Models/sentencepiece.model \
  --output-dir /tmp/repack-embedding-export
```

The existing tokenizer must match the checksum in the script.
The `--no-project --script` flags select the script environment instead of the repository's Python 3.14 development environment.
If you use another host, copy the tokenizer, script, and `.lock` file to that host.
The script compares token IDs with the Hugging Face tokenizer before conversion.
It also compares model output with the original PyTorch path before conversion and with LiteRT output afterward.
The script also runs the exported PyTorch graph on every fixture.
The export uses shared-head broadcasting because LiteRT Torch 0.10.0 incorrectly converts the original key repetition and transpose.
This change preserves the attention calculation and the numerical validation limits.
A failed conversion or comparison leaves a `.pending.tflite` file, which is not ready for upload.

After the script succeeds, upload `embeddinggemma-300m-bertscore-layer16-seq256-f32.tflite` to S3.
Provide the resulting URL and `export-report.json` to finish the app catalog entry.
The report includes the SHA-256 checksum and numerical comparison results.
The app catalog pins the published S3 model to the SHA-256 checksum from its export report.

The output has one Int32 input of shape `[1, 256]` and one Float32 output of shape `[1, 256, 768]`.
Input IDs include BOS and EOS, with zero padding on the right.
The model excludes padding from attention and returns unnormalized token vectors.
The Swift service normalizes each valid token vector before matching.
Float32 is the initial export format, so the artifact is larger than the old mixed-precision model.

For a development build, place the new model and the following files in `DevelopmentAssets/Models`:

- `sentencepiece.model`
- `vlm-gemma-4-e2b_llm-gemma-4-e2b.json`
- `vlm-gemma-4-e4b_llm-gemma-4-e2b.json`

On Apple Silicon, replace `--python 3.11` with `--python 3.12` to use the tested Python version.
Run the same command with `--check-only` to test tokenization, PyTorch output, and graph export without conversion.
Use `--model /path/to/checkpoint` for a local checkpoint or `--revision COMMIT` to pin a Hugging Face revision.

## Scoring limits

Inference truncates statements to 254 content tokens plus BOS and EOS.
IDF uses the Python tokenizer limit of 2048 tokens per calibration statement.
It preserves repeated documents and counts each token once per document.
Statement embeddings and ordered pair scores are reused within one run.
Original atomic occurrences and sample membership remain intact.
The existing semantic thresholds and certainty bands remain unchanged and need separate BERTScore calibration.

## Python reference tests

`repackTests/Fixtures/bertscore-reference.json` contains scores from the research project's `bert_score` package, using layer 16 and both production calibrations.
The fixture records token IDs, IDF weights, dependency versions, and artifact checksums.
The Swift integration test compares F1 scores with an absolute tolerance of 0.001.
It fails if the required model assets are missing or their checksums differ.

To regenerate the fixture, use the existing `partial-abstainer` Python environment from the repository root:

```bash
uv run --project ../partial-abstainer --no-sync python scripts/embeddinggemma/generate_reference.py \
  --model /path/to/embeddinggemma-checkpoint
```

The checkpoint directory must contain the Hugging Face model and tokenizer files.
Keep the exported model, tokenizer, calibrations, and `export-report.json` in `DevelopmentAssets/Models`.
The generator adapts BERTScore's removed tokenizer method for empty strings under Transformers 5. It does not replace BERTScore's scoring calculation.

Run the `BERTScoreReferenceTests` suite in the `repack` scheme with the Debug configuration.
The test reads local assets and does not contact a network service.
These comparisons test numerical agreement, not caption accuracy or acceptance thresholds.
