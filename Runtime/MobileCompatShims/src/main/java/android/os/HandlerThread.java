package android.os;

/** A thread with a Looper, as on Android (the android.jar stub has none). */
public class HandlerThread extends Thread {
    private final int priority;
    private Looper looper;
    private Handler handler;
    private int tid = -1;

    public HandlerThread(String name) {
        this(name, Process.THREAD_PRIORITY_DEFAULT);
    }

    public HandlerThread(String name, int priority) {
        super(name);
        this.priority = priority;
        setDaemon(true);
    }

    protected void onLooperPrepared() {}

    @Override
    public void run() {
        tid = (int) getId();
        Looper.prepare();
        synchronized (this) {
            looper = Looper.myLooper();
            notifyAll();
        }
        onLooperPrepared();
        Looper.loop();
        tid = -1;
    }

    public Looper getLooper() {
        if (!isAlive()) return null;
        boolean interrupted = false;
        synchronized (this) {
            while (isAlive() && looper == null) {
                try {
                    wait();
                } catch (InterruptedException e) {
                    interrupted = true;
                }
            }
        }
        if (interrupted) Thread.currentThread().interrupt();
        return looper;
    }

    public Handler getThreadHandler() {
        if (handler == null) {
            Looper current = getLooper();
            if (current != null) handler = new Handler(current);
        }
        return handler;
    }

    public boolean quit() {
        Looper current = getLooper();
        if (current != null) {
            current.quit();
            return true;
        }
        return false;
    }

    public boolean quitSafely() {
        Looper current = getLooper();
        if (current != null) {
            current.quitSafely();
            return true;
        }
        return false;
    }

    public int getThreadId() { return tid; }
}
