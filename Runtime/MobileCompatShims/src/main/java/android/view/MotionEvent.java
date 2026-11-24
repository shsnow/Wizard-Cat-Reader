package android.view;

/**
 * Headless MotionEvent: a plain value holder, enough for extensions that build touch events and
 * hand them to a WebView (the iOS WebView turns them into DOM events). Android's pooling,
 * history and batching are not modelled: every event holds one sample.
 */
public final class MotionEvent extends InputEvent {
    public static final int INVALID_POINTER_ID = -1;

    public static final int ACTION_MASK = 0xff;
    public static final int ACTION_DOWN = 0;
    public static final int ACTION_UP = 1;
    public static final int ACTION_MOVE = 2;
    public static final int ACTION_CANCEL = 3;
    public static final int ACTION_OUTSIDE = 4;
    public static final int ACTION_POINTER_DOWN = 5;
    public static final int ACTION_POINTER_UP = 6;
    public static final int ACTION_HOVER_MOVE = 7;
    public static final int ACTION_SCROLL = 8;
    public static final int ACTION_HOVER_ENTER = 9;
    public static final int ACTION_HOVER_EXIT = 10;
    public static final int ACTION_BUTTON_PRESS = 11;
    public static final int ACTION_BUTTON_RELEASE = 12;
    public static final int ACTION_POINTER_INDEX_MASK = 0xff00;
    public static final int ACTION_POINTER_INDEX_SHIFT = 8;

    public static final int TOOL_TYPE_UNKNOWN = 0;
    public static final int TOOL_TYPE_FINGER = 1;
    public static final int TOOL_TYPE_STYLUS = 2;
    public static final int TOOL_TYPE_MOUSE = 3;
    public static final int TOOL_TYPE_ERASER = 4;

    public static final int BUTTON_PRIMARY = 1;
    public static final int BUTTON_SECONDARY = 2;
    public static final int BUTTON_TERTIARY = 4;

    public static final int EDGE_TOP = 1;
    public static final int EDGE_BOTTOM = 2;
    public static final int EDGE_LEFT = 4;
    public static final int EDGE_RIGHT = 8;

    public static final int AXIS_X = 0;
    public static final int AXIS_Y = 1;
    public static final int AXIS_PRESSURE = 2;
    public static final int AXIS_SIZE = 3;
    public static final int AXIS_TOUCH_MAJOR = 4;
    public static final int AXIS_TOUCH_MINOR = 5;
    public static final int AXIS_TOOL_MAJOR = 6;
    public static final int AXIS_TOOL_MINOR = 7;
    public static final int AXIS_ORIENTATION = 8;

    private static final int SOURCE_TOUCHSCREEN = 0x00001002;

    public static final class PointerProperties {
        public int id;
        public int toolType;

        public PointerProperties() {
            clear();
        }

        public PointerProperties(PointerProperties other) {
            copyFrom(other);
        }

        public void clear() {
            id = INVALID_POINTER_ID;
            toolType = TOOL_TYPE_UNKNOWN;
        }

        public void copyFrom(PointerProperties other) {
            id = other.id;
            toolType = other.toolType;
        }
    }

    public static final class PointerCoords {
        public float x;
        public float y;
        public float pressure;
        public float size;
        public float touchMajor;
        public float touchMinor;
        public float toolMajor;
        public float toolMinor;
        public float orientation;
        public float relativeX;
        public float relativeY;

        public PointerCoords() {}

        public PointerCoords(PointerCoords other) {
            copyFrom(other);
        }

        public void clear() {
            x = y = pressure = size = 0;
            touchMajor = touchMinor = toolMajor = toolMinor = orientation = 0;
            relativeX = relativeY = 0;
        }

        public void copyFrom(PointerCoords other) {
            x = other.x;
            y = other.y;
            pressure = other.pressure;
            size = other.size;
            touchMajor = other.touchMajor;
            touchMinor = other.touchMinor;
            toolMajor = other.toolMajor;
            toolMinor = other.toolMinor;
            orientation = other.orientation;
            relativeX = other.relativeX;
            relativeY = other.relativeY;
        }

