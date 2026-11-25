package android.media;

import android.os.Handler;
import android.view.Surface;

/**
 * Headless ImageReader. Extensions use it as the sink of an offscreen virtual display; on iOS
 * the WebView already renders in the app's window, so no frames ever arrive here.
 */
public class ImageReader implements AutoCloseable {
    public interface OnImageAvailableListener {
        void onImageAvailable(ImageReader reader);
    }

    private final int width;
    private final int height;
    private final int format;
    private final int maxImages;

    protected ImageReader(int width, int height, int format, int maxImages) {
        this.width = width;
        this.height = height;
        this.format = format;
        this.maxImages = maxImages;
    }

    public static ImageReader newInstance(int width, int height, int format, int maxImages) {
        return new ImageReader(width, height, format, maxImages);
    }

    public static ImageReader newInstance(int width, int height, int format, int maxImages, long usage) {
        return new ImageReader(width, height, format, maxImages);
    }

    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public int getImageFormat() { return format; }
    public int getMaxImages() { return maxImages; }

    /** No real surface: whatever is given it draws nowhere. */
    public Surface getSurface() { return null; }

    public Image acquireLatestImage() { return null; }
    public Image acquireNextImage() { return null; }

    public void setOnImageAvailableListener(OnImageAvailableListener listener, Handler handler) {}

    public void discardFreeBuffers() {}

    @Override
    public void close() {}
}
