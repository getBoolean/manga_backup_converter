package mangabackup.tachi.shim;

import android.webkit.ValueCallback;
import android.webkit.WebView;
import java.util.Map;

/**
 * What {@link WebView} forwards to. The worker's KTD20 translation layer
 * implements it over {@code host.browser.*} reverse requests. Every call is
 * made on the worker-owned main looper and must not block it.
 */
public interface WebViewBackend {
    interface Factory {
        WebViewBackend create(WebView view);
    }

    void loadUrl(String url, Map<String, String> headers);

    void loadDataWithBaseUrl(String baseUrl, String data, String mimeType, String encoding, String historyUrl);

    void evaluateJavascript(String script, ValueCallback<String> callback);

    void addJavascriptInterface(Object target, String name);

    void removeJavascriptInterface(String name);

    void setUserAgent(String userAgent);

    void stopLoading();

    void destroy();

    String getUrl();
}

