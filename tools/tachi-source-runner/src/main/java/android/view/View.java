package android.view;

/**
 * Layout bookkeeping only. The desktop host renders nothing in-process; a
 * visible interaction goes to the platform browser through the supervisor.
 */
public class View {
    public static final int VISIBLE = 0;
    public static final int INVISIBLE = 4;
    public static final int GONE = 8;

    private ViewParent parent;
    private ViewGroup.LayoutParams layoutParams;
    private int left;
    private int top;
    private int right;
    private int bottom;
    private int visibility = VISIBLE;
    private boolean enabled = true;

    public View() { }

    public View(android.content.Context context) { }

    public static class MeasureSpec {
        public static final int UNSPECIFIED = 0;
        public static final int EXACTLY = 1 << 30;
        public static final int AT_MOST = 2 << 30;
        private static final int MODE_MASK = 3 << 30;

        public static int makeMeasureSpec(int size, int mode) { return (size & ~MODE_MASK) | (mode & MODE_MASK); }
        public static int getMode(int measureSpec) { return measureSpec & MODE_MASK; }
        public static int getSize(int measureSpec) { return measureSpec & ~MODE_MASK; }
    }

    public ViewParent getParent() { return parent; }
    void setParent(ViewParent p) { parent = p; }
    public View getRootView() { return this; }
    public View findViewById(int id) { return null; }
    public void setLayoutParams(ViewGroup.LayoutParams params) { layoutParams = params; }
    public ViewGroup.LayoutParams getLayoutParams() { return layoutParams; }
    public void measure(int widthMeasureSpec, int heightMeasureSpec) { }
    public void layout(int l, int t, int r, int b) { left = l; top = t; right = r; bottom = b; }
    public int getWidth() { return right - left; }
    public int getHeight() { return bottom - top; }
    public void setVisibility(int v) { visibility = v; }
    public int getVisibility() { return visibility; }
    public void setEnabled(boolean e) { enabled = e; }
    public boolean isEnabled() { return enabled; }
}

