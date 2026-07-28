#ifndef LiteRTXNNPackBridge_h
#define LiteRTXNNPackBridge_h

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/// Creates an XNNPACK delegate, configures its thread pool, and attaches it to
/// the supplied `TfLiteInterpreterOptions`.
///
/// The returned delegate must outlive the interpreter created with those
/// options and must be released with `REPACKDeleteXNNPackDelegate` only after
/// the interpreter is destroyed.
void *REPACKCreateXNNPackDelegate(
    void *interpreter_options,
    int32_t thread_count
);

void REPACKDeleteXNNPackDelegate(void *delegate);

#if defined(__cplusplus)
}
#endif

#endif
