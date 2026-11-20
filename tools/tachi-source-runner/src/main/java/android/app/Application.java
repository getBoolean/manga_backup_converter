package android.app;

import android.content.Context;
import android.content.ContextWrapper;

public class Application extends ContextWrapper {
    public Application() { super(null); }

    public Application(Context base) { super(base); }

    public void onCreate() { }
}

