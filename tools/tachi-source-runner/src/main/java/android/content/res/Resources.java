package android.content.res;

import android.util.DisplayMetrics;

/** Only {@link #getSystem()} and display metrics (used to size off-screen WebViews). */
public class Resources {
    private static final Resources SYSTEM = new Resources();
    private final DisplayMetrics metrics = new DisplayMetrics();

    public Resources() {
        metrics.widthPixels = 1080;
        metrics.heightPixels = 1920;
        metrics.density = 2.625f;
        metrics.densityDpi = 420;
    }

    public static Resources getSystem() { return SYSTEM; }

    public DisplayMetrics getDisplayMetrics() { return metrics; }
}

