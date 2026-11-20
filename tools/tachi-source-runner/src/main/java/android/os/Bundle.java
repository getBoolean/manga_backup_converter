package android.os;

import java.util.HashMap;
import java.util.Map;

public class Bundle {
    private final Map<String, Object> values = new HashMap<>();

    public Bundle() { }

    public void putString(String key, String value) { values.put(key, value); }
    public String getString(String key) { Object v = values.get(key); return v instanceof String s ? s : null; }
    public void putInt(String key, int value) { values.put(key, value); }
    public int getInt(String key) { Object v = values.get(key); return v instanceof Integer i ? i : 0; }
    public boolean containsKey(String key) { return values.containsKey(key); }
}

