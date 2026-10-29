# REPACK iOS

An iOS implementation of REPACK, with support for fully locally run models.

Requires LiteRT-LM v0.18.0 (`b2f686e`) checked out at `../LiteRT-LM`.

The app keeps `-all_load`, which LiteRT-LM v0.18.0 removed from its package. This loads the complete SentencePiece library and prevents tokenizer symbol conflicts with the runtime.
