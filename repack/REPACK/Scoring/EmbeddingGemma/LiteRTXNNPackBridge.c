#include "LiteRTXNNPackBridge.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct TfLiteDelegate TfLiteDelegate;
typedef struct TfLiteInterpreterOptions TfLiteInterpreterOptions;
typedef struct TfLiteXNNPackDelegateWeightsCache
    TfLiteXNNPackDelegateWeightsCache;

// Mirrors the stable LiteRT XNNPACK delegate C API. The implementation
// deliberately obtains the runtime's default options before changing the
// thread count so build-specific flags remain intact.
typedef struct {
    int32_t num_threads;
    uint32_t runtime_flags;
    uint32_t flags;
    TfLiteXNNPackDelegateWeightsCache *weights_cache;
    bool handle_variable_ops;
    const char *weight_cache_file_path;
    int weight_cache_file_descriptor;
    void *weight_cache_provider;
    bool weight_cache_lock_memory;
} TfLiteXNNPackDelegateOptions;

extern TfLiteXNNPackDelegateOptions
TfLiteXNNPackDelegateOptionsDefault(void);

extern TfLiteDelegate *TfLiteXNNPackDelegateCreate(
    const TfLiteXNNPackDelegateOptions *options
);

extern void TfLiteXNNPackDelegateDelete(TfLiteDelegate *delegate);

extern void TfLiteInterpreterOptionsAddDelegate(
    TfLiteInterpreterOptions *options,
    TfLiteDelegate *delegate
);

void *REPACKCreateXNNPackDelegate(
    void *interpreter_options,
    int32_t thread_count
) {
    if (interpreter_options == NULL || thread_count <= 0) {
        return NULL;
    }

    TfLiteXNNPackDelegateOptions options =
        TfLiteXNNPackDelegateOptionsDefault();
    options.num_threads = thread_count;

    TfLiteDelegate *delegate = TfLiteXNNPackDelegateCreate(&options);
    if (delegate == NULL) {
        return NULL;
    }

    TfLiteInterpreterOptionsAddDelegate(
        (TfLiteInterpreterOptions *)interpreter_options,
        delegate
    );
    return delegate;
}

void REPACKDeleteXNNPackDelegate(void *delegate) {
    TfLiteXNNPackDelegateDelete((TfLiteDelegate *)delegate);
}
