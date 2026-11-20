package android.webkit;

import mangabackup.tachi.shim.HostBackends;

/**
 * Source-scoped cookie store shared with the package's OkHttp cookie jar, as
 * on Android where both read the WebView cookie database. The worker installs
 * the implementation; {@link #getInstance()} resolves the calling package's
 * store.
 */
public abstract class CookieManager {
    protected CookieManager() { }

    public static CookieManager getInstance() { return HostBackends.cookies(); }

    public abstract void setAcceptCookie(boolean accept);
    public abstract boolean acceptCookie();
    public abstract void setAcceptThirdPartyCookies(WebView webview, boolean accept);
    public abstract boolean acceptThirdPartyCookies(WebView webview);
    public abstract void setCookie(String url, String value);
    public abstract void setCookie(String url, String value, ValueCallback<Boolean> callback);
    public abstract String getCookie(String url);
    public abstract void removeSessionCookies(ValueCallback<Boolean> callback);
    public abstract void removeAllCookies(ValueCallback<Boolean> callback);
    public abstract boolean hasCookies();
    public abstract void flush();
}

