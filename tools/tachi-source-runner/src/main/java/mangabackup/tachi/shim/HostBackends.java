package mangabackup.tachi.shim;

import android.webkit.CookieManager;

/** Backends the worker installs before loading any extension. */
public final class HostBackends {
    private static volatile WebViewBackend.Factory webViews;
    private static volatile CookieManager cookies;

    private HostBackends() { }

    public static void install(WebViewBackend.Factory webViewFactory, CookieManager cookieManager) {
        webViews = webViewFactory;
        cookies = cookieManager;
    }

    public static WebViewBackend.Factory webViews() {
        WebViewBackend.Factory f = webViews;
        if (f == null) throw new UnsupportedHostApi("android.webkit.WebView (no browser backend installed)");
        return f;
    }

    public static CookieManager cookies() {
        CookieManager c = cookies;
        if (c == null) throw new UnsupportedHostApi("android.webkit.CookieManager (no cookie backend installed)");
        return c;
    }
}

