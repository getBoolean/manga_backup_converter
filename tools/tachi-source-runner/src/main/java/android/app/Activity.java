package android.app;

import android.content.ContextWrapper;
import android.content.Intent;
import android.os.Bundle;
import mangabackup.tachi.shim.UnsupportedHostApi;

/** Extensions declare deep-link activities; the desktop host never starts one. */
public class Activity extends ContextWrapper {
    private Intent intent = new Intent();

    public Activity() { super(null); }

    protected void onCreate(Bundle savedInstanceState) { }
    public Intent getIntent() { return intent; }
    public void setIntent(Intent newIntent) { intent = newIntent; }
    public void finish() { }
    @Override public void startActivity(Intent intent) { throw new UnsupportedHostApi("Activity.startActivity"); }
}

