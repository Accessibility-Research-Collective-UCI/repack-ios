# Development model assets

Place approved `.litertlm` development files in this directory. The app target's
`Embed Development Models` build phase copies them into Debug products only.
Release products never copy files from this directory.

BERTScore also requires `embeddinggemma-300m-bertscore-layer16-seq256-f32.tflite`,
`sentencepiece.model`, and both `vlm-gemma-4-*_llm-gemma-4-e2b.json` calibration files.
The old sentence-vector model does not provide the token output that BERTScore needs.
See the [export instructions](../../scripts/embeddinggemma/README.md) to generate the token model.
