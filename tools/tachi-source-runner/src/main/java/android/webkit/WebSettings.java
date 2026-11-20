package android.webkit;

/**
 * Settings bean. Only the user agent reaches the platform browser
 * (host.browser.setUserAgent); the rest are recorded so the helper can read
 * back what it wrote, which is all the qualification sources need.
 */
public class WebSettings {
    public static final int LOAD_DEFAULT = -1;
    public static final int LOAD_NO_CACHE = 2;
    public static final int MIXED_CONTENT_NEVER_ALLOW = 1;

    private final WebView owner;
    private String userAgent = defaultUserAgentString();
    private boolean javaScriptEnabled;
    private boolean domStorageEnabled;
    private boolean databaseEnabled;
    private boolean blockNetworkImage;
    private boolean useWideViewPort;
    private boolean loadWithOverviewMode;
    private int cacheMode = LOAD_DEFAULT;
    private int mixedContentMode = MIXED_CONTENT_NEVER_ALLOW;

    WebSettings(WebView owner) { this.owner = owner; }

    public static String getDefaultUserAgent(android.content.Context context) { return defaultUserAgentString(); }

    private static String defaultUserAgentString() {
        return "Mozilla/5.0 (Linux; Android 15; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Mobile Safari/537.36";
    }

    public String getUserAgentString() { return userAgent; }

    public void setUserAgentString(String ua) {
        userAgent = ua == null || ua.isEmpty() ? defaultUserAgentString() : ua;
        owner.backend().setUserAgent(userAgent);
    }

    public boolean getJavaScriptEnabled() { return javaScriptEnabled; }
    public void setJavaScriptEnabled(boolean v) { javaScriptEnabled = v; }
    public boolean getDomStorageEnabled() { return domStorageEnabled; }
    public void setDomStorageEnabled(boolean v) { domStorageEnabled = v; }
    public boolean getDatabaseEnabled() { return databaseEnabled; }
    public void setDatabaseEnabled(boolean v) { databaseEnabled = v; }
    public boolean getBlockNetworkImage() { return blockNetworkImage; }
    public void setBlockNetworkImage(boolean v) { blockNetworkImage = v; }
    public boolean getUseWideViewPort() { return useWideViewPort; }
    public void setUseWideViewPort(boolean v) { useWideViewPort = v; }
    public boolean getLoadWithOverviewMode() { return loadWithOverviewMode; }
    public void setLoadWithOverviewMode(boolean v) { loadWithOverviewMode = v; }
    public int getCacheMode() { return cacheMode; }
    public void setCacheMode(int v) { cacheMode = v; }
    public int getMixedContentMode() { return mixedContentMode; }
    public void setMixedContentMode(int v) { mixedContentMode = v; }
}

