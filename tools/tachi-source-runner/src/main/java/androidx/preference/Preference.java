package androidx.preference;

import android.content.Context;

/**
 * Settings schema beans. Extensions build their screen in
 * {@code setupPreferenceScreen}; the host can read it back to describe a
 * source's settings. Nothing is rendered.
 */
public class Preference {
    public interface OnPreferenceChangeListener {
        boolean onPreferenceChange(Preference preference, Object newValue);
    }

    public interface OnPreferenceClickListener {
        boolean onPreferenceClick(Preference preference);
    }

    private final Context context;
    private String key;
    private CharSequence title;
    private CharSequence summary;
    private Object defaultValue;
    private boolean enabled = true;
    private boolean visible = true;
    private OnPreferenceChangeListener changeListener;
    private OnPreferenceClickListener clickListener;

    public Preference() { this(null); }

    public Preference(Context context) { this.context = context; }

    public Context getContext() { return context; }
    public String getKey() { return key; }
    public void setKey(String key) { this.key = key; }
    public CharSequence getTitle() { return title; }
    public void setTitle(CharSequence title) { this.title = title; }
    public CharSequence getSummary() { return summary; }
    public void setSummary(CharSequence summary) { this.summary = summary; }
    public Object getDefaultValue() { return defaultValue; }
    public void setDefaultValue(Object value) { defaultValue = value; }
    public boolean isEnabled() { return enabled; }
    public void setEnabled(boolean enabled) { this.enabled = enabled; }
    public boolean isVisible() { return visible; }
    public void setVisible(boolean visible) { this.visible = visible; }
    public OnPreferenceChangeListener getOnPreferenceChangeListener() { return changeListener; }
    public void setOnPreferenceChangeListener(OnPreferenceChangeListener l) { changeListener = l; }
    public void setOnPreferenceClickListener(OnPreferenceClickListener l) { clickListener = l; }
    public boolean callChangeListener(Object newValue) { return changeListener == null || changeListener.onPreferenceChange(this, newValue); }
}

