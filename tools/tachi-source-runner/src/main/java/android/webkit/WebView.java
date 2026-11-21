package android.webkit;

import android.content.Context;
import android.os.Looper;
import android.view.ViewGroup;
import java.util.Collections;
import java.util.Map;
import mangabackup.tachi.shim.HostBackends;
import mangabackup.tachi.shim.WebViewBackend;

/**
 * KTD20 translation shim. Calls are forwarded to the platform browser through
 * the supervisor's BrowserPort; page events come back on the worker-owned main
 * looper, so clients observe Android's threading.
 *
 * {@link #getWebViewClassLoader()} deliberately returns a provider class loader
 * with no Chromium glue, so androidx-style feature probes (for example
 * keiyoushi's WebViewGlueBridge) resolve every feature as unsupported and take
 * their documented fallbacks.
 */
public class WebView extends ViewGroup {
    /** Sees only the platform bootstrap classes: no org.chromium.* glue. */
    private static final ClassLoader PROVIDER_LOADER = new ClassLoader(null) { };

    private final Context context;
    private final WebSettings settings;
    private final WebViewBackend backend;
    private WebViewClient client = new WebViewClient();
    private WebChromeClient chromeClient;
    private boolean destroyed;

    public WebView(Context context) {
        super(context);
        checkThread();
        this.context = context;
        this.settings = new WebSettings(this);
        this.backend = HostBackends.webViews().create(this);
    }

    private static void checkThread() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            throw new IllegalStateException("A WebView method was called on thread '" + Thread.currentThread().getName()
                + "'. All WebView methods must be called on the main thread.");
        }
    }

    /** Host access for androidx.webkit shims (not an Android API). */
    public WebViewBackend hostBackend() { return backend; }

    public static ClassLoader getWebViewClassLoader() { return PROVIDER_LOADER; }

    public static void setWebContentsDebuggingEnabled(boolean enabled) { }

    public Context getContext() { return context; }

    public WebSettings getSettings() { return settings; }

    public void setWebViewClient(WebViewClient client) { this.client = client == null ? new WebViewClient() : client; }

    public WebViewClient getWebViewClient() { return client; }

    public void setWebChromeClient(WebChromeClient client) { this.chromeClient = client; }

    public WebChromeClient getWebChromeClient() { return chromeClient; }

    public void loadUrl(String url) { loadUrl(url, Collections.emptyMap()); }

    public void loadUrl(String url, Map<String, String> additionalHttpHeaders) {
        checkThread();
        if (destroyed) return;
        backend.loadUrl(url, additionalHttpHeaders == null ? Collections.emptyMap() : additionalHttpHeaders);
    }

    public void loadData(String data, String mimeType, String encoding) {
        loadDataWithBaseURL("about:blank", data, mimeType, encoding, null);
    }

    public void loadDataWithBaseURL(String baseUrl, String data, String mimeType, String encoding, String historyUrl) {
        checkThread();
        if (destroyed) return;
        backend.loadDataWithBaseUrl(baseUrl, data, mimeType, encoding, historyUrl);
    }

    public void evaluateJavascript(String script, ValueCallback<String> resultCallback) {
        checkThread();
        if (destroyed) return;
        backend.evaluateJavascript(script, resultCallback);
    }

    public void addJavascriptInterface(Object object, String name) {
        checkThread();
        if (destroyed) return;
        backend.addJavascriptInterface(object, name);
    }

    public void removeJavascriptInterface(String name) {
        checkThread();
        if (destroyed) return;
        backend.removeJavascriptInterface(name);
    }

    public String getUrl() { return backend.getUrl(); }

    public void stopLoading() {
        checkThread();
        if (destroyed) return;
        backend.stopLoading();
    }

    public void reload() {
        String url = getUrl();
        if (url != null) loadUrl(url);
    }

    public void onPause() { }

    public void onResume() { }

    public void clearCache(boolean includeDiskFiles) { }

    public void clearHistory() { }

    public void destroy() {
        checkThread();
        if (destroyed) return;
        destroyed = true;
        backend.destroy();
    }

    public boolean isDestroyed() { return destroyed; }
}