        public float getAxisValue(int axis) {
            switch (axis) {
                case AXIS_X: return x;
                case AXIS_Y: return y;
                case AXIS_PRESSURE: return pressure;
                case AXIS_SIZE: return size;
                case AXIS_TOUCH_MAJOR: return touchMajor;
                case AXIS_TOUCH_MINOR: return touchMinor;
                case AXIS_TOOL_MAJOR: return toolMajor;
                case AXIS_TOOL_MINOR: return toolMinor;
                case AXIS_ORIENTATION: return orientation;
                default: return 0;
            }
        }

        public void setAxisValue(int axis, float value) {
            switch (axis) {
                case AXIS_X: x = value; break;
                case AXIS_Y: y = value; break;
                case AXIS_PRESSURE: pressure = value; break;
                case AXIS_SIZE: size = value; break;
                case AXIS_TOUCH_MAJOR: touchMajor = value; break;
                case AXIS_TOUCH_MINOR: touchMinor = value; break;
                case AXIS_TOOL_MAJOR: toolMajor = value; break;
                case AXIS_TOOL_MINOR: toolMinor = value; break;
                case AXIS_ORIENTATION: orientation = value; break;
                default: break;
            }
        }
    }

    private long downTime;
    private long eventTime;
    private int action;
    private PointerProperties[] properties;
    private PointerCoords[] coords;
    private int metaState;
    private int buttonState;
    private float xPrecision = 1;
    private float yPrecision = 1;
    private int deviceId;
    private int edgeFlags;
    private int source = SOURCE_TOUCHSCREEN;
    private int flags;

    private MotionEvent() {}

    public static MotionEvent obtain(
        long downTime, long eventTime, int action, int pointerCount,
        PointerProperties[] pointerProperties, PointerCoords[] pointerCoords,
        int metaState, int buttonState, float xPrecision, float yPrecision,
        int deviceId, int edgeFlags, int source, int flags
    ) {
        MotionEvent event = new MotionEvent();
        event.downTime = downTime;
        event.eventTime = eventTime;
        event.action = action;
        int count = Math.max(1, pointerCount);
        event.properties = new PointerProperties[count];
        event.coords = new PointerCoords[count];
        for (int i = 0; i < count; i++) {
            event.properties[i] = pointerProperties != null && i < pointerProperties.length
                ? new PointerProperties(pointerProperties[i]) : new PointerProperties();
            event.coords[i] = pointerCoords != null && i < pointerCoords.length
                ? new PointerCoords(pointerCoords[i]) : new PointerCoords();
        }
        event.metaState = metaState;
        event.buttonState = buttonState;
        event.xPrecision = xPrecision;
        event.yPrecision = yPrecision;
        event.deviceId = deviceId;
        event.edgeFlags = edgeFlags;
        event.source = source;
        event.flags = flags;
        return event;
    }

    public static MotionEvent obtain(
        long downTime, long eventTime, int action, int pointerCount,
        PointerProperties[] pointerProperties, PointerCoords[] pointerCoords,
        int metaState, int buttonState, float xPrecision, float yPrecision,
        int deviceId, int edgeFlags, int source, int displayId, int flags
    ) {
        return obtain(downTime, eventTime, action, pointerCount, pointerProperties, pointerCoords,
            metaState, buttonState, xPrecision, yPrecision, deviceId, edgeFlags, source, flags);
    }

    public static MotionEvent obtain(
        long downTime, long eventTime, int action, float x, float y, float pressure, float size,
        int metaState, float xPrecision, float yPrecision, int deviceId, int edgeFlags
    ) {
        PointerProperties property = new PointerProperties();
        property.id = 0;
        property.toolType = TOOL_TYPE_FINGER;
        PointerCoords coord = new PointerCoords();
        coord.x = x;
        coord.y = y;
        coord.pressure = pressure;
        coord.size = size;
        return obtain(downTime, eventTime, action, 1, new PointerProperties[] {property},
            new PointerCoords[] {coord}, metaState, 0, xPrecision, yPrecision, deviceId,
            edgeFlags, SOURCE_TOUCHSCREEN, 0);
    }

