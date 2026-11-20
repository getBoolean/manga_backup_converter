package android.os;

import java.util.Locale;

public final class LocaleList {
    private final Locale[] locales;

    public LocaleList(Locale... locales) { this.locales = locales.clone(); }

    public static LocaleList getDefault() { return new LocaleList(Locale.getDefault()); }
    public Locale get(int index) { return locales[index]; }
    public int size() { return locales.length; }
    public boolean isEmpty() { return locales.length == 0; }
    public String toLanguageTags() {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < locales.length; i++) { if (i > 0) sb.append(','); sb.append(locales[i].toLanguageTag()); }
        return sb.toString();
    }
}

