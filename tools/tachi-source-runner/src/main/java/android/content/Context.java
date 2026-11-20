package android.content;

import android.content.res.Resources;
import java.io.File;
import mangabackup.tachi.shim.UnsupportedHostApi;

/**
 * Desktop-host {@code Context}. The base class implements nothing; the worker
 * hands extensions a {@link ContextWrapper} whose base supplies the
 * source-scoped, in-memory facilities (KTD9). Every other member fails with a
 * named error instead of returning a stub value.
 */
public class Context {
    public static final int MODE_PRIVATE = 0;

    public Context() { }

    public SharedPreferences getSharedPreferences(String name, int mode) {
        throw new UnsupportedHostApi("Context.getSharedPreferences");
    }

    public String getPackageName() {
        throw new UnsupportedHostApi("Context.getPackageName");
    }

    public File getCacheDir() {
        throw new UnsupportedHostApi("Context.getCacheDir");
    }

    public File getFilesDir() {
        throw new UnsupportedHostApi("Context.getFilesDir");
    }

    public Context getApplicationContext() {
        throw new UnsupportedHostApi("Context.getApplicationContext");
    }

    public Resources getResources() {
        return Resources.getSystem();
    }

    public String getString(int resId) {
        throw new UnsupportedHostApi("Context.getString");
    }

    public void startActivity(Intent intent) {
        throw new UnsupportedHostApi("Context.startActivity");
    }

    public ClassLoader getClassLoader() {
        throw new UnsupportedHostApi("Context.getClassLoader");
    }
}