    public static MotionEvent obtain(long downTime, long eventTime, int action, float x, float y, int metaState) {
        return obtain(downTime, eventTime, action, x, y, 1f, 1f, metaState, 1f, 1f, 0, 0);
    }

    public static MotionEvent obtain(MotionEvent other) {
        return obtain(other.downTime, other.eventTime, other.action, other.properties.length,
            other.properties, other.coords, other.metaState, other.buttonState, other.xPrecision,
            other.yPrecision, other.deviceId, other.edgeFlags, other.source, other.flags);
    }

    public static MotionEvent obtainNoHistory(MotionEvent other) {
        return obtain(other);
    }

    @Override public void recycle() {}

    @Override public int getDeviceId() { return deviceId; }
    @Override public int getSource() { return source; }
    public void setSource(int source) { this.source = source; }
    @Override public long getEventTime() { return eventTime; }
    public long getEventTimeNanos() { return eventTime * 1_000_000L; }
    public long getDownTime() { return downTime; }
    public void setDownTime(long downTime) { this.downTime = downTime; }

    public int getAction() { return action; }
    public void setAction(int action) { this.action = action; }
    public int getActionMasked() { return action & ACTION_MASK; }
    public int getActionIndex() { return (action & ACTION_POINTER_INDEX_MASK) >> ACTION_POINTER_INDEX_SHIFT; }
    public int getFlags() { return flags; }
    public int getMetaState() { return metaState; }
    public int getButtonState() { return buttonState; }
    public int getEdgeFlags() { return edgeFlags; }
    public void setEdgeFlags(int flags) { edgeFlags = flags; }
    public float getXPrecision() { return xPrecision; }
    public float getYPrecision() { return yPrecision; }
    public int getHistorySize() { return 0; }

    public int getPointerCount() { return coords.length; }
    public int getPointerId(int index) { return properties[index].id; }
    public int getToolType(int index) { return properties[index].toolType; }

    public int findPointerIndex(int pointerId) {
        for (int i = 0; i < properties.length; i++) {
            if (properties[i].id == pointerId) return i;
        }
        return -1;
    }

    public float getX() { return coords[0].x; }
    public float getY() { return coords[0].y; }
    public float getX(int index) { return coords[index].x; }
    public float getY(int index) { return coords[index].y; }
    public float getRawX() { return coords[0].x; }
    public float getRawY() { return coords[0].y; }
    public float getPressure() { return coords[0].pressure; }
    public float getPressure(int index) { return coords[index].pressure; }
    public float getSize() { return coords[0].size; }
    public float getSize(int index) { return coords[index].size; }
    public float getTouchMajor() { return coords[0].touchMajor; }
    public float getTouchMinor() { return coords[0].touchMinor; }
    public float getToolMajor() { return coords[0].toolMajor; }
    public float getToolMinor() { return coords[0].toolMinor; }
    public float getOrientation() { return coords[0].orientation; }
    public float getAxisValue(int axis) { return coords[0].getAxisValue(axis); }
    public float getAxisValue(int axis, int index) { return coords[index].getAxisValue(axis); }

    public void getPointerCoords(int index, PointerCoords out) { out.copyFrom(coords[index]); }
    public void getPointerProperties(int index, PointerProperties out) { out.copyFrom(properties[index]); }

    public void setLocation(float x, float y) {
        offsetLocation(x - coords[0].x, y - coords[0].y);
    }

    public void offsetLocation(float deltaX, float deltaY) {
        for (PointerCoords coord : coords) {
            coord.x += deltaX;
            coord.y += deltaY;
        }
    }

    public static String actionToString(int action) {
        switch (action) {
            case ACTION_DOWN: return "ACTION_DOWN";
            case ACTION_UP: return "ACTION_UP";
            case ACTION_MOVE: return "ACTION_MOVE";
            case ACTION_CANCEL: return "ACTION_CANCEL";
            case ACTION_OUTSIDE: return "ACTION_OUTSIDE";
            default: return Integer.toString(action);
        }
    }

    @Override
    public String toString() {
        return "MotionEvent { action=" + actionToString(getActionMasked())
            + ", x=" + getX() + ", y=" + getY() + " }";
    }
}
