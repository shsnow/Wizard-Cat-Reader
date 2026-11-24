package android.view;

/**
 * Base of input events. The android.jar stub throws "Stub!" from its constructor, so the
 * headless MotionEvent needs a base that can be built.
 */
public abstract class InputEvent {
    InputEvent() {}

    public abstract int getDeviceId();

    public abstract int getSource();

    public boolean isFromSource(int source) {
        return (getSource() & source) == source;
    }

    public abstract long getEventTime();

    public void recycle() {}
}
