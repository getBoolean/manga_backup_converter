package androidx.preference;

import android.content.Context;

public class ListPreference extends Preference {
    private CharSequence[] entries = new CharSequence[0];
    private CharSequence[] entryValues = new CharSequence[0];
    private String value;

    public ListPreference(Context context) { super(context); }

    public CharSequence[] getEntries() { return entries; }
    public void setEntries(CharSequence[] entries) { this.entries = entries; }
    public CharSequence[] getEntryValues() { return entryValues; }
    public void setEntryValues(CharSequence[] values) { this.entryValues = values; }
    public String getValue() { return value; }
    public void setValue(String value) { this.value = value; }
    public void setValueIndex(int index) { setValue(entryValues[index].toString()); }

    public int findIndexOfValue(String v) {
        for (int i = 0; i < entryValues.length; i++) if (entryValues[i].toString().equals(v)) return i;
        return -1;
    }
}

