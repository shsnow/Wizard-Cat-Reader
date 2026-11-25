package android.hardware.display;

import android.os.Handler;
import android.view.Display;
import android.view.Surface;

/**
 * Headless DisplayManager. Extensions create a private virtual display to render an offscreen
 * WebView "like on screen"; the iOS WebView already renders in the app's window, so the
 * display is accepted and draws nowhere.
 */
public final class DisplayManager {
    public DisplayManager() {}

    public Display getDisplay(int displayId) { return null; }

    public Display[] getDisplays() { return new Display[0]; }

    public Display[] getDisplays(String category) { return new Display[0]; }

    public VirtualDisplay createVirtualDisplay(
        String name, int width, int height, int densityDpi, Surface surface, int flags
    ) {
        return new VirtualDisplay(surface);
    }

    public VirtualDisplay createVirtualDisplay(
        String name, int width, int height, int densityDpi, Surface surface, int flags,
        VirtualDisplay.Callback callback, Handler handler
    ) {
        return new VirtualDisplay(surface);
    }

    public void registerDisplayListener(Object listener, Handler handler) {}

    public void unregisterDisplayListener(Object listener) {}
}
