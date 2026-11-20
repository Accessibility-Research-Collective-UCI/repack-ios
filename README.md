# REPACK iOS

An iOS implementation of REPACK, with support for fully locally run models.

Uses the patched LiteRT-LM v0.19.1 from [LiteRT-LM-Custom, branch `ios/v0.19.1-metal-mtp`](https://github.com/Accessibility-Research-Collective-UCI/LiteRT-LM-Custom/tree/ios/v0.19.1-metal-mtp), checked out at `../LiteRT-LM-Custom`. Follow the fork’s [iOS build instructions](https://github.com/Accessibility-Research-Collective-UCI/LiteRT-LM-Custom/blob/ios/v0.19.1-metal-mtp/local-build/README.md) to generate the frameworks before building the app. This is needed to have MTP support for sampling which, prior to 0.19.0, did not respect the sampling settings.

The app keeps `-all_load`, which LiteRT-LM v0.18.0 removed from its package. This loads the complete SentencePiece library and prevents tokenizer symbol conflicts with the runtime.
