package androidx.preference;

import android.content.Context;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class PreferenceScreen {
    private final Context context;
    private final List<Preference> preferences = new ArrayList<>();

    public PreferenceScreen() { this(null); }

    public PreferenceScreen(Context context) { this.context = context; }

    public Context getContext() { return context; }

    public boolean addPreference(Preference preference) { return preferences.add(preference); }

    public List<Preference> getPreferences() { return Collections.unmodifiableList(preferences); }
}
