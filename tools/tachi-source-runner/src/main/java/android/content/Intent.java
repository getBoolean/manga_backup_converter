package android.content;

import android.net.Uri;
import android.os.Bundle;

/** Data holder only; the desktop host never dispatches intents. */
public class Intent {
    public static final String ACTION_VIEW = "android.intent.action.VIEW";
    public static final int FLAG_ACTIVITY_NEW_TASK = 0x10000000;
    public static final int FLAG_ACTIVITY_CLEAR_TOP = 0x04000000;

    private String action;
    private Uri data;
    private final Bundle extras = new Bundle();
    private int flags;

    public Intent() { }

    public Intent(String action) { this.action = action; }

    public Intent setAction(String action) { this.action = action; return this; }
    public String getAction() { return action; }
    public Intent setData(Uri data) { this.data = data; return this; }
    public Uri getData() { return data; }
    public Intent putExtra(String name, String value) { extras.putString(name, value); return this; }
    public String getStringExtra(String name) { return extras.getString(name); }
    public Bundle getExtras() { return extras; }
    public Intent setFlags(int flags) { this.flags = flags; return this; }
    public Intent addFlags(int flags) { this.flags |= flags; return this; }
    public int getFlags() { return flags; }
}

