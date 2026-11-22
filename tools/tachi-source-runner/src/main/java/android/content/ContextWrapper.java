package android.content;

import android.content.res.Resources;
import java.io.File;

public class ContextWrapper extends Context {
    private Context base;

    public ContextWrapper(Context base) {
        this.base = base;
    }

    protected void attachBaseContext(Context newBase) {
        this.base = newBase;
    }

    public Context getBaseContext() {
        return base;
    }

    private Context base() {
        if (base == null) return new Context();
        return base;
    }

    @Override public SharedPreferences getSharedPreferences(String name, int mode) { return base().getSharedPreferences(name, mode); }
    @Override public String getPackageName() { return base().getPackageName(); }
    @Override public File getCacheDir() { return base().getCacheDir(); }
    @Override public File getFilesDir() { return base().getFilesDir(); }
    @Override public Context getApplicationContext() { return base().getApplicationContext(); }
    @Override public Resources getResources() { return base().getResources(); }
    @Override public String getString(int resId) { return base().getString(resId); }
    @Override public void startActivity(Intent intent) { base().startActivity(intent); }
    @Override public ClassLoader getClassLoader() { return base().getClassLoader(); }
}

