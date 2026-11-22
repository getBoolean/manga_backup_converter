package android.widget;

import android.text.TextWatcher;
import android.view.View;
import mangabackup.tachi.shim.UnsupportedHostApi;

public class TextView extends View {
    private CharSequence error;

    public TextView() { }

    public CharSequence getError() { return error; }
    public void setError(CharSequence e) { error = e; }
    public void addTextChangedListener(TextWatcher watcher) { throw new UnsupportedHostApi("TextView.addTextChangedListener"); }
}

