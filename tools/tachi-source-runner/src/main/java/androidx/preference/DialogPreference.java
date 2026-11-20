package androidx.preference;

import android.content.Context;

public abstract class DialogPreference extends Preference {
    private CharSequence dialogTitle;
    private CharSequence dialogMessage;

    public DialogPreference() { super(); }

    public DialogPreference(Context context) { super(context); }

    public CharSequence getDialogTitle() { return dialogTitle; }
    public void setDialogTitle(CharSequence t) { dialogTitle = t; }
    public CharSequence getDialogMessage() { return dialogMessage; }
    public void setDialogMessage(CharSequence m) { dialogMessage = m; }
}

