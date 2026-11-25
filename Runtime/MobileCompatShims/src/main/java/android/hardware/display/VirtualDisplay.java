package android.hardware.display;

import android.view.Display;
import android.view.Surface;

/** A virtual display that shows nothing (see DisplayManager). */
public final class VirtualDisplay {
    public abstract static class Callback {
        public void onPaused() {}
        public void onResumed() {}
        public void onStopped() {}
    }

    private Surface surface;

    VirtualDisplay(Surface surface) {
        this.surface = surface;
    }

    /** No Android display exists on iOS. */
    public Display getDisplay() { return null; }

    public Surface getSurface() { return surface; }

    public void setSurface(Surface surface) { this.surface = surface; }

    public void resize(int width, int height, int densityDpi) {}

    public void release() {}

    @Override
    public String toString() { return "VirtualDisplay(headless)"; }
}
