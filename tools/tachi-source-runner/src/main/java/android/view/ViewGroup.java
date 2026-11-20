package android.view;

import java.util.ArrayList;
import java.util.List;

public class ViewGroup extends View implements ViewParent {
    private final List<View> children = new ArrayList<>();

    public ViewGroup() { }

    public ViewGroup(android.content.Context context) { super(context); }

    public static class LayoutParams {
        public static final int MATCH_PARENT = -1;
        public static final int WRAP_CONTENT = -2;
        public int width;
        public int height;

        public LayoutParams(int width, int height) { this.width = width; this.height = height; }
    }

    public void addView(View child) { children.add(child); child.setParent(this); }
    public void removeView(View child) { if (children.remove(child)) child.setParent(null); }
    public int getChildCount() { return children.size(); }
}

