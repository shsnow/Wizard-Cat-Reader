// WizardJVMRunner — Apache License 2.0
// C interface between Swift and the embedded Java VM.
//
// Written for Wizard Cat Reader against the public JNI Invocation API
// (Oracle's jni.h, GPLv2 with the Classpath Exception) and the
// Apache-licensed extension-host protocol of TachiyomiAZ's Runtime/.

#ifndef WizardJVMBridge_h
#define WizardJVMBridge_h

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WJBRuntime WJBRuntime;

typedef enum WJBStatus {
    WJBStatusOK = 0,
    WJBStatusInvalidArgument = 1,
    WJBStatusVMCreationFailed = 2,
    WJBStatusThreadAttachFailed = 3,
    WJBStatusJavaClassNotFound = 4,
    WJBStatusJavaMethodNotFound = 5,
    WJBStatusJavaException = 6,
    WJBStatusAllocationFailed = 7,
    WJBStatusCompressionFailed = 8
} WJBStatus;

/// Creates the single in-process Java VM and prepares the extension host.
/// Registers the app.tachiaz.compat.NativeBridge natives. Returns NULL on
/// failure with a malloc'd message in error_message.
WJBRuntime *wjb_runtime_create(
    const char *java_home,
    const char *frameworks_directory,
    const char *classpath,
    const char *const *additional_options,
    int additional_option_count,
    char **error_message
);

/// Sends one JSON request to the host's dispatch(String) and returns its
/// JSON response (malloc'd) in response_json.
WJBStatus wjb_runtime_dispatch(
    WJBRuntime *runtime,
    const char *request_json,
    char **response_json,
    char **error_message
);

/// Releases bridge bookkeeping. The VM itself stays alive: DestroyJavaVM is
/// not safe for a long-lived multithreaded app process.
void wjb_runtime_release(WJBRuntime *runtime);

void wjb_string_free(char *value);

WJBStatus wjb_gzip_decompress(
    const unsigned char *input,
    size_t input_size,
    unsigned char **output,
    size_t *output_size
);

WJBStatus wjb_gzip_compress(
    const unsigned char *input,
    size_t input_size,
    unsigned char **output,
    size_t *output_size
);

void wjb_buffer_free(unsigned char *value);

/// Delivers a WKWebView event to app.tachiaz.compat.NativeBridge.dispatchWebKitEvent
/// from any thread (attaching and detaching it). Returns the Java result
/// (malloc'd, free with wjb_string_free) or NULL when the VM is not ready.
char *wjb_webkit_dispatch_event(
    long long handle,
    const char *event,
    const char *argument1,
    const char *argument2
);

#ifdef __cplusplus
}
#endif

#endif
