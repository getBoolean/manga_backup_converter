package android.net;

import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

/** An immutable URI reference over {@link java.net.URI}, covering the parts extensions read. */
public class Uri implements Comparable<Uri> {
    public static final Uri EMPTY = new Uri("");

    private final String text;

    private Uri(String text) { this.text = text; }

    public static Uri parse(String uriString) { return new Uri(uriString); }

    public static String encode(String s) { return encode(s, null); }

    public static String encode(String s, String allow) {
        if (s == null) return null;
        String encoded = URLEncoder.encode(s, StandardCharsets.UTF_8).replace("+", "%20").replace("%7E", "~");
        if (allow != null) {
            for (char c : allow.toCharArray()) {
                encoded = encoded.replace(URLEncoder.encode(String.valueOf(c), StandardCharsets.UTF_8), String.valueOf(c));
            }
        }
        return encoded;
    }

    public static String decode(String s) {
        return s == null ? null : URLDecoder.decode(s.replace("+", "%2B"), StandardCharsets.UTF_8);
    }

    private URI uri() {
        try {
            return new URI(text);
        } catch (URISyntaxException e) {
            try {
                return new URI(text.replace(" ", "%20"));
            } catch (URISyntaxException e2) {
                return null;
            }
        }
    }

    public String getScheme() { URI u = uri(); return u == null ? null : u.getScheme(); }
    public String getHost() { URI u = uri(); return u == null ? null : u.getHost(); }
    public int getPort() { URI u = uri(); return u == null ? -1 : u.getPort(); }
    public String getAuthority() { URI u = uri(); return u == null ? null : u.getAuthority(); }
    public String getPath() { URI u = uri(); return u == null ? null : u.getPath(); }
    public String getEncodedPath() { URI u = uri(); return u == null ? null : u.getRawPath(); }
    public String getQuery() { URI u = uri(); return u == null ? null : u.getQuery(); }
    public String getEncodedQuery() { URI u = uri(); return u == null ? null : u.getRawQuery(); }
    public String getFragment() { URI u = uri(); return u == null ? null : u.getFragment(); }
    public String getUserInfo() { URI u = uri(); return u == null ? null : u.getUserInfo(); }
    public boolean isAbsolute() { return getScheme() != null; }
    public boolean isRelative() { return !isAbsolute(); }
    public boolean isHierarchical() { URI u = uri(); return u != null && !u.isOpaque(); }

    public List<String> getPathSegments() {
        String path = getPath();
        if (path == null) return Collections.emptyList();
        List<String> out = new ArrayList<>();
        for (String s : path.split("/")) if (!s.isEmpty()) out.add(s);
        return Collections.unmodifiableList(out);
    }

    public String getLastPathSegment() {
        List<String> segments = getPathSegments();
        return segments.isEmpty() ? null : segments.get(segments.size() - 1);
    }

    public Set<String> getQueryParameterNames() {
        String q = getEncodedQuery();
        if (q == null) return Collections.emptySet();
        Set<String> names = new LinkedHashSet<>();
        for (String pair : q.split("&")) {
            if (pair.isEmpty()) continue;
            int eq = pair.indexOf('=');
            names.add(decode(eq < 0 ? pair : pair.substring(0, eq)));
        }
        return Collections.unmodifiableSet(names);
    }

    public List<String> getQueryParameters(String key) {
        String q = getEncodedQuery();
        if (q == null) return Collections.emptyList();
        List<String> values = new ArrayList<>();
        for (String pair : q.split("&")) {
            int eq = pair.indexOf('=');
            String name = decode(eq < 0 ? pair : pair.substring(0, eq));
            if (name.equals(key)) values.add(eq < 0 ? "" : decode(pair.substring(eq + 1)));
        }
        return Collections.unmodifiableList(values);
    }

    public String getQueryParameter(String key) {
        List<String> values = getQueryParameters(key);
        return values.isEmpty() ? null : values.get(0);
    }

    public Builder buildUpon() { return new Builder(this); }

    @Override public String toString() { return text; }
    @Override public boolean equals(Object o) { return o instanceof Uri other && other.text.equals(text); }
    @Override public int hashCode() { return text.hashCode(); }
    @Override public int compareTo(Uri o) { return text.compareTo(o.text); }

    public static final class Builder {
        private String scheme;
        private String authority;
        private String path = "";
        private final StringBuilder query = new StringBuilder();
        private String fragment;

        public Builder() { }

        Builder(Uri base) {
            URI u = base.uri();
            if (u != null) {
                scheme = u.getScheme();
                authority = u.getRawAuthority();
                path = u.getRawPath() == null ? "" : u.getRawPath();
                if (u.getRawQuery() != null) query.append(u.getRawQuery());
                fragment = u.getRawFragment();
            }
        }

        public Builder scheme(String s) { scheme = s; return this; }
        public Builder authority(String a) { authority = a; return this; }
        public Builder encodedAuthority(String a) { authority = a; return this; }
        public Builder path(String p) { path = encode(p, "/"); return this; }
        public Builder encodedPath(String p) { path = p; return this; }
        public Builder appendPath(String segment) {
            if (!path.endsWith("/")) path += "/";
            path += encode(segment);
            return this;
        }
        public Builder appendEncodedPath(String segment) {
            if (!path.endsWith("/")) path += "/";
            path += segment;
            return this;
        }
        public Builder appendQueryParameter(String key, String value) {
            if (query.length() > 0) query.append('&');
            query.append(encode(key)).append('=').append(encode(value));
            return this;
        }
        public Builder clearQuery() { query.setLength(0); return this; }
        public Builder encodedQuery(String q) { query.setLength(0); if (q != null) query.append(q); return this; }
        public Builder fragment(String f) { fragment = encode(f); return this; }

        public Uri build() {
            StringBuilder sb = new StringBuilder();
            if (scheme != null) sb.append(scheme).append(':');
            if (authority != null) sb.append("//").append(authority);
            sb.append(path);
            if (query.length() > 0) sb.append('?').append(query);
            if (fragment != null) sb.append('#').append(fragment);
            return new Uri(sb.toString());
        }
    }
}

