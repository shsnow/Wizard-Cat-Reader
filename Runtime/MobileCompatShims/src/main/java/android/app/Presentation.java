package android.app;

import android.content.Context;
import android.view.Display;
import android.view.View;
import android.view.ViewGroup;

/**
 * Headless Presentation. It gives the content view a parent (as the window it would show in)
 * so code can watch for the view's removal; showing it does nothing, as the iOS WebView is
 * already in the app's window.
 */
public class Presentation {
    private final Context context;
    private final Display display;
    private Root root;
    private boolean showing;

    public Presentation(Context outerContext, Display display) {
        this.context = outerContext;
        this.display = display;
    }

    public Presentation(Context outerContext, Display display, int theme) {
        this(outerContext, display);
    }

    public Display getDisplay() { return display; }

    public final Context getContext() { return context; }

    public void setContentView(View view) {
        if (root == null) root = new Root(context);
        root.addView(view);
    }

    public void setContentView(View view, ViewGroup.LayoutParams params) {
        setContentView(view);
    }

    public void show() { showing = true; }

    public void hide() { showing = false; }

    public void dismiss() { showing = false; }

    public void cancel() { dismiss(); }

    public boolean isShowing() { return showing; }

    private static final class Root extends ViewGroup {
        Root(Context context) {
            super(context);
        }

        @Override
        protected void onLayout(boolean changed, int left, int top, int right, int bottom) {}
    }
}
