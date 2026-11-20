// WizardJVMRunner — Apache License 2.0

import CWizardJVMBridge
import Foundation

/// The reverse half of the WebView bridge: hands WKWebView events to the
/// Android-compat layer (`IOSWebViewProviderFactory.dispatchEvent`).
public enum WebKitEvents {
    /// Safe from any thread. Returns nil when the VM is not ready yet.
    /// Never call it from the main thread: some events wait for Java's
    /// emulated main looper, which may itself be waiting for the main thread.
    public static func dispatch(
        handle: Int64,
        event: String,
        _ argument1: String? = nil,
        _ argument2: String? = nil
    ) -> String? {
        let pointer = event.withCString { eventPointer in
            withOptionalCString(argument1) { first in
                withOptionalCString(argument2) { second in
                    wjb_webkit_dispatch_event(handle, eventPointer, first, second)
                }
            }
        }
        guard let pointer else { return nil }
        defer { wjb_string_free(pointer) }
        return String(cString: pointer)
    }

    private static func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let value else { return body(nil) }
        return value.withCString { body($0) }
    }
}
