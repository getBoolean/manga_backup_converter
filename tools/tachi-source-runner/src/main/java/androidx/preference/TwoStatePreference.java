package androidx.preference;

import android.content.Context;

public class TwoStatePreference extends Preference {
    private boolean checked;
    private CharSequence summaryOn;
    private CharSequence summaryOff;
    private boolean disableDependentsState;

    public TwoStatePreference(Context context) { super(context); }

    public boolean isChecked() { return checked; }
    public void setChecked(boolean checked) { this.checked = checked; }
    public CharSequence getSummaryOn() { return summaryOn; }
    public void setSummaryOn(CharSequence s) { summaryOn = s; }
    public CharSequence getSummaryOff() { return summaryOff; }
    public void setSummaryOff(CharSequence s) { summaryOff = s; }
    public boolean getDisableDependentsState() { return disableDependentsState; }
    public void setDisableDependentsState(boolean d) { disableDependentsState = d; }
}

