package androidx.preference;

import android.content.Context;
import java.util.HashSet;
import java.util.Set;

public class MultiSelectListPreference extends DialogPreference {
    private CharSequence[] entries = new CharSequence[0];
    private CharSequence[] entryValues = new CharSequence[0];
    private Set<String> values = new HashSet<>();

    public MultiSelectListPreference(Context context) { super(context); }

    public CharSequence[] getEntries() { return entries; }
    public void setEntries(CharSequence[] entries) { this.entries = entries; }
    public CharSequence[] getEntryValues() { return entryValues; }
    public void setEntryValues(CharSequence[] values) { this.entryValues = values; }
    public Set<String> getValues() { return values; }
    public void setValues(Set<String> values) { this.values = new HashSet<>(values); }

    public int findIndexOfValue(String v) {
        for (int i = 0; i < entryValues.length; i++) if (entryValues[i].toString().equals(v)) return i;
        return -1;
    }
}

